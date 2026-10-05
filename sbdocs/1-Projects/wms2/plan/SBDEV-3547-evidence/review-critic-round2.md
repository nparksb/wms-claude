# SBDEV-3547 — critic review, round 2 (2026-09-27)

**VERDICT: APPROVE.** No High or Medium findings remain. All 16 round-1 findings, both "What's missing" items and both open questions are addressed. I found five new Lows, all text edits to the plan (L1–L5 below). The planner should apply them together with the architect's N1–N4 before the TDD gate.

**Mode:** I stayed in THOROUGH mode throughout. Nothing met the escalation bar. Everything was checked against `origin/develop` at `0ac108e2`. I re-ran `rail-census.py`, and I ran its `scan()` on the code shapes PR-B would add (L1).

**Pre-commitment predictions and what I found**
- **RED tests that start green, or red for the wrong reason:** none among the service tests. The only exceptions are new-class and new-method tests, which start as compile errors (L5).
- **A GREEN guard whose mutant cannot reach it:** partly true. The rail's stale-entry check cannot see duplicate snippets (L2).
- **Round-2 code not measured against the rail:** confirmed. B-3 and A5 are likely to trip the rail, and the plan's counts leave them out (L1).
- **IT fixture holes:** small ones remain (L4).

### Round-1 status

| # | Status | Where / verification |
|---|---|---|
| 1 | ADDRESSED | §0 M6, §2 B3, §4 A5, §7.1, §7.3, A4 (:869/:871 moved to EXEMPT), §10 D3′. The new `adjustAmount_lock100_…` test asserts the hint, which does not exist yet, so it starts red, and the mutant "drop the hint" kills it. Residual: L3 |
| 1b | ADDRESSED | `value not changed` is kept. The `StockunitServiceUnitTest:2528` helper stays green, as long as L3 is applied |
| 2 | ADDRESSED | Arguments 8 and 9 of `recordForTransferUnitLoad` are `orderNumber` and `comment` (`UnitloadRecordService:41`, called at `UnitloadBusinessService:542`). The existing `SendToClearing` test at `:856-880` already drives the real path to `:542`, so a captor there can be written |
| 3 | ADDRESSED | The lane is correct (`pom.xml:588` excludes the IT from surefire, `:753` includes it in failsafe). Fixture, mocks, suffixes and the step-2 failure message are specified. `cancelOrder`'s `orderCanBeCancelled` arm is reachable with the stated fixture: regular section, positions below PACKED (`CustomerorderPositionService:59-113`). Residual: L4 |
| 4 | ADDRESSED | The rule now works on the whole condition, has a reporting-stage control and self-tests, and the census is quoted. My re-run on `0ac108e2` gives 19 classes and 8 offenders, identical output. **I concede the plan's correction:** `CancellationReversalService:289` carries `!= NOT_LOCKED`, so it is not an offence. Residuals: L1, L2 |
| 5 | ADDRESSED | §8 R5 (four tenants), G3, and D1′ superseding D1 |
| 6 | ADDRESSED | §7.1 now has a Kind column. Every GREEN mutant I traced does turn its test red. `CancelLockRelease`'s `equals`→`==` mutant NPEs on null. The `toteTypeIdNull` guard works because Mockito's `any()` matches null |
| 7 | ADDRESSED | §5 table; the steelman alternative is in the ADR |
| 8 | ADDRESSED | By construction: MMU is in the rail's scope. See L1 for the counts |
| 9–11 | ADDRESSED | §4 A3 and §7.5; B-2 `isToteType`; B-1 inside the lambda |
| 12 | ADDRESSED | Checked: MMU `:681`/`:697` are reached only through `transferStock`, so the existing-pallet carrier arm reads the type repository nowhere else |
| 13 | ADDRESSED | Precedent `PickingorderBusinessServiceUnitTest:1692/:1765` checked. `BillofladingServiceUnitTest:145` constructs the service with `new` (see L5). `BolCloseGuardPerTenantUnitTest:57` uses `@InjectMocks`, but every one of its tests throws before the bulk UPDATE, so the null new repository is never reached |
| 14–16 | ADDRESSED | §7.2; §7.4 steps 0 and 4; B-3's out-of-scope line and `StockunitRepository.findByUnitloadIdIn:426` |
| Missing: PRD gate rows | ADDRESSED | §6.1 G1–G4 |
| Missing: M5 merge strand | ADDRESSED | §8 R2(b) |
| Open question: Tote as pallet / putaway source | ADDRESSED | §0 Reachability (label guard plus PRD controls) |
| Open question: WineCo after StagingLane05 | ADDRESSED | R9: one hand-restock row |
| D1′ tests at `:485` / `:512` | Sound | Call sites confirmed at `:485` (under `!isMoveStock`, before `createUnitload` at `:492`) and `:512` (before `:514`). If the `:485` call is deleted, `:512` still refuses, but `never().createUnitload` goes red, so the inbound test does discriminate. The carrier-arm precedent exists at `MobileMoveUnitloadServiceUnitTest:1563-1720` |

