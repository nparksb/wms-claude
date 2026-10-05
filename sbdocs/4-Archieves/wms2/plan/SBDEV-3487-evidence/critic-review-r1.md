---
title: "SBDEV-3487 critic review r1"
snapshot_sha1: f321405a75813573b47c75c8c0e298ec2768a97f
verdict: ITERATE
---

**VERDICT: ITERATE**

**Overall assessment:** The core design holds up. A facade guard, a backstop that throws, and the delete predicate is the right shape. Almost every code claim I checked is accurate, and the V1 (scanGate) race argument rests on a real measured lock order. The plan is still not ready to approve, for three reasons. First, its whole account of C2 (`scanDestination`) is built on "unmeasured flush timing", but the code settles that question, and the answer contradicts R2, the A2 rejection and the ADR's consequences. Second, an ordinary checked-exception change that breaks compilation is missing. Third, the AC-6 STOP rule can never fire.

**Pre-commitment predictions vs actual:**
- I expected (1) the C2 flush reasoning to be wrong. Confirmed.
- I expected (2) ambiguity about which collaborators are real or mocked in the AC unit tests. Confirmed for AC-2.
- I expected (3) a STOP or red-reason rule that doesn't actually test anything. Confirmed.
- I expected (4) a silent layer justified by unmeasured reasoning. Confirmed: Fix D.
- I expected (5) wrong file or line references. Not found: every reference I checked is accurate.

---

### Findings

**1. High: §5.4 "Race note for C2", §5.5 "For" bullet, §8 R2, §11 ADR (A2 rejection and consequences), and §3.3's last sentence.**

The plan says: `"Whether the pallet row is locked when the backstop reads depends on when Hibernate flushes … this is unmeasured. Fix D removes the dependency."` The code answers this in two independent ways.

- **Route 1: the JPQL child lookup flushes the pallet row.**
  - `UnitloadBusinessService.processTransfer` (`:523-527`) makes the pallet dirty with `setStoragelocationId`.
  - It then runs `unitloadRepository.findByCarrierunitloadId` (derived JPQL on `Unitload`, `UnitloadRepository:50`).
  - Hibernate's AUTO flush runs because the query covers the dirty entity's table. So the pallet UPDATE is flushed inside `transferUnitLoadToLocation`, before `handleTruckOffLoading` is called.
- **Route 2: native queries flush everything.**
  - Hibernate 6.6.39's `NativeQueryImpl.shouldFlush()` (`:676-689`) returns `isJpaBootstrap()` under AUTO. The tenant EMF is a `LocalContainerEntityManagerFactoryBean` (`TenantDatabaseConfig:70`).
  - So the backstop's native query does a full flush before its SELECT anyway.
- **The UPDATE is version-checked.**
  - `AbstractBaseEntity:34` has `@Version`.
  - `closeBOL` bumps the pallet's version: `"u.version = u.version + 1"` at `BillofladingService:665-667`.

**Consequence:** if `closeBOL` holds the pallet row first, `scanDestination`'s flush waits, then fails its version check, and the whole move rolls back. If `scanDestination` goes first, `closeBOL` is the side that fails (the R5 behaviour).

R2's outcome, `"the pallet ends up moved out of Shipped with its CLOSED positions intact"`, can't happen. In that race the pallet isn't on Shipped at the start; `closeBOL` is what would put it there. So Fix D is never the thing that saves C2, and the ADR's `"A narrow C2 race is left non-destructive rather than rejected"` and §3.3's `"would also close this plan's C2 residual"` are both false.

This breaks principle 3 twice: a derivable fact is labelled "unmeasured", and the unmeasured version is then used to reject A2.

**Fix:**
- Rewrite §5.4 and §8 R2 from the derivation above, citing the lines.
- Delete R2, or restate it as "unreachable given @Version plus closeBOL's version bump".
- Re-justify Fix D honestly: as caller-independent protection for **future** callers of R3–R6, not as C2's guarantee.
- Restate A2's rejection accordingly.
- Remove the C2 clause from §3.3.
- Optional, to make this a real second instrument: in AC-6, after `transferUnitLoadToLocation`, have a second connection run `SELECT … FOR UPDATE NOWAIT` on the pallet and expect `55P03`.

