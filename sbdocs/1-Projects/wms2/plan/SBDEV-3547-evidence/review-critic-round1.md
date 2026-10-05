# SBDEV-3547 — critic review, round 1 (2026-09-27)

**VERDICT: ITERATE.** There is one High (finding 1), so a second consensus round is needed.

**Overall assessment.** The core mechanism is sound: at C1/C2, stock at lock 100 is a lookup-free proxy for "reversal owed", and the PR-A/PR-B split with a PRD gate is the right shape. But the plan has not yet taken in any of the architect's round-1 findings. One acceptance criterion (AC-D3, the adjustAmount half) cannot fail. Three test specifications would start red for the wrong reason, or would name a lane that doesn't exist. The rail census rests on a narrowed pattern that its positive control cannot catch.

**Mode.** I started in THOROUGH mode and escalated to ADVERSARIAL after finding 1 and three Mediums. Everything below was checked against `origin/develop` at `a5b36931`. The WineCo and ShipItEZ-NY PRD queries were read-only and run today.

**Pre-commitment predictions vs. what I found**
- **Tests green before the fix:** confirmed (findings 1 and 6).
- **Wrong test lane:** confirmed (finding 3).
- **Census instrument blind to its own rule:** confirmed (finding 4).
- **Cost of a settled decision under-measured:** confirmed (finding 5).
- **§7.3 flips mis-cited:** mostly correct. One flip is missing (finding 1b).

---

### Findings

**1. High: AC-D3's adjustAmount half cannot fail. D3's premise for M6 is false. (Concur with architect F1.)**
- **Evidence:**
  - `StockunitService.java:885-897`: `switch (stockUnit.getEntityLock())` allows only ON_HOLD, QUALITY_FAULT and NOT_LOCKED. Its `default:` arm throws `"unexpected lock=… value not changed"` before `changeAmount` at `:899`.
  - `StockunitServiceUnitTest.java:2498` `adjustAmount_pickedForGoodsout_doesNotCommit` already pins that 100 is refused.
  - The only callers are `StockUnitController:318/:360`.
- **What this breaks:**
  - The §7.1 row `adjustAmount_refusesPickedForGoodsout … | remove 100 from the predicate` is green on develop, which violates the floor.
  - Its named mutant survives, because `default:` still refuses.
  - §2 B3 (`"so it can zero a 100 SU"`) and the §0 M6 row (`Fixed, PR-B`) are both false.
  - D3 itself is not re-opened: "M6 refuses 100" is already true. What changes is where and how the plan implements it.
- **1b, a missing flip:** the planned B-3 message `"Can't set amount on stock unit … locked=100 (Picked)…"` does not contain `value not changed`. So `StockunitServiceUnitTest:2498`, which asserts `contains("value not changed")` at `:2528`, will flip. It is not listed in §7.3.
- **Changes to the plan:**
  - Rewrite §0 M6 and §2 B3 to say "already refused by the `default:` arm; the message is unactionable".
  - Move the adjustAmount change to PR-A as a message-only, fail-open change.
  - Replace the §7.1 row with `adjustAmount_lock100_messageCarriesGoodsOutHint`. It asserts the `goodsOutHint` substring, starts red today, and is killed by the mutant "drop the hint".
  - Add `:2498` to §7.3. Either keep `value not changed` in the new text or rewrite `:2528`.
  - For the rail, move `:869/:871` from `KNOWN_OFFENDERS` to `EXEMPT` with the reason "a denylist made redundant by the allowlist `switch` at :885". Or delete them in the PR-A rewrite.
  - Note in the rail's javadoc that here the `switch` is the real guard.
  - Tell Nam in one line that D3's M6 half was already in place on develop, so D3 reduces to "M7 plus a message".

**2. Medium: the `sendToClearing` swap test is specified against a non-mock, so it starts red with a Mockito error rather than an assertion. (Concur with F4. I raise it from Low because it breaks "red for the right reason".)**
- **Evidence:**
  - `UnitloadBusinessServiceUnitTest:95` uses `@InjectMocks` (no spy).
  - `sendToClearing` at `:691` self-calls `transferUnitLoadToLocation`. A `captor on transferUnitLoadToLocation args 5/6` gives `NotAMockException`.
  - What can be observed is `unitloadRecordService.recordForTransferUnitLoad(… activityCode, orderNumber, comment)` at `UnitloadBusinessService:542`.
- **Change:** capture arguments 8 and 9 of `recordForTransferUnitLoad`, and assert `orderNumber == "ORD-001"` and `comment == null`. Add F4's javadoc warning on `sendToClearing`'s `(comment, orderNumber)` order.

