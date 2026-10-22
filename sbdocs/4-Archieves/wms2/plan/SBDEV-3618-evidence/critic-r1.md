**VERDICT: ITERATE**

**Overall Assessment.** The diagnosis is right. The live case reproduces on DEV: REPL389503 has requested 26 on SU 30685299 at 18/18. The population query reproduces exactly: 565 / 53 / 393 / 2 / 93 / 0. The booking rule `delta = desired − held` with `capacity = held + free` is arithmetically sound for the single-holder case, and I checked that it converges for the two-holder case. The plan does not survive contact with the test suite, though. It claims existing suites "stay unchanged", and they cannot: the SBDEV-3605 tests and at least five existing ROMS unit tests pin the exact arithmetic this plan changes. Two acceptance tests are vacuous or underspecified on current code. One lock claim, one "never throws" claim and one query-count claim are false against `origin/develop` @ `652f37f7`.

**Pre-commitment predictions vs. actual**

| Prediction | Result |
|---|---|
| (1) "Tests pass unchanged" is false | **Confirmed**, twice (H-1, H-2) |
| (2) The "under the SU lock" claim has an unlocked path | **Confirmed**: the move path (M-1) |
| (3) Some ITs are vacuous on current code | **Confirmed**: IT-2 and IT-3 (M-5, M-6) |
| (4) §0 missed a release site | **Confirmed**: `ReplenishorderService:280` (M-3) |
| (5) Alternatives are thin | **Confirmed** (M-7) |

---

### High

**H-1. "SBDEV-3605 suites pass unchanged" is false, and U-8 contradicts it.**
- **Plan text:**
  - §3 Fix A: `Its package-private method stays as a one-line delegate, so the SBDEV-3605 unit tests and MultiUnitLoadOwnShareContractUnitTest stay unchanged`
  - §8 U-8: `delegates (a verify on the mock). The SBDEV-3605 suites (164 plus contract) pass unchanged`
- **Evidence:** `MobileReplenishServiceUnitTest` builds the service with `@InjectMocks` (`:130`). It exercises `ownShareOfReservation` through the *repository* mocks:
  - `:4414-4420` stubs `replenishorderRepository.sumRequestedAmountOfOtherOpenOrdersOnStockunit(...)` and `pickingorderPositionRepository.sumOpenAmountByPickfromstockunitId(...)`, then calls the helper by reflection and asserts `share == 0`.
  - `:4564-4566` asserts `inOrder.verify(replenishorderRepository).sumRequestedAmountOfOtherOpenOrdersOnStockunit(25L, …); inOrder.verify(pickingorderPositionRepository).sumOpenAmountByPickfromstockunitId(25L, …)` between the SU locks and `changeReservedAmount`.
  - `:4393`, `:4455`, `:4496` and `:661`/`:3975` drive release amounts through the same repository stubs.
- **Why it breaks:**
  - If `ownShareOfReservation` delegates to a new `ReservationShareService`, `@InjectMocks` either passes `null` for the new constructor parameter (an NPE; the SBDEV-3091 trap this file documents at `:90`), or injects a `@Mock`.
  - A `@Mock` returns `null` for `BigDecimal` and never touches the repository mocks. The reflection test then NPEs, the inOrder verify fails, and strict stubs flag the unused repository stubs.
  - U-8 needs the service to be a mock (to verify on it). The unchanged-suite claim needs it to be real. Both cannot hold.
- **Fix:** Pick one and say so.
  - (a) In `MobileReplenishServiceUnitTest`, build a *real* `ReservationShareService` over the existing repository mocks. That needs `@Spy` plus manual construction, so it is a test edit and must be listed. Drop U-8's "verify on the mock" and replace it with a behavioural equivalence pin.
  - (b) Or make the invariant a static pure function `ownShare(res, others, picks)` that both services call, each keeping its own two queries. The existing tests then truly stay unchanged. This is the "duplicate the queries, share the arithmetic" alternative the plan never weighed.

**H-2. Existing ROMS tests pin the old arithmetic on under-reserved fixtures. The plan neither enumerates them nor handles the mock.**
- **Plan text:** §7 `ROMS @InjectMocks tests get a null ReservationShareService | Add @Mock in the 4 classes; the unit tests stub it`
- **Evidence (all from `ReplenishmentOrderMaintenanceServiceUnitTest` on `origin/develop`):** the default fixture is `buildStockunit(20L, 50L, amount, BigDecimal.ZERO)` with `requested 10`. That is reserved 0 against requested 10, which is exactly the under-reserved state this fix re-prices.