**2. Medium: §5.3 and §5.4 code snippets, and §5.7.**

`assertPalletNotShipped` throws `BusinessException`, which is a checked exception (`BusinessException.java:14`, `extends Exception`). Neither D0 variant declares it:
- `public void handleTruckOffLoading(String)` at `MobileMoveUnitloadService:488`
- `public void handleTruckOffLoadingNoClear(String)` at `:532`

Both need `throws BusinessException`. That breaks compilation of `MobileTruckLoadingWriteServiceUnitTest:124`, where `private void assertNothingWasWritten()` calls `verify(...).handleTruckOffLoadingNoClear(any())` and has no `throws`. That file isn't in §5.7.

The real risk is not the compile error, which is loud. It's an executor who avoids the ripple by wrapping the exception in a `RuntimeException`. That changes the response to a 500 and breaks every AC that asserts `BusinessException` and `getKey()`.

**Fix:**
- State the signature change on both methods.
- Add the test file to §5.7 and Step 2.
- Forbid wrapping.

**3. Medium: §5.8 Step 2, the AC-6 STOP rule.**

`"If AC-6 is GREEN on pre-fix code, STOP"` can never trigger. AC-6 asserts `billOfLadingPositionUnxepectedStateFound`, and no pre-fix code on that path throws that key, so AC-6 is red before the fix whether or not analysis §2 is right.

What actually disproves §2 is AC-6 going red **for the wrong reason**. Examples: `scanDestination` throws something else (`STORAGELOCATION_LOCKED`, a location-constraint `FacadeException`, `EntityNotFound`), or the positions survive.

**Fix:**
- Write AC-6 as `catchThrowable` first.
- Assert the data next: positions intact, pallet still on Shipped with lock 405.
- Assert the key last.
- Then the pre-fix red has to be "positions deleted". Rewrite the STOP rule as: "if pre-fix AC-6 fails on anything other than the positions-deleted assertion, or the throwable is non-null, STOP."

**4. Medium: §5.5 "Rejected refinement". Fix D is the one silent layer, and the reason for keeping it silent doesn't hold.**

The plan says: `"It would falsely fail a legitimate second concurrent move of the same pallet."` Both callers hold the pallet row before R1 reads: V1 through B2 (`findByLabelidForUpdate`), C2 through the flushed version-checked UPDATE (finding 1).

So a second move's R1 sees what the first move committed. On scanGate that is the new tree; on C2 it doesn't get that far, because it hits the version conflict first. When R1 returns a non-null id, a 0-row delete of the pallet row can only mean one of two things:
- the CLOSED predicate fired, or
- a future caller that takes no lock.

Both are exactly the cases that should be loud.

**Fix:** make R3 and R5 return `int`, and have V1 and V2 throw when `bolPositionId != null && deleted == 0`. If the plan keeps the skip instead, give the correct rationale and add a `LOG.warn` on 0 rows.

**5. Medium: §6.2 AC-2. It is ambiguous which collaborators are real, and the wrong reading makes the test vacuous.**

`MobileTruckLoadingServiceUnitTest:85-93` builds the service by hand, with a **real** `OutboundPalletLabelGuard(syspropService)` and a `null` write service. AC-2 says `"stub the finder → "BOL-X""` and `verify(repo, never()).findClosedBolNameBySourceUnitLoadLabel(any())`. That only means something if the new `BillofladingPositionService` constructor argument is a **real** instance built over the mocked repository.

The more natural choice is a `@Mock BillofladingPositionService`, which is the pattern in `MobileMoveUnitloadServiceUnitTest:107`. With that choice:
- stubbing the finder does nothing;
- the `never()` check is vacuous;
- `labelGuardRunsBeforeShippedGuard` stays green even with the call order swapped.

**Fix:** specify `new BillofladingPositionService(mock(ClientService), billofladingPositionRepository, mock(BasicService), mock(UnitloadRepository))`. Alternatively, mock the service and verify `billofladingPositionService, never()).assertPalletNotShipped(any())`. Either way, say that `syspropService` must be stubbed so the real label guard accepts the outbound label in the first test.