### Architect round 2
- **N1: concur.** `MMU:703-722` sends a Tote to EmptyTotes (`:707`), never to Clearing. The "upper bound" caveat names the wrong mechanism.
- **N2: concur.** Checked: `setCarrierunitloadId(` writers are only `BillofladingService:865`, `ParcelMonitorViewService:322` and `UnitloadBusinessService:503`, and `scanParcelBulk` resolves through `:561`.
- **N3: concur.** It pairs with L1 and L2. The RED MMU tests are what pin D1′. The rail's entry only pins the literal text.
- **N4: concur.** The frontmatter and line 32 still say `a5b36931`.

### New findings (all Low)

**L1. The rail counts in AC-6 leave out B-3, and possibly A5. PR-B's rail would be red on day one.**
- **Evidence:** `UnitloadService` is in the rail's scope, because it calls `.transferStockToUnitLoad(` at `:175`. I ran `scan()` on the three natural B-3 shapes and all three are reported as offenders:
  - a loop with `if (Integer.valueOf(PICKED_FOR_GOODSOUT).equals(su.getEntityLock())) throw`
  - an inline `if (list.stream().anyMatch(su -> …equals(su.getEntityLock()))) throw`
  - `if (su.getEntityLock() == …PICKED_FOR_GOODSOUT) throw`
- Only a `boolean fenced = …; if (fenced) throw` shape passes.
- A5 is in `StockunitService`, which is also in scope. If A5 is written as `if (lock == PICKED_FOR_GOODSOUT) throw …+hint` it is flagged too. The plan does not fix either shape, yet AC-6 says `"PR-B green with 9"` and §4 A4 says `"PR-B rewrites none of these sites"`.
- **Realist check:** this would show up on the first test run and is cheap to fix, but the executor would have to invent an EXEMPT entry nobody reviewed. That is why it is Low and not Medium.
- **Change:**
  - Add a B-3 EXEMPT entry, `"D3′ destroy guard; single-value refusal by decision"`. Update AC-6 and §6.3 step 2 to "PR-B green with 10", and require that removing the B-3 check turns the rail red too.
  - For A5, state the shape: append the hint with a ternary inside the existing `default:` throw, so no new `if…throw` is added.

**L2. The stale-entry check cannot see the removal of one site from a duplicated pair.**
- **Evidence:** the census condition text is identical for MMU `:169` and `:365` (`stockUnit.getEntityLock() == …ON_HOLD`), for `StockunitService:869` and `:918` (`== SHIPPED`), and for `:871` and `:920` (`== GOING_TO_DELETE`).
- A `file + condition snippet` key therefore gives 5 distinct keys for 8 entries. Deleting `:365` or `:918` leaves each key still matched, so nothing goes stale.
- AC-6's `"A stale entry … fails"` and §7.1's mutant `"remove an EXEMPT site"` both overclaim.
- **Change:** either make EXEMPT a multiset with an expected count per key, or key entries on `file + enclosing method + snippet`. Name `:365` as the mutant for the stale-entry self-test.

