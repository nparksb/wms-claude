## Summary

The core arithmetic is right. Booking against `held = min(max(req,0), ownShare)` and bounding by `capacity = held + free` stops the over-grant on the recalc path. Fix B's post-condition `held' == requested'` holds whenever the SBDEV-3605 holder invariant holds (`res ≥ others + picks`). But four of the plan's claims are false or unproven against `origin/develop` @ `652f37f7`:

1. **Not every path is locked.** The SU is not row-locked on the move path (`reassignOrCancelForMovedStockUnit`).
2. **Redirect to the same row still churns and shrinks.** A same-row redirect nets correctly but shrinks the order to free-only stock.
3. **The SBDEV-3605 tests cannot stay unchanged.** Mockito constructor injection passes `null` for the new parameter.
4. **The §0 enumeration misses a release-of-requested site** (`ReplenishorderService:280`).

Verdict: **SOUND-WITH-CHANGES**.

## Analysis

### Q1. Is the SU row locked (first touch) on every path where held or capacity is computed?

**Recalc path: yes, locked.**
- `ensureValidSource` loads the source under lock as its first touch: `stockunitRepository.findByIdForUpdate(order.getStockunitId())` (ROMS:407-408). `isSourceUsable` (Fix A capacity) reads that instance.
- Cancel at `shortage.compareTo(cancelThreshold) <= 0` (ROMS:307-308) and at `desiredAmount <= 0` (ROMS:313-314) receive the same `source`. That is either the first-touch locked instance or the post-redirect instance.
- The post-redirect instance is `stockunitRepository.findById(order.getStockunitId())` (ROMS:418). It hits the persistence context and returns the instance F4 locked with `stockunitRepository.findByIdForUpdate(candidate.stockUnitId)` (ROMS:531). `changeReservedAmount` then refreshes it (`entityManager.refresh(stockUnit)`, SBS:513), so its `reservedamount` is current.
- `cancelOrder(order, source, …)` after a failed redirect (ROMS:420) uses the first-touch locked `source`.

**Move path (`reassignOrCancelForMovedStockUnit`): not locked. This is finding H-1.**
- The caller loads the SU with a plain finder: `for (Stockunit movedStockUnit : stockunitRepository.findByUnitloadId(unitload.getId()))` (UnitloadBusinessService:535). It passes it through `syncForMovedStockUnit(movedStockUnit, …)` (:538) into `reassignOrCancelForMovedStockUnit(stockUnit, destinationLocation)` (SourceSync:78).
- ROMS locks only the order: `replenishorderRepository.findByIdForUpdate(probeId)` (ROMS:237). It then calls `redirectSource(order, movedStock)` or `cancelOrder(order, movedStock, …)` (ROMS:247-248).
- So Fix C's `heldShare(order, movedStock)` reads `reservedamount` from an unlocked entity, while the two sums in `ownShareOfReservation` are fresh JPQL. The plan's premise is false on this path: "All are computed under the source SU's row lock… `reassignOrCancelForMovedStockUnit` reaches `cancelOrder`, so it is covered with no separate edit."
- Most staleness still fails closed. The release's `findByIdForUpdate` (SBS:509) upgrades a READ-mode entity and is version-checked (the SBDEV-3244 mechanism). But `others` can change with no SU write: Fix B's own `delta == 0` branch sets `requestedamount` without calling `changeReservedAmount`, and so does an order growing into holder-less surplus. That change bumps no SU version, so the upgrade cannot detect it. Held can then come out too high and over-release, stripping another holder. That is the SBDEV-3605 defect class, which Fix C exists to close.
- **Same-row redirect on this path:** if held is computed before `findByIdForUpdate(candidate.stockUnitId)` (ROMS:531), it is computed before any SU lock at all.

### Q2. Is the Fix B post-condition proof correct?

Write `O = others + picks` (always ≥ 0). Then `ownShare = max(0, min(res, res − O)) = max(0, res − O)`, which matches MRS:1432: `reserved.subtract(others).subtract(picks).min(reserved).max(BigDecimal.ZERO)`.

