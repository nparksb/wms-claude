---
title: "SBDEV-3487 architect review r1"
snapshot_sha1: f321405a75813573b47c75c8c0e298ec2768a97f
---

## Verdict: SOUND-WITH-CHANGES

The design (A1: a facade guard, a throwing scalar backstop in V1 and V2, and the `(bp.state IS NULL OR bp.state <> 'CLOSED')` predicate on R3–R6) holds up against the code. Nothing I found makes it unsafe. Four things need changing before approval:
- §2's race argument leaves out `finishTransfer`, a second writer of CLOSED that takes its locks in the opposite order.
- §8 R2 describes an outcome the code doesn't produce.
- The snapshot has no Principles section and no RALPLAN section, but §5.5 line 356 points to one.
- The plan doesn't say that Fixes B and C force a checked-exception change to both D0 signatures.

---

## Steelman antithesis

**"Fix D is the wrong kind of guarantee. In every interleaving that can actually happen it is either unused or it turns a loud outcome into a silent one."**

- **V1 doesn't need it.** Fix B runs after B2. `closeBOL` has to take the pallet row before it can write CLOSED to the positions.
- **C2 doesn't need it either, if Hibernate flushes as documented.**
  - `scanDestination` changes a managed `Unitload`: `setStoragelocationId` then `save` at `UnitloadBusinessService.java:526-527`. `Unitload` inherits `@Version` from `AbstractBaseEntity.java:34`.
  - `closeBOL`'s bulk UPDATE bumps `u.version = u.version + 1` (`BillofladingService.java:664-671`).
  - The backstop is a native query. Through the JPA API, Hibernate flushes the session before a native query that declares no query spaces. So the pallet UPDATE is written before the backstop reads, and there are only two outcomes:
    - C2 takes the pallet row first. `closeBOL` then blocks, and nothing can overtake the backstop.
    - C2's UPDATE hits a committed close. The version check fails and the whole move rolls back with a 409.
  - Either way no delete commits. C2 is as race-free as V1, just by a different route.
- **What Fix D adds is a silent skip on four shared statements.** In the one case where it fires with nothing else guarding (a future caller, or a backstop that has been mocked or removed), the pallet ends up on two BOLs. That silently breaks R1 (`IncorrectResultSize`) and R2 (`21000`) for that label from then on.
- **The honest version of the antithesis:** decision 3 already buys defence in depth. Fix D is a fourth layer that fails silently, and the plan justifies it with an A2 rejection ("unmeasured flush timing") that the `@Version` check largely answers.

**Why A1 still wins, and the plan doesn't say why.** The flush timing *does* matter, through a path the plan never mentions: R6 and R5 are `@Modifying(clearAutomatically = true)` (`BillofladingPositionRepository.java:109,115`).
- If the pallet UPDATE were **not** flushed before R6, R6's `EntityManager.clear()` would throw it away. The `@Version` check would never run, and without Fix D the CLOSED rows would be deleted and committed.
- So without Fix D, C2's safety depends on flush timing and on `clearAutomatically`. That is a real reason to keep Fix D. It is not the reason §5.5 and the ADR give.

---

## Tradeoff tensions and synthesis

**T1. Silent skip or loud failure (Fix D).**
- The plan turns down "return `int` and throw on 0" because a legitimate second concurrent move also gets 0 rows (§5.5).
- **Synthesis:** make R3 and R5 return `int`. When the count is 0 and R1 returned non-null, call `assertPalletNotShipped(label)` again.
  - Under READ COMMITTED, a statement after a DELETE that waited sees what the other transaction committed.
  - Row gone (a legitimate concurrent move): the re-check passes. Row now CLOSED: the re-check throws.
  - This separates exactly the two cases the plan says it can't separate. Cost: about 3 lines per variant, plus `void`→`int` on two repository methods. It is optional, because no reachable interleaving triggers it today (see Verified 3).

**T2. §3.3 proposal against Fix C.**
- The one-line source-is-Shipped check in `scanDestination` (mirroring `scanUnitLoad`) closes C2 **before** `transferUnitLoadToLocation` runs. It covers non-outbound labels too, and it runs whether or not the pattern sysprops are configured.
- Fix C only catches C2 after the move and only inside `if (matches)`.
- Decision 3 fixes Fix C in place. Still, the stronger and simpler guard for this path is the one the plan leaves out of scope.
- **Synthesis:** the plan handles it correctly under ticket policy (proposed, T3). Nam should know that folding §3.3 into this ticket would make Fix C a pure backstop and remove R2 entirely. The ticket is `pending approval`, not `on dev`, so the carve-out doesn't apply.

**T3. One choke point or duplicated call sites.** The existing javadoc deliberately keeps V1 and V2 separate (`MobileMoveUnitloadService.java:510-531`). The result is three call sites plus four predicates, rather than one guarded purge method. I accept the duplication. AC-5 and AC-9 pin it, and that is the right answer to the "someone tidies it" risk in pre-mortem 2.