**3. Medium: the only IT is described as the wrong lane, and its fixture is not specified well enough to write.**
- **Evidence:**
  - §7.1 says `"CancelPreservesGoodsOutFenceIntegrationTest (Testcontainers, extends BaseRollbackIntegrationTest …)"`.
  - `BaseRollbackIntegrationTest` is **H2**: `jdbc:h2:mem:rollback_tenant`, `ddl-auto=create-drop`, Flyway off. It is not Testcontainers.
  - It runs with no test transaction, so every write commits and rows persist across methods. `CancellationReversalLockClearIntegrationTest:113-118` suffixes every fixture name for exactly this reason.
  - The precedent IT **seeds** lock 100 directly. It never runs `confirmPick` or `cancelOrder`.
  - Step 1 says "Pick 2 lines → OMS cancel" but doesn't say whether that means driving `confirmPick`, or seeding at 100 and then calling `cancelOrder(order,false)`.
  - It also doesn't list what must be mocked: `MessageService` is a `@MockitoBean` in the precedent, and the OMS notification path isn't mentioned. Nor does it list what must be seeded: Clearing, Nirwana, Shipped and Damaged locations, the Tote type row, a FlowBin type with its fix-location assignment, and the sequence rows.
  - Step 4 (MMU `scanDestination`) additionally needs `accessService` and the location-type graph.
  - The named mutant `"revert C1 → Move Stock succeeds"` is not what fails: step 2's lock assertion (0 ≠ 100) goes red first.
- **Change:**
  - Say "H2 full-context lane (`BaseRollbackIntegrationTest`), runs under failsafe; *IntegrationTest is excluded from surefire".
  - Specify the fixture: seed a picked tote at 100 with 2 log-eligible positions, then call the real `cancelOrder`. List the seeded rows and the beans to mock, and use per-run suffixes.
  - Name the attributable failure: "step 2: `entity_lock` expected 100, was 0".
  - Cut step 4 from the IT; the unit tests already cover it.
  - Drop the claim that this is the only lane seeing a *committed* lock. It sees the H2-persisted lock and the `refresh` re-read, and that is what matters.

**4. Medium: the rail census of "8" comes from a narrowed pattern, and the offence as written also matches three allowlist sites. PR-A's rail would be red on day one.**
- **Evidence:** the offence is defined as `"a source-lock comparison against a single non-zero constant"` inside a throw-guarded `if`, with only NOT_LOCKED comparisons exempt. Three in-scope sites satisfy that and are missing from both lists:
  - `MobileMoveUnitloadService:767`: `… != NOT_LOCKED && stockUnit.getEntityLock() != QUALITY_FAULT) throw`
  - `MobileMoveUnitloadService:804`: same shape.
  - `CancellationReversalService:288-291`: `Integer sourceLock = …getEntityLock(); if (… && sourceLock != PICKED_FOR_GOODSOUT) throw` (pattern 3).
- **Why the census missed them:** the census evidently dropped whole lines containing `NOT_LOCKED`. The "4 known MMU hits" control can't detect that narrowing.
- **Change:** define the offence at the level of the whole condition. Something like: "a throw-guarded condition whose lock comparisons are all `==`/`!=` against non-zero constants and which carries no `!= NOT_LOCKED` allowlist conjunct". Add a self-test with the `:767` shape that must **not** fire, and one with `== ON_HOLD` alone that must fire. Re-run the census with the final lexer and quote its output in §4.A4.

**5. Medium: D1's measured premise ("0 operator Tote moves") is false on WineCo, and R5 is stale.**
- **Evidence:** WineCo PRD, operator-initiated Tote `TRANSFER` over 365 days (almost all v1-era, since WineCo went live on v2 on 2026-09-26):
  - Clearing → StagingLane01/03/05/06: 17 moves.
  - Clearing → Club04: 1 move.
  - Clearing → PutAwayLane: 1 move.
  - FinishedPicking → StagingLane05/06: 3 moves. These are **live picked totes**, which D1 also refuses.
  - T-0082 went Clearing → StagingLane05 seven minutes after its cancel (22:28 → 22:35, 2026-09-15).
- ShipItEZ-NY PRD has 0 rows in 90 days. So all four tenants are now measured, yet R5 and Layer-2 row 5 still say "2 of 4".
- **Assessment:** this is not a wrong fix. Blocking the cancelled-tote hand move is the fence working as intended, and completeReversal is the replacement. But on WineCo it is a real floor practice, and the refusal also blocks about 3 live-tote moves a year, with a hint that doesn't apply to them.
- **Change:**
  - Replace R5 with these measurements.
  - Add a PR-B PRD-gate checklist item: brief the WineCo floor ("a cancelled tote stays at Clearing until it is completed or waived").
  - Record for Nam, without re-opening D1, that its premise now carries a measured WineCo cost.
  - Adopt architect §3's `arm` parameter on `MoveUnitloadSourceLockPolicy`, so narrowing to the carrier arm (`:514`) is a one-line change if Nam wants it.