**Invariant holds (`res ≥ O`):**
- `ownShare = res − O ≥ held`, and `res' = res + desired − held`.
- So `ownShare' = ownShare + desired − held ≥ desired`, which gives `held' = min(desired, ownShare') = desired`. ✓
- No throw:
  - If `delta > 0`: `res' ≤ res + free ≤ amount`.
  - If `delta < 0`: `res' ≥ res − ownShare ≥ 0`, so the `zeroIfNegative` clamp never fires. ✓

**Holder-less surplus (`ownShare > req`):**
- `held = req` and `capacity = req + free`. That is exactly the old `amount − res + req` whenever `res ≤ amount`, so behaviour is unchanged and the surplus is untouched. ✓

**`requested` null or negative:**
- `held = 0` and `delta = desired`. Post-condition: `held' = min(desired, ownShare + desired) = desired`. ✓
- `cancelOrder` releases 0. The old code released only when `> 0` (ROMS:635), so this is identical. ✓

**`others > 0` with the invariant broken (`res < O`): the post-condition fails. This is finding M-2.**
- `ownShare = 0`, so `held = 0` and `delta = desired`. But `ownShare' = max(0, res + desired − O) < desired`, so `held' < desired = requested'`.
- The next recalc books again. Worked example: amount 20, res 2, O 5, shortage 3.
  - Cycle 1: +3, res 5.
  - Cycle 2: `held` is still 0, +3 again, res 8.
  - Cycle 3: `delta` is 0.
- This converges, and the end state (res = O + req) is actually correct. But the claims in §3 ("Post-condition: `held' == requested'`"), §6 #6 ("a re-run gives `delta 0`") and IT-2 ("a second recalc writes no stockrecord row") are unconditional, and they are false in this case. Also, the backfill for the other holder's deficit is written to stockrecord under **this** order's number.
- Measured on DEV today: `invariant_broken_res_lt_O = 0`, `has_open_picks = 0` (565 open orders). So the exposure is zero now, but the claim is still wrong.
- **Fix-A side effect:** with `res < O` and `free = 0`, capacity is 0, so `isSourceUsable` returns false and the order is redirected or cancelled because of *another* order's deficit. U-5 covers it; §3's list of behaviour changes should name it.

**Unreachable branch:** `res > amount` would make even a release throw (`if (stockUnit.getAmount().compareTo(newReservedAmount) < 0) throw … CANNOT_RESERVE_MORE_THAN_AVAILABLE`, SBS:519-520). On DEV one SU has res > amount (`30022257`, amount −1, res 0). It has no open replenishment, and `isSourceUsable` rejects `amount <= 0` (ROMS:428), so the branch is unreachable today.

### Q3. Same-row redirect (current == target)

- The candidate comes from a native query that has no `su.id <> current` filter (ROMS:510-514 says so). On the recalc path, current is already locked, so `candidate.getAvailable()` equals current's `amount − res = free`.
- `newRequested = safe(order.getRequestedamount()).min(candidate.getAvailable())` (ROMS:491) gives `min(req, free)`. The order's own held share is **not** credited.
- Arithmetic with held captured first:
  - Reserve: `res + newReq`, which is ≤ amount.
  - Release: `res + newReq − held`.
  - `ownShare' = ownShare + newReq − held ≥ newReq`, so `held' = newReq`. The invariant holds, so the plan's IT-3 assertion passes.
- **Sizing is wrong, though (finding M-1).** Take held 9, req 9, free 2. The order drops to 2 on the same row: +2 SWITCHED, then −9 CANCELLED. MobileReplenishService already solved this exact problem with a self-credit: `if (oldSu != null && oldSu.getId().equals(matching.getId())) { effectiveAvailable = effectiveAvailable.add(ownShare); }` (MRS:1461-1463).
- On the recalc path, Fix B then regrows the order in the same transaction: capacity = `newReq + free'`. The net outcome is right, but it writes three stockrecord rows for a no-op.
- On the move path there is no follow-on recalc, so the order stays shrunk until the next cron.
- This pre-dates the ticket; the old code shrank the same way. The plan should not claim IT-3 "covers" same-row redirect, because IT-3 checks the invariant, not the size.