**6. Low-Medium: AC-9. The mutation failure doesn't name the broken query.**

Take one CLOSED tree and drop the predicate from R3 (or R5) only. R4 and R6 still skip the children, so R3 deletes a pallet row that the children still point to. That raises `23503` on the position→position FK (analysis Q7). The test goes red, but the failure names an FK, not the missing predicate.

**Fix:** use one fixture per query, with a **childless** CLOSED row for R3 and R5, so each mutant fails on a count assertion that names that query.

**7. Low: §8.1 pre-mortem #1 is analysed wrongly.**

If someone added `@MockitoBean BillofladingPositionService` to the fixture, it would also mock `createEntity`, which PHASE D uses. AC-1's key assertion would go red and many ITs would break. It would not be "every IT green".

**Fix:** replace it with a scenario that could actually happen. Candidates:
- The facade and the backstop can't be told apart in production logs (finding 8).
- §3.3 lands and intercepts AC-6 (finding 9).

**8. Low-Medium: §6.5 observability can't tell which layer fired.**

There is one `LOG.warn` inside `assertPalletNotShipped`, and it is shared by all three call sites. The only production evidence that the race closure works is the backstop firing on scanGate after the facade passed, and that looks identical to a facade rejection.

**Fix:** pass a site tag, or add a distinct `LOG.warn` at the D0 call sites along the lines of "backstop fired after facade passed".

**9. Low: coupling between §3.3 and AC-6 is not recorded.**

If the source-is-Shipped check lands in `scanDestination` (via SBDEV-3442), AC-6's scenario is rejected earlier with a different message. AC-6 breaks, and Fix C loses its only IT coverage.

**Fix:** record the coupling. Also give AC-6 a variant where the pallet has a CLOSED position but is **not** on Shipped (for example, moved by jdbc), because that case is the one only Fix C protects.

**10. Low: claim discipline.**

- §5.5: `"the only construct that makes … true for C2"` is a closed-set claim that is false (see finding 1; an explicit flush or lock would also work).
- §8 R1: `"No reopen-BOL path writes positions back from CLOSED"` names no derivation. My grep found only one bulk writer of position state, `finishTransfer` at `BillofladingService:1512`. Cite that grep.
- The §5.3 code comment `"this read cannot be overtaken by a close"` drops the plan's own single-probe caveat. Keep "per ClosebolLockOrderProbeIT" in the comment.

**11. Low: §6.4 manual test step 1 and the AC-6 setup.**

- Step 1 uses `u.labelid ~ '<outbound regex>'`. PostgreSQL's `~` matches substrings, while Java's `matches()` matches the whole string. Anchor it: `'^(…)$'`.
- AC-6 doesn't name its destination. It has to be:
  - non-flowbin;
  - not `EmptyPallets`;
  - `entity_lock = 0`;
  - of a location type whose constraints allow the pallet's unitload type.

  Name a concrete fixture location.

**12. Low: length (599 lines).**

About 120–150 lines can go:
- §7 is 10 rows of "No"; two lines would do.
- §9.2 repeats §0 and §6.
- §1's DB table repeats analysis §8.
- The ADR's list of alternatives repeats the RALPLAN-DR summary.

Meanwhile the RALPLAN-DR principles and options themselves aren't in the plan. Add them as a short section so that a reviewer of the plan alone can check it against its principles.

---