| Test (lines) | Setup | Test asserts | Proposed code gives |
|---|---|---|---|
| `cancelsOrderWhenShortageAtOrBelowThreshold` (`:625-628`) | reserved 0 | release `new BigDecimal("10").negate()` | held = 0, so release 0 (or no call) |
| SBDEV-3605 U-A1 (`:1151-1153`) | reserved 0 | redirect releases `-10` from `originalSu` | 0 |
| `updatesRequestedAmountWhenDiffers` (`:739-775`) | 50/0/10 | requested 60, delta 50 | cap 50, requested **50** (delta 50 only by coincidence) |
| default-upperbound test (`:1541-1543`) | 100/0/10 | delta **74** | delta **84** |
| redirect-then-cancel (`:731-736`) | entity 15/20, redirected req 5 | cancelled | own 20, held 5, cap 5, so **not cancelled** |

  - Three classes use `@InjectMocks` on ROMS, not "4": `ReplenishmentOrderMaintenanceServiceUnitTest:84`, `…ReassignTest:71`, `ReplenishmentFirstTouchInvariantUnitTest:96`. The last runs `STRICT_STUBS` with `verifyNoMoreInteractions(replenishorderRepository)` (`:213`). A real `ReservationShareService` over that mock adds a `sumRequestedAmountOfOtherOpenOrdersOnStockunit` interaction and fails it.
  - A bare `@Mock` returns `null` from `capacity`/`heldShare`, so `shortage.min(null)` NPEs on every recalc test. The existing catch then logs a WARN, so failures show up far from their cause.
  - `ReassignTest` builds moved stock as `new Stockunit()` with no reserved amount, so held = 0 there too. Its release-exactly-once pins (around `:306`) flip as well.
- **Why it matters:** the executor meets a wall of reds with no plan-sanctioned expected values. The easy way out is to edit each assertion until it goes green, which removes the review value of those pins. This is the "fix the tests to match" failure the floor exists to prevent.
- **Fix:** Add a §8.1 "Existing pins that change" table: test · line · old expected · new expected · why. Rows at minimum: `:625`, `:731-736`, `:771`, `:1151`, `:1541`, plus a `ReassignTest` sweep. Decide how the helper is present in unit tests. Recommended: a real `ReservationShareService` over the repository mocks, with the two sums stubbed `lenient()` to `ZERO` in a shared `@BeforeEach`. Name `FirstTouchInvariantUnitTest`'s `verifyNoMoreInteractions` as an intentional edit, or use `ignoreStubs`. Regrade the §5 step 2 claim to "SBDEV-3605 and ROMS suites change in the N rows listed".

---

### Medium

**M-1. "All computed under the source SU's row lock" is false on the move path.**
- **Plan text:** §3 `All are computed under the source SU's row lock` and `reassignOrCancelForMovedStockUnit reaches cancelOrder, so it is covered with no separate edit`.
- **Evidence:**
  - `UnitloadBusinessService.processTransfer` passes `for (Stockunit movedStockUnit : stockunitRepository.findByUnitloadId(unitload.getId()))`, a plain finder, into `syncForMovedStockUnit`, and from there into `reassignOrCancelForMovedStockUnit(movedStock, …)`.
  - `ROMS:220-249` locks only the *order* (`findByIdForUpdate(probeId)`), then calls `redirectSource(order, movedStock)` and `cancelOrder(order, movedStock, …)`.
  - `heldShare(order, movedStock)` would therefore read `movedStock.getReservedamount()` from an unlocked READ-mode entity.
  - Today the release amount comes from the *locked* order row. Fix C moves the source of truth to an unlocked read, so this is a small regression in concurrency safety.
- **Trap:** Adding `findByIdForUpdate(movedStock.getId())` there is a version-checked lock upgrade on a READ-managed row. That is the SBDEV-3244 mechanism.
- **Fix:** On the move path, compute `held` from the SU instance `changeReservedAmount` returns after its lock and refresh. Or accept the residual in a named §7 row. Either way, remove "covered with no separate edit" and add a ReassignTest pin for an under-reserved moved SU.

**M-2. Capacity is not bounded by `amount`. "Never throws" and "reservedamount never exceeds amount" are both false.**
- **Plan text:**
  - §2 `So reservedamount never exceeds amount; only requestedamount can`
  - §3 `desired ≤ capacity means res' ≤ amount, so changeReservedAmount never throws on this path`
- **Evidence:**
  - `StockunitBusinessService.changeReservedAmount` checks `if (stockUnit.getAmount().compareTo(newReservedAmount) < 0) throw CANNOT_RESERVE_MORE_THAN_AVAILABLE` on *every* delta, releases included.
  - `amount` can drop below `reserved` by paths that never call it. DEV today has 1 SU with `reservedamount > amount` (id 30022257: amount −1, reserved 0).
  - Worked case: amount 5, reserved 10, sole order requesting 10. ownShare 10, held 10, free 0, cap 10, so requested stays at **10 > amount 5**. The ticket's own defect ("requested above physical") survives.
  - Any partial shrink leaves `res' > amount`, which throws, which marks the shared `recalculateForItem` transaction rollback-only. That transaction includes `transferStock`'s, per the `ROMS:136-143` note.