### Q4. Is extracting ReservationShareService the right boundary?

**No bean-cycle risk.** The new service depends only on `ReplenishorderRepository` and `PickingorderPositionRepository`. ROMS already reaches MobileReplenishService's graph only through `@Lazy` points (MRS:96-97; SourceSync:52). A leaf service with repository dependencies adds no cycle.

**"The SBDEV-3605 unit tests stay unchanged" is false. This is finding H-2.**
- `MobileReplenishServiceUnitTest` uses constructor `@InjectMocks` (`@InjectMocks private MobileReplenishService mobileReplenishService;`, test:130). Its own comments record the trap: "SBDEV-3091: was absent, so @InjectMocks passed null for this constructor parameter."
- With a new `ReservationShareService` constructor parameter:
  - **No `@Mock` declared:** it is null, so the delegate throws an NPE.
  - **`@Mock` declared:** the default answer returns `null` for `BigDecimal`, so the reflective U-2 (`helper.invoke(mobileReplenishService, su, 512L)` asserting 0) fails. Its repository stubs are also never consulted.
- Every multi-UL test that reaches MRS:1281 is affected the same way. Either the test wires in a real `ReservationShareService` built over the repository mocks in `@BeforeEach`, or the tests change.
- **The contract test pins a dependency that becomes dead.** `MultiUnitLoadOwnShareContractUnitTest:175-190` asserts `MobileReplenishService` takes a `PickingorderPositionRepository` constructor parameter ("the open-pick sum needs PickingorderPositionRepository injected"). After the extraction, MRS no longer uses it (MRS:1430 is its only use). Keeping the test "unchanged" means keeping a dead injected dependency; changing it contradicts the plan.
- **ROMS tests:** `ReplenishmentFirstTouchInvariantUnitTest:213-214` has `verifyNoMoreInteractions(replenishorderRepository)`. A real `ReservationShareService` over the shared repository mock would trip it on any path that computes held. The path in that test uses `source == null`, so it is safe today.
  - With a mocked service (the plan's choice), every existing ROMS test that reaches `isSourceUsable`, `updateRequestedAmount` or `cancelOrder` with a source needs `held`/`capacity` stubs. Otherwise it NPEs on a null `BigDecimal`.
  - The mocked service also means ROMS unit tests no longer exercise the real rule. The plan's "Add `@Mock` in the 4 classes" understates this churn. The grep found 3 ROMS classes with `@InjectMocks`: FirstTouchInvariant, Reassign, UnitTest.

### Q5. Does anything depend on the old (inflated) requested value?

No.
- `shortage` = `upperBound − (destAvailable + destReserved + inbound)` (ROMS:304) does not include this order's own requested.
- `getInboundReplenish` sums *other* orders: `ro.id <> :excludedId` (Repo:56). For a non-null destination that sum is structurally 0, because `CREATE UNIQUE INDEX idx_replenishorder_active_item_dest ON public.replenishorder USING btree (itemdata_id, destination_id) WHERE (state < 700)` (V2.2.00:3876) allows one active order per item and destination.
- The null-destination branch (`:destinationId IS NULL OR …`) sums every other order of the item. That is pre-existing, and `alignDestination` normally fills the destination in.
- `redirectSource` uses the old requested only as an upper bound: `min(req, candidate.available)`. An inflated 26 is harmless there.
- **Multi-UL interplay:** SBDEV-3605 already expects maintenance to "top up, cancel or re-source this template" before its SU locks (MRS:1238-1240), and it re-guards the state (MRS:1243). With Fix B, maintenance can now also *shrink* a PROCESSABLE template in-flow. `ownShare` is computed after that (MRS:1279-1281), so the two stay consistent. There is no defect here, but the behaviour change should be named.

### Q6. Is §0 mis-scoped?

- **Missing site:** `ReplenishorderService:280`, the admin redirect-source path: `stockunitBusinessService.changeReservedAmount(oldSource, requested.negate(), true, WmsConstants.CODE_REDIRECT_REPLENISHMENT_SOURCE, …)`. This is the plan's own stated blind spot (a local variable), and §0 lists only :326 from that file. It belongs under P-1 alongside #7-#9.
- **Keeping #7-#9 out is defensible.** Their residual exists only between drift and the next recalc, and DEV has `shared_su = 0`. Two caveats:
  - #9, the single-UL finish (MRS:581), releases `requested` on a STARTED order, and recalc never repairs a STARTED order (`!Objects.equals(order.getState(), PROCESSABLE)`, ROMS:280). If an admin cut the reservation after the order started, "once Fix B holds…" does not apply.
  - Once `ReservationShareService` exists, the cost is small (about ½ day, per the plan).
- **I would keep them as P-1, not bring them in**, so the T3 surface stays on the maintenance path. But P-1 should list #9's STARTED-state exposure explicitly.

## Root Cause

This confirms the plan's diagnosis. `getAvailableIncludingReservation` (ROMS:607-612) assumes `requested ⊆ reserved`, and `updateRequestedAmount` (ROMS:615-619) books the delta against requested. Both break once an admin absolute set (`StockunitService:1001`, `CODE_MANUAL_ADJUSTMENT`) cuts the reservation below requested.

The design's residual defects come from one gap: Fix C's premise assumes a lock that the move path does not take.

## Findings

**H-1: Fix C computes held on an unlocked SU on the move path.**
- Evidence: UnitloadBusinessService:535 `stockunitRepository.findByUnitloadId(unitload.getId())`, then ROMS:247-248 `if (!redirectSource(order, movedStock)) { cancelOrder(order, movedStock, …) }`. The only lock taken is the order's (ROMS:237).
- Fix: in `reassignOrCancelForMovedStockUnit`, after the state guard (ROMS:239-243), take `Stockunit lockedSource = stockunitRepository.findByIdForUpdate(movedStock.getId()).orElse(null)` and pass it to `redirectSource` and `cancelOrder`.
- This is a lock *upgrade* of a READ-mode entity, so it is version-checked. That is no worse than today, because the release at SBS:509 performs the same upgrade later.
- Side effect: the move path's order becomes order → current → target, matching recalc. That removes the half of the ABBA that ROMS:501-504 names ("reassignOrCancelForMovedStockUnit's redirect/release path is still target->current"). Update that comment. The cross-order residual stays.
- Add a unit pin: an `InOrder` asserting `findByIdForUpdate(movedId)` runs before `findByIdForUpdate(candidateId)`.

**H-2: The "SBDEV-3605 suites unchanged" claim is false, and the DI wiring of tests is unspecified.**
- Evidence: MobileReplenishServiceUnitTest:130 `@InjectMocks`; test:4411-4424 reflective U-2 with repository stubs; ContractUnitTest:175-190 pins the `PickingorderPositionRepository` constructor parameter.
- Fix: say in §5 step 2 that MobileReplenishServiceUnitTest constructs a real `new ReservationShareService(replenishorderRepository, pickingorderPositionRepository)` and injects it with `ReflectionTestUtils` or an explicit constructor. Decide explicitly whether the contract test's constructor pin is retargeted to `ReservationShareService` or whether the dead parameter stays. Retargeting is recommended; a dead injected dependency pinned by a test is rot.

**M-1: The same-row redirect sizes the new request without the order's own share.**
- Evidence: ROMS:491 `safe(order.getRequestedamount()).min(candidate.getAvailable())`, against the self-credit precedent at MRS:1461-1463.
- Fix: `available = candidate.getAvailable() + (current != null && current.getId().equals(candidate.stockUnitId) ? held : 0)`. Better still, short-circuit a same-row candidate to a location re-point with no reservation writes, as SourceSync:121-125 does.
- Also compute held *after* the target `findByIdForUpdate` whenever current == target.
- Extend IT-3 to assert the requested amount is preserved and the stockrecord row count, not just the invariant.

**M-2: The Fix B post-condition and idempotency hold only when `res ≥ others + picks`.**
- Evidence: MRS:1432 floors at 0. With `res < O`, `held' = max(0, res + desired − O) < desired`.
- Fix: state that precondition in §3, §6 #6 and §9 #6. Add a unit test (U-4b) for multi-cycle convergence to `res = O + req` with a strictly shrinking `delta`. Name the attribution caveat: another order's deficit is backfilled under this order's number.
- DEV today: 0 rows with `res < O`, 0 with open picks.

**L-1: §0 misses a release-of-requested site.**
- Evidence: ReplenishorderService:280 `changeReservedAmount(oldSource, requested.negate(), true, CODE_REDIRECT_REPLENISHMENT_SOURCE, …)`.
- Fix: add it as row #7b under P-1.

**L-2: The share is recomputed three to four times per order.**
- `isSourceUsable` computes capacity, `recalculateOrder` computes capacity again (ROMS:312), `updateRequestedAmount` computes held, and a redirect computes held on current. That is up to 8 scalar queries per order, not the "2" in §6 #3.
- Fix: compute a small `Share(held, free)` value once, for the final source, and pass it to `desired` and `updateRequestedAmount`. Recompute only when the source changes. It is also easier to mutation-test.

**L-3: Comment drift.** The comment at ROMS:431, `// Treat the source as usable if it still has availability for this order (amount - reserved + current request)`, becomes false once the helper is deleted. Update it with Fix A.

**L-4: #9 has a STARTED-state exposure recalc never repairs.** The P-1 rationale ("Once Fix B holds, a PROCESSABLE order leaves every recalc with `held == requested`") does not cover the single-UL finish at MRS:581, which runs on STARTED orders. Note it in P-1.

## Consensus Addendum

**Antithesis (steelman).** Don't touch booking semantics at all. Fix only the capacity helper (Fix A) plus a hard clamp `requested ≤ reserved share + free` in `updateRequestedAmount`, and handle under-reservation with a separate, audited reconciliation job, like the SBDEV-2610 precedent (`ReplenishmentReservationReconciliationService`).
- Recalc runs on every cron tick, for 565 orders on DEV, and inside other writers' transactions. `recalculateForItem` runs inside the `transferStock` and multi-UL transactions (ROMS:136-143; OSIV map §8.5).
- Teaching it to re-reserve (the top-up) and to use a holder-attribution heuristic (`ownShare` subtracts others' *requested*, not their held) spreads a heuristic across every order on every tick. M-2 shows the heuristic misattributes exactly when data is already broken.
- A one-shot reconciler with its own audit trail, run on a quiet tenant, fixes the 53 orders once. A plain clamp then keeps new ones from appearing, with a much smaller always-on blast radius.

**Tradeoff tension.**
- *Self-healing vs. how far the heuristic reaches.* D3 (no data script, recalc converges) needs the holder heuristic on the hot path. The reconciler keeps the heuristic out of the hot path but leaves a window between drift and the next manual run, and it adds an operator step Nam has declined.
- *Single source vs. test isolation (H-2).* One bean holding the invariant is the right way to stop drift, but it makes every consumer's unit tests either use a real instance, which trips `verifyNoMoreInteractions` pins, or a mock, which hollows out the tests of the rule.

**Synthesis.**
1. Keep Fixes A, B and C and D3. Make the helper a pure function of `(res, others, picks, req, amount)`, placed in `ReservationShareService` next to a thin bean method that runs the two queries.
2. Unit-test the pure function directly. Consumers' unit tests stub the bean with values computed by the pure function, which removes the `BigDecimal`-null and repository-interaction problems.
3. Take the SU lock on the move path (H-1).
4. Make the Fix B top-up conditional on `res ≥ O`. When the invariant is broken, only shrink, never top up, and log it at WARN. That keeps recalc from ratcheting a broken shared SU and still converges every over-grant.
5. Trade-off of step 4: the 2 `topup_only` DEV orders are still re-reserved (their invariant holds), but a broken shared SU waits for a human.

**Principle violations (deliberate mode).**
- **Stated lock precondition not met (High).** "All are computed under the source SU's row lock" is false on the move path (H-1).
- **Unconditional completeness claim (Medium).** "SBDEV-3605 suites… pass unchanged" is not achievable as written (H-2).
- **Proof overstated (Medium).** The idempotency claim ignores its own precondition (M-2).

## Recommendations (prioritized)

1. **H-1:** lock `movedStock` in `reassignOrCancelForMovedStockUnit` before `redirectSource`/`cancelOrder`. Effort: small. Impact: closes the only unlocked held read and harmonizes lock order.
2. **H-2:** specify the test wiring (a real service instance in the MRS tests; a decision on the contract test's constructor pin) and drop the "unchanged" claim. Effort: small. Impact: stops a false-green or false-red gate.
3. **M-1:** self-credit held on a same-row redirect, or short-circuit it to a re-point; compute held after the target lock. Effort: small. Impact: removes the shrink/regrow churn and the move-path under-sizing.
4. **M-2:** state the `res ≥ O` precondition, add U-4b, and optionally gate the top-up on the invariant. Effort: small. Impact: makes the proof and IT-2 honest.
5. **L-1 to L-4:** add the missing §0 row, compute the share once per order, fix the comment at ROMS:431, and note #9's STARTED exposure in P-1. Effort: trivial.

## Trade-offs

| Option | Pros | Cons |
|---|---|---|
| Plan as written (bean, mocked in consumer tests) | One home for the invariant; small diff | H-1 hole; consumer unit tests stop exercising the rule; "unchanged" claim false |
| Bean plus pure static core (synthesis) | Invariant tested once, directly; consumer stubs are trivial; no repository-interaction collisions | Two layers (pure function and bean) to keep aligned |
| Clamp only, plus a reconciler job (antithesis) | Smallest always-on change; audited one-shot repair | Operator step (against D3); drift reappears between runs; no top-up |
| Keep a second copy of the invariant in ROMS | Zero DI or test churn | The duplication this ticket warns against |

## References

**Code** (`/Users/np1076/dev/spk/owl/v2/wms2-api`, `origin/develop` @ `652f37f7`):
- `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java`
  - :237 locks only the order on the move path; :247-248 redirect or cancel with `movedStock`
  - :304-316 shortage and cancel logic; :407-408 first-touch SU lock on recalc; :418 post-redirect locked instance; :431 stale comment
  - :491 `newRequested` has no self-credit; :501-530 ABBA comment; :531 target lock; :558 releases requested
  - :607-612 the add-back helper; :615-619 delta booked against requested; :634 cancel releases requested
- `src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java` — :535 `findByUnitloadId` (unlocked); :538 sync call
- `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderSourceSyncService.java` — :52 `@Lazy` ROMS parameter; :78 delegation
- `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java` — :509-520 lock, refresh and the over-amount throw (which also fires on a release while res > amount)
- `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java` — :1238-1243 maintenance-before-lock plus re-guard; :1281 `ownShare`; :1426-1433 the invariant; :1461-1463 same-SU self-credit precedent; :581 single-UL finish release
- `src/main/java/net/aim_ai/wms/service/ReplenishorderService.java` — :280 missing §0 site; :326 cancel
- `src/main/java/net/aim_ai/wms/repo/jpa/ReplenishorderRepository.java` — :51-62 inbound sum; :201-206 others-sum
- `src/main/resources/db/migration/V2.2.00__base_v2_schema.sql` — :3876 unique active item and destination index
- `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileReplenishServiceUnitTest.java` — :130 `@InjectMocks`; :4411-4424 reflective U-2
- `src/test/java/net/aim_ai/wms/unit/repo/MultiUnitLoadOwnShareContractUnitTest.java` — :175-190 constructor-parameter pin
- `src/test/java/net/aim_ai/wms/unit/service/ReplenishmentFirstTouchInvariantUnitTest.java` — :213-214 `verifyNoMoreInteractions`

**Plan:** `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3618-recalc-over-grants-requested-above-stock.md`

**DB:** DEV wineco (`dev_wh01_om1`), queried 2026-10-01: 565 open orders; 0 with `res < others + picks`; 0 with open picks; 0 with null or non-positive requested; 1 SU with res > amount (`30022257`, amount −1, no open replenishment).

**Verdict: SOUND-WITH-CHANGES.** Resolve H-1 and H-2 before the TDD gate. M-1 and M-2 should land in the same pass.