### Claims I verified against the code
- `@MockitoBean OutboundPalletLabelGuard` at `AbstractTruckLoadingPgFixture:152` and `MobileTruckLoadingRollbackIT:152`. Neither mocks `BillofladingPositionService`; the other mocks are only `ManageOrderService` and `ItemdataService`. ✓
- `new MobileTruckLoadingService(` appears only at `MobileTruckLoadingServiceUnitTest:85` and `MobileTruckLoadingServiceTest:71`. ✓
- The `BillofladingPositionService` constructor takes only `ClientService`, the repository, `BasicService` and `UnitloadRepository` (`:25-28`), so there's no dependency cycle. ✓
- R3–R6 are called only from V1 and V2 in `src/main` (`MobileMoveUnitloadService:502,504,570,571`). ✓
- R5 and R6 are `clearAutomatically = true` with no `flushAutomatically`; R3 and R4 are `flushAutomatically = true` (`BillofladingPositionRepository:109-162`). ✓
- `git grep "'CLOSED'" src/main/java` finds nothing. `BillOfLadingState.CLOSED = "CLOSED"` is at `WmsConstants:261`. The key exists only in `messages_en_US.properties:331`. ✓
- `TruckLoadingWriteEntryPointArchTest:47` uses `DO_NOT_INCLUDE_TESTS`. ✓
- `ClosebolLockOrderProbeIT:64-65` records the order `unitload_record → unitload → stockunit → flush{billoflading_position,…}`. ✓
- `checkPallet` treats only CLOSED as shipped, with `findById(...).getName()`, else `getNumber()` (`MobileTruckLoadingService:97-113`). ✓
- There are no pending writes before D0 (the write-service comment at `:411-414`), so §5.3's claim that the auto-flush does nothing there holds. ✓
- The Shipped and Damaged locations are seeded in `V2.2.00`, so AC-6 can be set up. ✓
- **Refuted:** the §5.4/§8 R2 model of C2 (finding 1). **Missing:** the checked-exception ripple (finding 2).

### What must change for APPROVE
1. Rewrite the C2 race reasoning from the flush and `@Version` derivation (finding 1), and re-justify Fix D and A2 on that basis.
2. Document `throws BusinessException` on V1 and V2, and add the test file whose compilation breaks (finding 2).
3. Reorder AC-6's assertions and rewrite the STOP rule so it can actually fire (finding 3).
4. Say exactly which collaborators are real and which are mocked in AC-2 (finding 5).
5. Either make the pallet-row delete fail loudly on 0 rows, or correct the reason for keeping it silent (finding 4).

Findings 6–12 are cheap to fix and should go into the same revision.

---

### Verdict justification
I started in THOROUGH mode and escalated to ADVERSARIAL after finding 1, because the same unmeasured premise shows up in four sections, which points to a systemic cause rather than an isolated slip.

Realist check:
- Finding 1 stays High, not Critical. The code the plan would ship is correct; the reasoning is wrong in the places that shape Nam's §3.3 decision and the ADR.
- Finding 2 was downgraded to Medium. It is mitigated because the compiler catches it immediately; the remaining risk is only the wrapping workaround.

Deliberate-mode requirements are met, though one part is weak. The three pre-mortem scenarios are present, but #1 is analysed wrongly. The expanded test plan covers unit, IT, E2E and observability, and gives a defensible reason for having no concurrency test: AC-3's IT serialises the race's logical outcome.

### Open questions (unscored)
- Does Hibernate's HQL `executeUpdate` in `closeBOL` really leave the `saveAll` position updates unflushed until `:686`? The probe measures this order, so I accepted it, but it's a single probe.
- `coalesce(b.name, bp.number)` differs from `checkPallet` when `billoflading_id` is set but `b.name` is null (it renders the number, where `checkPallet` renders "null"). This is cosmetic.

---
*Ralplan summary:*
- **Principle/Option consistency: Fail (partial).**
  - P3 is broken in C2: a claim labelled "unmeasured" is actually derivable, and the derived answer contradicts R2.
  - Fix D is a silent layer.
  - P2 is scoped to scanGate only. That's acceptable under the decisions.
- **Alternatives depth: Fail (partial).** A2's rejection reason is wrong in code terms, and the throw-on-0 refinement was rejected on reasoning that doesn't hold. Options B, C, D and E are handled fairly, given the fixed decisions.
- **Risk/verification rigor: Fail.** R2 is mis-described, the STOP rule can't fire, AC-2 can pass vacuously, and AC-9's failures don't name the broken query.
- **Deliberate additions: Pass (weak).** The pre-mortem has 3 scenarios, one of them analysed wrongly. The expanded test plan is present.

Files: plan `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3487-evidence/plan-snapshot-r1.md`. Key code: `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java` (lines 523–543), `.../service/BillofladingService.java` (665–667), `.../service/mobile/MobileMoveUnitloadService.java` (488, 532), `.../src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTruckLoadingWriteServiceUnitTest.java` (124).