- **Fix:** Define `capacity = min(held + free, amount)`. Use a signed release `min(0, desired − held)` that may take `res` below `amount`, or explicitly skip with a WARN. Add a unit test: amount 5, reserved 10, requested 10, which today leaves requested 10.

**M-3. §0 missed a same-class release site.**
- **Plan text:** §0 blind spot `a release amount derived indirectly, through a local variable … redirectSource's release was found by reading the file` and §9 `✓ §0: 11 rows, each fixed or excluded`.
- **Evidence:** `ReplenishorderService:280`, `changeReservedAmount(oldSource, requested.negate(), true, WmsConstants.CODE_REDIRECT_REPLENISHMENT_SOURCE, …)`. This is the admin redirect, releasing the local `requested`, which is exactly the stated blind spot. §0 row #7 cites only `:326`, the cancel.
- **Fix:** Add it as row #7b ("no, P-1"), fold it into P-1's blast radius, and restate the §0 method as "the full `changeReservedAmount(` inventory (27 call sites), each classified". Do not use the 3-line proximity grep.

**M-4. The query-count claim is false.**
- **Plan text:** §6 #3 `work per order grows by 2 indexed scalar queries`.
- **Evidence:** As written, `capacity` runs in `isSourceUsable` (`ROMS:432`) and again in `recalculateOrder` (`:312`), and `heldShare` runs in `updateRequestedAmount`. Each costs `ownShareOfReservation`'s 2 queries, so it is **6 per order** on the common path, and more after a redirect. JPQL sums on `replenishorder` also trigger Hibernate auto-flush of the dirty order row mid-method.
- **Fix:** Compute `ownShare` once after `ensureValidSource` returns and pass it down, or state the real count. Pin the count with a `times(1)` verify on the sum.

**M-5. IT-2's idempotency assertion is vacuous on current code and targets the wrong mutant.**
- **Plan text:** `a second recalc writes no stockrecord row (watermark by created)`.
- **Arithmetic:**
  - Current code on 18/18/26 with shortage ≥ 26: cap = 26, desired = 26 = requested, so both runs return early and write no stockrecord. The assertion passes today.
  - Proposed code, run 1: delta 0, and the `delta != 0` guard prevents the call. Run 2 returns early.
  - The only mutant that matters is dropping the `delta.signum() != 0` guard. That writes a zero-delta stockrecord on **run 1**: `recordChangeReservedAmount` fires unconditionally in `changeReservedAmount`. The shortage is also unstated; with shortage < 18 the expected value is not 18.
  - `created` watermarks are timing-fragile, and repo tests commit, so assert by id.
- **Fix:** Assert that run 1 writes 0 stockrecord rows for the SU (id watermark), and that it kills "drop the delta guard". Seed shortage ≥ 26.

**M-6. IT-3 can pass on current code, and its assertion names no column.**
- **Plan text:** `a same-row redirect keeps reserved ≤ amount and held == requested`.
- **Arithmetic:**
  - Sole holder, correctly reserved (20/9/9, free 11): current code reserves +9 and releases 9, ending at 9 == 9. **Green today.**
  - It fails on current code only when under-reserved, e.g. 20/1/9: current ends at res 1 vs requested 9; proposed captures held 1, reserves +9 and releases 1, ending at 9 == 9.
  - Reaching a same-row redirect also needs the SBDEV-2492 route: SU location ≠ `order.requestedlocationId`, still in a replenishable area, with free > 0. The plan names none of this.
  - "held" is not a column.
- **Fix:** Specify the fixture (20/1/9, location-mismatch route, replenishable area) and the assertion (`stockunit.reservedamount == replenishorder.requestedamount == 9`). State the mutant it kills: computing held after the target reserve gives 20 − 10 … i.e. the wrong release.

**M-7. The alternatives are thin, and existing prior art is not mentioned.**
- **Evidence:** There is no Options or Alternatives section. The only rationale is Fix A's "why a service / why not StockunitBusinessService". None of the following is weighed:
  - **Clamp-only:** Fix A alone plus `requested ≤ amount`.
  - **Existing reconciliation service:** `ReplenishmentReservationReconciliationService` (SBDEV-2610 C1, admin endpoint `/reconcile-stranded-reservations`) is the codebase's precedent for audited reservation repair. It is relevant to the D3 "recalc converges" argument, and to the 93 holderless-surplus SUs it deliberately leaves alone.
  - **Shared pure function with duplicated queries:** the option H-1 needs.
  - The plan also has no pre-mortem.
- **Fix:** Add a ≤10-line options table (clamp-only · helper service · static function · reconciliation job) with the rejection reason for each, and a 3-scenario pre-mortem. H-1, H-2 and M-2 are the obvious candidates.