---

## Principle violations

**The snapshot has no Principles section**, and it has no RALPLAN options section even though line 356 says "covered in the RALPLAN option A2". I can't check against five principles the document doesn't contain. That is a finding in itself (F3). I checked against the principles the ADR drivers and §5.2 imply:

| Implied principle | Status |
|---|---|
| P1. No lock before a rejection (SBDEV-3474) | **Held.** The facade calls the finder before the write transaction opens (`MobileTruckLoadingService.java`, scanGate, before the `try`). The finder is an unlocked SELECT. |
| P2. Scalar only, first-touch rule (SBDEV-3244) | **Held.** The native finder returns `String`. Nothing is dirty before D0: I grepped for setters, `save`, `persist`, `merge`, `executeUpdate` and `refresh` between `MobileTruckLoadingWriteService.java:251` and `:427` and found none, so the backstop's auto-flush does nothing. |
| P3. Test-lane honesty (the guard isn't on a mocked bean) | **Held.** A grep of all of `src/test` finds no `@MockitoBean` or `@MockBean` of `BillofladingPositionService`. The fixture mocks only `ManageOrderService` and `OutboundPalletLabelGuard` (`AbstractTruckLoadingPgFixture.java:141,152`). |
| P4. Invariant over instance | **Held**, through Fix D. |
| P5. Fail loud, not silent | **Minor violation.** Fix D can skip silently. §5.5 admits it. T1's synthesis removes it. |
| Claim discipline (repo standing rule) | **Violated twice (Medium).** §2 says "a check that runs after B2 is race-free" but covers only `closeBOL` (F1). §2 also calls the position-write placement "measured", but the probe never checks `billoflading_position` (F6). |

---

## Verified claims (with code citations)

1. **`closeBOL` locks the pallet before it writes CLOSED to the positions. Confirmed** by the probe (unitload before customerorder) and by reading the code:
   - Position `setState(bolState)` runs on managed entities (`BillofladingService.java:532,541,588`). The only flush is `entityManager.flush()` at `:696`, after the bulk `UPDATE Unitload` at `:664-671`.
   - Nothing between them triggers an auto-flush of positions. The JPQL at `:617` is on the Unitload query space, `findAllById` runs on Location and UnitloadType, and `unitloadRecordRepository.saveAll` inserts on its own table.
   - Caveat: `ClosebolLockOrderProbeIT` checks only unitload against customerorder (`:275-318`). The `billoflading_position` placement comes from its javadoc plus code reading, not from an assertion. Follow-up (b) admits this.

2. **`finishTransfer` is a second writer of CLOSED, and the plan leaves it out.**
   - Its order: `findByIdForUpdate(bol)` (`:1485`), then an **immediate** bulk `UPDATE BillofladingPosition … state = CLOSED` (`:1511-1516`), then `UPDATE Unitload` (`:1590-1597`). Callers: `BillOfLadingController.java:480`, `OrderRestController.java:831`.
   - On a TRANSFER pallet (re-scannable under decision 2), the scanGate backstop **can** be overtaken:
     1. FT has written uncommitted CLOSED.
     2. The backstop reads the committed TRANSFER and passes.
     3. R4 waits on FT's row locks.
     4. FT waits on B2's pallet lock.
     5. PostgreSQL detects the deadlock (`40P01`) and aborts one side.
   - Neither abort deletes CLOSED: if FT aborts, the rows stay TRANSFER and are deleted legitimately; if scanGate aborts, nothing happens.
   - `40P01` becomes `DeadlockLoserDataAccessException`, a `PessimisticLockingFailureException`, and the facade's `catch` turns it into the existing lock-contention response.
   - Safety here comes from **deadlock detection, not from the backstop**, and not from Fix D. Analysis §5 line 160 says this. The plan dropped it.

3. **Plan risk R2 (the C2 residual) doesn't happen the way the plan says.**
   - `scanDestination` loads the source without a lock (`MobileMoveUnitloadService.java:~301`, `findByLabelid`). But `processTransfer` changes the managed, versioned `Unitload` (`UnitloadBusinessService.java:526-527`).
   - **If** the native backstop query flushes (Hibernate's JPA-API native-query behaviour), a close committed before the flush makes the UPDATE fail its version check. The result is a 409 with everything rolled back, not "moved out of Shipped with CLOSED positions intact".
   - **If** it doesn't flush, R6's `clearAutomatically` throws the pallet UPDATE away. The pallet **stays** on Shipped, Fix D keeps the positions, and the IDENTITY-inserted `unitload_record` rows commit as a phantom move.
   - Neither world matches R2's text.
   - Indirect evidence that the flush does happen: if it didn't, every outbound-pallet move through `scanDestination` today would lose its location change at R6's clear.

4. **Fix D's semantics are correct.**
   - `BillofladingPosition extends AbstractBaseEntity` with no inheritance, secondary table or collection tables, so the JPQL bulk DELETE becomes a single SQL `DELETE … WHERE id=? AND (state IS NULL OR state<>'CLOSED')`.
   - PostgreSQL re-checks the WHERE clause against the updated row (EvalPlanQual) for any UPDATE or DELETE, whoever sent it.
   - **The IS NULL arm is needed:** `billoflading_position.state` is nullable (`character varying(255)`, `V2.2.00__base_v2_schema.sql:695`).
   - **Referential integrity:** R4 deletes both lower levels in one statement (`carrierId IN` children ids plus the pallet id, per R2's UNION ALL, `:95-107`).
     - Mixed tree with children CLOSED and the pallet not: R4 skips the children, R3 deletes the pallet, and the NO ACTION FK position→position raises `23503` at the end of the statement. That surfaces as a `DataIntegrityViolationException`, which is not caught by the facade's `PessimisticLockingFailureException` catch, so it is a 500 and a full rollback. It fails loud.
     - The reverse mix (pallet CLOSED, children not) never reaches the deletes, because the backstop throws first.
     - This is the right behaviour, and analysis §4.2 line 150 states it. **The plan does not** (F4).

5. **Placement on `BillofladingPositionService` is safe.**
   - Its dependencies are `ClientService`, `BillofladingPositionRepository`, `BasicService` and `UnitloadRepository` (`BillofladingPositionService.java:17-23`). Neither service depends on either mobile service, so there is no cycle.
   - It is already injected into `MobileMoveUnitloadService` (`:66,93,116`).

6. **Fix C's rollback covers everything.**
   - `scanDestination` is `@Transactional(tenantTransactionManager, rollbackFor = {BusinessException, FacadeException})` (`:287`).
   - `transferUnitLoadToLocation` → `processTransfer` → `unitloadRecordService`, `pickLineRealignmentService`, `replenishmentOrderSourceSyncService`. None of these files contains `REQUIRES_NEW`, `afterCommit`, `registerSynchronization`, `TransactionalEventListener`, or an outbox or OMS call.
   - Caveat: I checked the classes directly on the path, not every callee they reach.

7. **The scalar finder matches checkPallet.**
   - It selects the same rows as `checkPallet`'s `getBySourceUnitLoadLabelId` (a `source_id` join), so keying on the pallet-level row gives the same result as checkPallet.
   - `coalesce(b.name, bp.number)` differs only when the BOL exists but its `name` is null. There, checkPallet shows `null` and the finder shows `bp.number`. That difference is harmless.
   - `limit 1` is legal in H2.
   - The 0 mismatches in the data are enough, because Fix D protects the child rows on its own.

8. **The existing D0 variants declare no checked exception.** `handleTruckOffLoading(String)` (`:488`) and `handleTruckOffLoadingNoClear(String)` (`:532`) declare nothing. `BusinessException extends Exception` (`exceptions/BusinessException.java:14`). Both callers already declare it and roll back for it (`MobileTruckLoadingWriteService.java:249-251`, `MobileMoveUnitloadService.java:287`).

---

## Findings

| # | Sev | Plan location | Finding | Concrete change |
|---|---|---|---|---|
| F1 | **Medium** | §2 "Why a facade guard alone is not enough"; §5.3 comment; ADR "Why chosen" | "Race-free after B2" is stated as a general claim, but `finishTransfer` writes CLOSED **before** it takes the unitload lock (`BillofladingService.java:1511` then `:1590`). The backstop can be overtaken there. Safety comes from the `40P01` deadlock (Verified 2). | Add one paragraph to §2: FT's order, the deadlock, that neither victim deletes CLOSED, and that it is mapped to 409. Reword the §5.3 code comment to "cannot be overtaken by closeBOL; finishTransfer deadlocks instead (40P01)". |
| F2 | **Medium** | §8 R2; §5.4 race note; §5.5 "Residual"; ADR consequence 4; ADR A2 rejection | R2's outcome is wrong (Verified 3). The A2 rejection gives the wrong reason: the real dependency is R6's `clearAutomatically` discarding an unflushed pallet UPDATE and with it the `@Version` check. | Rewrite R2: "flushed: C2 is race-free, like V1 (pallet row lock or a @Version 409); unflushed: R6's clear discards the move, Fix D keeps the positions." Replace the A2 rejection reason with the clearAutomatically argument. Add a positive control to AC-6's class: a TRUCK_LOADING outbound pallet moved by `scanDestination` really changes `storagelocation_id`. That turns "likely auto-flush" into a measurement. |
| F3 | **Medium** | line 356; whole document (deliberate mode) | It points to "RALPLAN option A2", which isn't in the snapshot. There is also no Principles or Drivers section to review against. | Add a short RALPLAN block: 5 principles, 3 drivers, options A1/A2/B–E with one line each. Remove the options restated in the ADR so the list lives in one place. |
| F4 | Low | §5.5 bullets | The plan doesn't state what happens with a mixed-state tree: `23503`, then a 500 and a full rollback (Verified 4). The analysis states it. | Add one bullet saying it fails loud, and why that is intended. |
| F5 | Low | §5.3, §5.4, §5.7 | Both D0 variants must gain `throws BusinessException`. The test fallout is small: the 4 direct callers already declare `throws BusinessException` (for example `MobileMoveUnitloadServiceUnitTest.java:534,550,896`). But "the same two lines" understates the change, and it changes the method contract. | State the signature change in §5.3 and §5.4. Note that both callers already roll back for it. |
| F6 | Low | §2 "closeBOL's measured lock order … writes CLOSED" | The probe measures unitload against customerorder. The `billoflading_position` flush placement comes from its javadoc and code reading. | Say "measured (unitload) plus code-read (the position flush at `:696`)". |
| F7 | Low | §6.2 AC-2 | "Stub the finder" and "`verify(repo, never())`" assume a real `BillofladingPositionService` over a mocked repository inside `MobileTruckLoadingServiceUnitTest`. The facade depends on the service, so the natural test mocks the service. | Pick one: mock the service and verify `assertPalletNotShipped` is never called. AC-8 already covers the finder. |
| F8 | Low (optional) | §5.5 "Rejected refinement" | That rejection is answered by T1's synthesis (re-check on 0 rows). | Adopt it, or say why a silent skip is acceptable for future callers. |
| F9 | Low | §3.3 | The proposal is correct, but the plan doesn't say that adopting it makes R2 impossible and Fix C purely a backstop (T2). | One sentence, so Nam can weigh folding it in. |

No High findings. No race or rollback defect lets a CLOSED delete commit.

---

## Length cuts (599 lines now; about 280 is reachable)

| Section | Lines | Action |
|---|---|---|
| §7 Horizontal scalability | ~16 | Collapse to one line: no state, no new lock, +1 indexed SELECT. Ten rows of "No" add nothing. |
| §9.1 and §9.2 checklists | ~30 | Delete. Every row points back to a section that already says it. |
| §10 Resolved decisions | ~14 | Delete. Decisions 1–3 are fixed inputs, and 4–9 repeat §5 and the ADR. Keep one line per decision inside the ADR. |
| §5.1 Prerequisites | ~13 | Replace nine N/A rows with one line. Move row 9 (freshness) into Step 1, where it is already mentioned. |
| §4 key-file table | ~10 | Duplicates §5.7. Keep one of the two. |
| §5.2 "Why here, and not the alternatives" plus ADR alternatives | ~25 | This is the same argument twice. Keep it in one place, the RALPLAN block from F3. |
| §6.5 Expanded test plan | ~10 | The Unit and IT rows repeat §6.2, and E2E repeats §6.4. Move the Observability row to §8 and delete the rest. |
| §8.1 pre-mortem 1 and 2 | ~12 | They repeat the Mutation column of §6.2. Keep pre-mortem 3, the operational one. |
| §0 D1–D3, S1–S4 rows | ~8 | Collapse the excluded rows into one "excluded, see analysis §0" line. Keep R1–R6, V1–V2 and C1–C2. |
| §5.6 doc table | — | Keep. The four-place correction to the workflow doc is real value the analysis missed. |

---

## References

- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/BillofladingService.java:354,447,532-588,664-671,696` (closeBOL); `:1479-1516,1590-1605` (finishTransfer, positions before unitload)
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/java/net/aim_ai/wms/integration/service/ClosebolLockOrderProbeIT.java:63-65,118-120,275-318`: what is and isn't measured
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/repo/jpa/BillofladingPositionRepository.java:87-162`: R1–R6; `clearAutomatically` at `:109,115`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java:287-288,370-378,488-505,532-574`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java:221-247,522-527`: the source isn't locked; managed versioned Unitload save
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingWriteService.java:249-251,410-427`: rollbackFor; nothing dirty before D0
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingService.java`: scanGate facade and try/catch; checkPallet `:94-114`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/BillofladingPositionService.java:17-25`: no cycle
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/java/net/aim_ai/wms/integration/service/mobile/AbstractTruckLoadingPgFixture.java:141,152`: the only mocks
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:695`: `state` is nullable
- `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3487-evidence/analysis.md:150,160`: the FK fail-loud and finishTransfer-deadlock statements the plan dropped
- `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3487-evidence/plan-snapshot-r1.md`: reviewed unmodified, sha1 `f321405a75813573b47c75c8c0e298ec2768a97f`