**6. Medium: §6.2/§6.3 says "confirm each is red" but about 8 of the §7.1 tests are green regression guards by design.**
- **Evidence:** these pin today's behaviour and are green on develop:
  - `forceCancelOrder_packedArm_stillClearsParcelStock…`
  - `…_stillMovesPackageAtPickedForGoodsout`, `…_stillMovesQualityFaultOutOfDamaged`, `…_stillRefusesOnHold`, `…_noTypeLookupWhenNo100`
  - `closeBOL_writesNothing_whenNone`
  - `_lock104_hasNoGoodsOutHint`
  - "405/2 still refused, 0 allowed"
- An executor following "red first" will either stall or weaken them.
- **Change:** add a column to §7.1 marking each row RED-first or GREEN-guard. For each guard, name the mutant that must turn it red (the plan already names most of them).

**7. Medium: the RALPLAN-DR section is missing, so O1 and O2 have no options analysis.**
- **Evidence:** O1 and O2 both say `"See RALPLAN options"`, but neither the plan nor `SBDEV-3547-evidence/` contains such a section. The drivers exist only in the ADR, three bullets long.
- **Assessment:** O1 (an EXEMPT list with a stale-entry failure) and O2 (fail-open plus WARN, the `SourceContainerGuard` precedent, whose javadoc gives the same "no operator remedy for states that do not occur" reason) are both defensible, and consistent with the drivers. But the gate asks for the options with pros and cons, and they aren't there.
- **Change:** add a short RALPLAN-DR block: principles, drivers, and two or three options for each of O1 and O2 with a line each on why they were rejected. Also add architect §2's steelman (a distinct "pending reversal" lock state) to the ADR alternatives, rejected for scope under D2. Today the ADR omits the strongest alternative.

**8. Medium: PR-B's rail "green" comes from moving code out of the rail's scope. (Concur with F2.)**
- **Evidence:** the rail's scope is classes that call the four primitives, and `MoveUnitloadSourceLockPolicy` calls none of them. It still holds the two `== ON_HOLD` throws.
- **Change:** add the policy class to the rail's scope explicitly. Put its two ON_HOLD checks in `EXEMPT` with the reason "kept by D1". Add a self-test that fails if the Tote-100 branch is removed. Correct AC-6 to match.

**9. Low: the pool-slot claim in §7.5 row 9 is wrong. (Concur with F3.)**
- `afterCommit` runs before the outer connection is released, so it holds 2 slots briefly. Row locks are released; slots are not.
- **Change:** reword to "2 slots briefly, row locks released; bounded by the pending-row count". Keep the design: REQUIRES_NEW is necessary there.

**10. Low: B-2's null-safety must check `typeId == null` before `findById`. (Concur with F5.)**
- `findById(null)` throws `IllegalArgumentException` (precedent `CustomerorderService:1026-1027`).
- **Change:** say this explicitly and name it in `_toteTypeUnresolvable_`.

**11. Low: the C3 snippet doesn't match the code. (Concur with F6.)**
- `CustomerorderService:490-493` saves each row inside the lambda; there is no `saveAll`.
- **Change:** call `releaseUnlessGoodsOut(stockUnit)` inside the existing lambda.

**12. Low: `_noTypeLookupWhenNo100` with `verify(unitloadTypeRepository, never())` will go red spuriously on some scanDestination paths.**
- **Evidence:** MMU reads the type repository legitimately at `:490` (`findByName` PALLET), `:681` (`SourceContainerGuard`) and `:697` (`findById`).
- **Change:** scope it to `never().findById(any())`. Drive it through `scanUnitLoad`, or through the location-relocation arm of `scanDestination`.

**13. Low: the BOL unit tests need transaction synchronization set up.**
- `registerSynchronization` throws when synchronization isn't active. Existing closeBOL tests stay green only because the new repository mock returns an empty list.
- **Change:** say the non-empty tests call `TransactionSynchronizationManager.initSynchronization()`, invoke `afterCommit()` by hand, and clear in `@AfterEach`. Precedent: `PickingorderBusinessServiceUnitTest`. That is also what makes `_serviceLogNotWrittenInline` able to fail.

**14. Low: the mutation discipline contradicts itself.**
- §7.2 says `"Hand-rolled mutants are allowed only for the two IT steps"`, but §7.1's mutants for CustomerorderService, PickingorderBusinessService, MobileMoveUnitloadService and UnitloadService are hand edits.
- **Change:** "PIT for the four `util/` classes. Named hand mutants for the service sites, each run with the exact `-Dtest` selector, and the red output recorded."