**M-8. The TDD-gate ordering cannot compile.**
- **Plan text:** §5 step 1 `failing tests U-1 to U-8 … (§8)`, then step 2 `Extract ReservationShareService`.
- **Evidence:** U-4, U-8 and every ROMS test that mocks or constructs `ReservationShareService` reference a class that does not exist yet. That is a module-wide compile failure, not a right-reason red. The repo's own precedent (the `MultiUnitLoadOwnShareContractUnitTest` javadoc) says so: `those pins would be compile errors that break every other gate test in the module`.
- **Fix:** Gate with a reflection contract test for the new class and signatures. Behavioural U-1 to U-3 and U-5 to U-7 can be written against the *existing* ROMS surface, with the numbers asserted through `changeReservedAmount` / `getRequestedamount`, so they genuinely red today.

---

### Low

- **L-1.** U-7 has no numbers. Give it the U-6 shape (current SU reserved 3, requested 9, expect `-3`).
- **L-2.** U-2 does not state the shortage. It must be ≥ 26, or the current-code result is not "stays 26".
- **L-3.** Fix C does not say whether held = 0 skips the call. `cancelOrder`'s `releaseAmount > 0` guard is pinned by `:1344-1358`, "does not call changeReservedAmount when requestedAmount is zero". Keep the guard on `held`.
- **L-4.** The INFO log condition `desiredAmount < currentRequested because capacity bound it` is ambiguous: shortage shrinkage also lowers desired. Log when `capacity < shortage && desired < requested`.
- **L-5.** "4 classes" should be 3 (see H-2).
- **L-6.** §7's "only on PROCESSABLE (not started) orders" is correct for recalc. It does not apply to the move path, which also reaches Fix C for PROCESSABLE orders.

### What's Missing
- A test for `res > amount` (M-2).
- An under-reserved moved-SU pin on the move path (M-1).
- An explicit list of existing tests whose expectations flip (H-2).
- A statement that the `with_picks` population is 0 on DEV (I measured it), so the picks term, like the others term, is covered only by unit tests.
- Clarity that "would_shrink → 0" after deploy is not guaranteed in one cron: a cancel-threshold hit cancels rather than shrinks, which is fine but should be said.

### Verified correct
- The live-case numbers and all appendix counts (I re-ran them).
- Both indexes exist on DEV.
- `NEW_CRON_JOB_ACTIVATED=true` on DEV, so the manual "wait one cron" step works.
- The formulas for U-1 (old gives 26 / new gives 18, delta +17 in both), U-3 (the old early return skips +4), U-4, U-5 and U-6 fail on current code for the stated reason.
- "A plain revert is safe" holds: when held == requested, the old formula equals the new one.
- No DI cycle: `MobileReplenishService` → ROMS already exists, and the new service depends only on repositories.

### Verdict Justification
The review escalated to ADVERSARIAL mode after H-1 and H-2, which form a systemic pattern of "tests unchanged" claims unverified against the test tree.

The realist check keeps H-1 and H-2 at High. They are certain, and they strike at the TDD floor: the pins that protect SBDEV-3605 and SBDEV-3244 would be rewritten under pressure, with no plan-sanctioned expected values.

I held M-2 at Medium. It is mitigated by only 1 SU on DEV having reserved > amount, and that SU has amount ≤ 0, which `isSourceUsable` rejects. It is not downgraded further because the failure mode is a rollback-only shared transaction.

M-1 is Medium: 0 shared SUs on DEV, and the move path is operator-paced.

To reach APPROVE:
- resolve H-1 and H-2, with the options and a changed-pins table;
- fix M-2 with the amount cap;
- respecify IT-2 and IT-3;
- add M-3 to §0;
- correct the lock and query-count claims.

### Open Questions (unscored)
- Does `StockunitService.adjustReservedAmount` (the P-2 precondition) also run inside `recalculateForItem`'s caller transactions? If so, IT-1's sequence can run in one transaction.
- Same-row redirect sizing: `newRequested = min(req, candidate.available)` ignores the order's own held on that row. The recalc in the same transaction re-grows it, but a comment should say so.

**Ralplan summary**
- **Principle/Option consistency: Fail.** "Tests unchanged" contradicts the delegate design and U-8.
- **Alternatives depth: Fail.** No options table; the reconciliation-service precedent is unmentioned.
- **Risk/Verification rigor: Fail.** IT-2 is vacuous, IT-3 is underspecified, the tests do not compile at the gate, and the "never throws" and lock claims are false.
- **Deliberate additions:** no pre-mortem.

Files: the plan snapshot at `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3618-evidence/plan-r1-snapshot.md`. All code was read at `origin/develop` `652f37f7` in `/Users/np1076/dev/spk/owl/v2/wms2-api`.