**L3. A5's label lookup has no fallback specified, so an `orElseThrow` would flip `:2498`.**
- **Evidence:** `testStockunit` has a non-null `unitloadId` (`StockunitServiceUnitTest:170`). `unitloadRepository.findById` is not stubbed in `:2498`, so it returns `Optional.empty()`.
- An `.orElseThrow(EntityNotFoundException)` in the `default:` arm would replace the expected `BusinessException`, and `adjustAmount_pickedForGoodsout_doesNotCommit` would go red.
- **Change:** in §4 A5, write it as `findById(…).map(Unitload::getLabelid).orElse("this container")` (fail-open, as O2 does), with a null check on `unitloadId` first. Also state that `:2498` stays green without any new stubbing.

**L4. The IT seeds `Clearing` per method, and it leaves out EmptyTotes and Nirwana.**
- **Evidence:** in §7.1, `(once)` attaches only to `Spawn`. `sendToClearing` resolves `findByName(STORAGE_LOCATION_CLEARING)` into an `Optional`. With a second `Clearing` row, the second method gets a non-unique result.
- `cancelOrder`'s `catch (Exception e)` then wraps that as `ToteTeardownException` (`CustomerorderService:1062-1073`). The failure looks like a defect in the code under test, which is the trap the precedent warns about in its `:190` comment.
- Step 4 (`completeReversal` emptying the tote) and the §7.4 step 5 expectation both need EmptyTotes. The precedent gets-or-creates EmptyTotes at `:675` and Nirwana at `:1114`.
- The pickingorder's own state is also not given. It must be below PACKED for `canOrderPositionBeCancelled`.
- **Change:** get-or-create Clearing, EmptyTotes and Nirwana once per context (citing `:675` and `:1114`), and state "pickingorder state PICKED (below PACKED)".

**L5. Four RED rows will start as compile errors, not assertion failures.**
- **Evidence:** these rows have no code to compile against on develop:
  - `LockRefusalMessagesUnitTest` and `CancelLockReleaseUnitTest` (new classes)
  - the two BOL RED tests (`findPendingReversalsOnPallets` doesn't exist)
  - `BillofladingServiceUnitTest:145` calls `new BillofladingService(...)` explicitly, so adding a constructor parameter breaks every test in that class until the call is updated
- **Change:** in §6.2 step 1, first add skeletons (the class, the repository method, and the constructor parameter with a `@Mock` in `:145`). Each RED test must then fail on an assertion, and its message should be recorded.

### Verdict justification
- Everything that decides whether the fix is correct checks out against `0ac108e2`:
  - D2's lock-value predicate
  - D1′'s placement on the carrier arm
  - the B-3 ordering relative to `:583`, `:590` and `:596`
  - the swap-test captor
  - every §7.3 flip
  - the shape of the BOL `afterCommit`
- Each RED test either fails today for an assertion reason or becomes one once L5's skeletons exist. Each GREEN guard has a mutant that reaches it, except the duplicated-key case in L2.
- **Realist check:** L1 would have been Medium, but it is detected on the first run and fixed with one EXEMPT entry consistent with the settled D3′. None of the five findings touches production behaviour.

### Open questions (unscored)
- The IT run command combines `-Dit.test=X` with `-Dsurefire.failIfNoSpecifiedTests=false`, which only matters alongside `-Dtest`. As written, it runs the full surefire lane before failsafe, which is slow but correct. Consider checking it against the "Running ONE wms2 integration test" recipe in memory.
- §4 A3 says `idx_cancel_log_reversal_pending` serves the query. The index leads with `(tenant_name, facility_code, …)` and is partial, so the planner can use it only as a scan of the partial index. That is harmless at 4 pending rows, but the word "served" overstates it.

---
**Ralplan summary**
- **Principle/option consistency:** Pass.
- **Alternatives depth:** Pass. §5 covers four decisions, and the steelman is in the ADR.
- **Risk/verification rigor:** Pass with the Lows. L1 and L2 affect the rail's own claims, not the fence.
- **Deliberate additions:** Pass. The pre-mortem has 3 scenarios mapped to G1–G3 and R9/R10. The test plan covers unit, H2 IT, mutation and manual testing, with the observability rows for A3.

Files:
- `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3547-fence-cancelled-stock-against-hand-moves.md`
- `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3547-evidence/rail-census.py`
- `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3547-evidence/review-architect-round2.md`

I did not write this report to disk, because this lane is read-only. The parent should save it as `SBDEV-3547-evidence/review-critic-round2.md`.