**15. Low: two manual test steps don't discriminate.**
- Manual step 4's adjust-amount half is refused today as well (finding 1).
- **Change:** assert the new hint text instead. Also add step 0: run step 1 on the pre-PR-B build and observe lock 0, as the baseline.

**16. Low: F7 is correct and already mostly reflected in the plan.**
- **Change:** add one line naming `bulkDeleteContainer`'s pre-existing partial commit as out of scope. Use the existing `StockunitRepository.findByUnitloadIdIn` for the pre-run check.

### Verified as correct (no change)
- §7.3 citations:
  - `CustomerorderServiceUnitTest:4001-4014` (100 fixture asserting `NOT_LOCKED`) and `:2307/:2379` flip.
  - `PickingorderBusinessServiceUnitTest:1545`: the `stockUnit1` fixture at `:1559` is 100, so `:1593` flips; `:1594` (ON_HOLD) stays green. The plan's correction of A§7.1 is right.
  - The MMU "locked on hold" tests at `:321/:353`, `:1243/:1278` and `MobileMoveUnitloadServiceTest:431/:451` exist, and their text is kept.
  - The SBDEV-3490 ordering pin at `:690` exists.
  - No MMU test or IT uses a fixture at `PICKED_FOR_GOODSOUT`, so there are no hidden flips there.
- The swap at `:691` against the `:221` signature, and all 5 callers.
- `deleteUnitLoad` and `deleteUnitLoadRecursive` have no `@Transactional`, and the controllers always run `PreRun` first (`:115`, `:177`, `:207`).
- The BOL bulk UPDATEs at `:675-680` and `:1604-1609`, both methods `@Transactional`.
- `Integer entityLock`, so the `==` null-NPE claim holds.
- 19 in-scope rail classes.
- The waive `lockRetained` branch at `CancellationReversalService:603-617`.

### What's missing
- A PR-B PRD-gate checklist written out as rows: 3381 and 3548 on `/api/public/version` for each tenant, the WineCo briefing, and the R5 replacement.
- The M5 residual understates one case. If Move-to-Damaged merges the SU into an existing damaged SU, the log's `picktostockunit_id` points at a drained SU, which is a strand and not merely a visible refusal. Add this to R2.

### Architect findings
- Concur: F1 (High), F2, F3, F4 (raised to Medium), F5, F6, F7.
- Architect §3's synthesis: adopted in finding 5.
- None disputed. None is already addressed in the plan.

### Length (466 lines against ~350; about 110 lines can go without losing content)
- §3 ASCII diagram (about 18 lines). It restates §0 and §2; keep only the file table.
- §7.5 and §7.6 (about 28 lines). Collapse to three lines: "no in-JVM state, caches, jobs or new locks; afterCommit takes 2 slots briefly; tenant context still bound".
- §0 rows C5, C6, M4a/b, M8–M11 (about 6 lines). Merge into one "Unchanged, and why" row.
- §4.A2's "substring survives" bullet (about 3 lines). It duplicates §7.3.
- §5 file table (about 17 lines). Each §4 item already names its file; keep only the "no Flyway, sysprop or DTO change" line.
- ADR "Alternatives" and "Consequences" (about 12 lines). They duplicate §8 and §10; point to them instead.
- Layer-2 checklist "Reference" column (about 10 lines). Shorten each cell to a § pointer.
- §1 "Corrections to the ticket" (about 4 lines). Two lines are enough.

### Ralplan summary
- **Principle/option consistency:** Pass. O2's fail-open and the D1 choices match the drivers.
- **Alternatives depth:** Fail. The RALPLAN options that O1 and O2 cite are missing, and the steelman alternative is absent from the ADR (finding 7).
- **Risk and verification rigor:** Fail. AC-D3 can't fail, the swap test and the IT lane are wrong, the rail census is narrowed, and R5 is stale (findings 1–5).
- **Deliberate additions:** the pre-mortem is adequate in substance through §8. The expanded test plan fails on the IT specification and on the RED/GREEN classification (findings 3 and 6).

### Open questions (unscored)
- Can a Tote be scanned as a "pallet" in `MobileTruckLoadingWriteService` or as a source in `MobilePutAwayService:154`? A§0.2 lists controllers it didn't open as a blind spot, and M10's "not reachable" claim is asserted rather than traced.
- On WineCo, what happens to a tote after StagingLane05: is it hand-restocked through Move Stock? If so, the fence changes a real process there. That is covered by the briefing, but worth confirming with the floor.

Files: `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3547-fence-cancelled-stock-against-hand-moves.md`, `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3547-evidence/review-architect-round1.md`, `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3547-evidence/analysis.md`
