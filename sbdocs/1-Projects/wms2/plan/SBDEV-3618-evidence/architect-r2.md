## Summary

Both r1 Highs are fixed. Fix D locks the moved stock unit on the move path. The static `ReservationShare` really does leave the MRS suites needing zero edits, and I checked every MRS pin. The Fix B/C/D/E designs hold up.

The r2 problems are mostly in test bookkeeping:
- §8.1 calls itself the complete list of expected test flips, but it misses two existing ROMS unit tests that will go red.
- It never mentions the new `@Mock PickingorderPositionRepository` wiring that two existing test classes need.
- One §8.1 rewrite (redirect-then-cancel) cannot keep the evidence it says it keeps.

On the design side there are two edge cases, both with 0 DEV exposure: Fix E should not re-point on the move path, and Fix C's release is not protected by Fix B step 4's `res > amount` guard.

**Verdict: SOUND-WITH-CHANGES** (no High; 3 Medium, 5 Low).

## Analysis

### 1. r1 findings

| r1 | Status | Evidence |
|---|---|---|
| **H-1** Fix C read held on an unlocked SU on the move path | **RESOLVED** | Fix D takes `findByIdForUpdate(movedStock.getId())` after the state guard. The only caller chain is `UnitloadBusinessService:535` `for (Stockunit movedStockUnit : stockunitRepository.findByUnitloadId(...))` → `SourceSync:78` → ROMS:220. That is the only place that needs the lock. |
| **H-2** "SBDEV-3605 suites unchanged" was false | **RESOLVED** | See §2a: MRS keeps its signature, its queries and its constructor parameter, so every MRS pin still holds. |
| **M-1** same-row redirect shrinks the order | **RESOLVED** on the recalc path (Fix E). See M-B for a move-path caveat. | |
| **M-2** Fix B post-condition assumes `res ≥ O` | **RESOLVED** | Fix B step 3 plus U-9. §3 now states the post-condition only "when invariantHolds". |
| **L-1** missing §0 site | **RESOLVED** | §0 row #9 is `ReplenishorderService` `changeReservedAmount(oldSource, requested.negate(), … CODE_REDIRECT_REPLENISHMENT_SOURCE`. |
| **L-2** share recomputed per call | **RESOLVED**, with a gap | The `Share` record is computed once and pinned by U-8 `times(1)`. The gap is L-A below. |
| **L-3** stale comment at ROMS:431 | **RESOLVED** | Fix A names it. |
| **L-4** #12 STARTED exposure | **RESOLVED** | §0 row #12 and P-1 state it. |

### 2a. Pure static `ReservationShare`, with MRS keeping its queries: are zero MRS test edits real?

**Yes.**
- `MobileReplenishService.java:1426-1433` keeps the signature `ownShareOfReservation(Stockunit lockedOldSu, Long templateId)` and both repository calls. Only the return line (`reserved.subtract(others).subtract(picks).min(reserved).max(BigDecimal.ZERO)`) moves.
- The reflective U-2 in `MobileReplenishServiceUnitTest:4411-4420` (`getDeclaredMethod("ownShareOfReservation", Stockunit.class, Long.class)`) keeps working, and its repository stubs are still consulted.
- `MultiUnitLoadOwnShareContractUnitTest` keeps passing:
  - `ownShareOfReservation/2` is still package-private and still returns `BigDecimal` (:159-171).
  - `PickingorderPositionRepository` is still a constructor parameter of MRS (:186-188).
- One trap in the same contract test is not named by the plan (see L-D). Its ROMS test pins `cancelOrder/3` as a positive control and `releaseReservation/4` by exact parameter types (:196-210). If the executor threads `Share` through those signatures, as in "`cancelOrder` releases `share.held`", the contract test goes red.

**Null safety is required, not optional.**
- The three ROMS `@InjectMocks` classes get `null` from Mockito's default answer for an unstubbed `BigDecimal` sum.
- `ReservationShare` must therefore treat null inputs as 0. The planned `ReservationShareUnitTest` null cases should be an explicit requirement for this reason.

### 2b. Fix B steps 3-4: does any state stay unrecoverable, and is the capacity cap right?

**The capacity cap is correct.**
- When `res ≤ amount`: `held ≤ ownShare ≤ res`, so `held + free = held + amount − res ≤ amount`. The cap is a no-op, and the r1 proof stands.
- When `res > amount`: `free = 0` and `capacity = min(held, amount)`. So `desired ≤ held`, `delta ≤ 0`, and step 4 is only reachable with `delta < 0`, as the plan says.

**Step 3 (invariant broken):**
- `ownShare = 0`, so `held = 0`, so `delta = desired > 0` whenever the order survives. Step 3 therefore always fires when the invariant is broken.
- The end state is `requested = min(desired, req) ≤ capacity ≤ amount`. So `requested > amount` cannot remain.
- `reserved ≠ requested` does remain, deliberately.
- It is not strictly permanent. For one order A, "broken" means `res < b + picks`, while another holder B may still satisfy `res ≥ a + picks`. B then tops up, which raises `res` and can repair A's invariant.
- It is stuck only when every holder is broken at once. That waits for a human (P-2 or the reconciler), and the plan accepts that.
- DEV today: `broken = 0`.

**Step 4 (`res + delta > amount`):**
- The end state is `requested = desired ≤ min(held, amount)`, with `res > amount` unchanged.
- The next recalc gets `held = min(req, ownShare) = req`, so `delta = 0` and `desired == requested`, and it returns. This is stable and not ratcheting.
- The leftover `res > amount` is pre-existing corrupt data.
- DEV today: `res_gt_amount` among open orders = 0.

**Gap: the step-4 guard does not reach the release sites (M-C).** See the finding below.

### 2c. Fix D: is it really "the same upgrade the release already does"? Is `movedStock` possibly dirty?

**The claim is true, with one qualification.**
- Today, on this path, `releaseReservation(currentSource, …)` (ROMS:557-559) or `cancelOrder` → `releaseReservation` (ROMS:634-636) calls `changeReservedAmount`. That runs `stockunitRepository.findByIdForUpdate(staleStockUnit.getId())` (SBS:509) on the READ-managed `movedStock`: the same version-checked upgrade.
- The qualification: today that upgrade only happens when the release amount is `> 0` (ROMS:635). Under Fix C, a `held == 0` cancel releases nothing. So Fix D adds the lock in the zero-release cases.
- The wording should say "whenever a release occurs" rather than implying the upgrade is always there. This is harmless.

**`movedStock` is not dirty.**
- In `processTransfer`, the loop body calls `assertNoActivePickFor(id)`. Then `realignForMovedStockUnit`, which writes only `PickingorderPosition` (PLRS:127-138: `pp.setPickfromunitloadlabel` / `pp.setPickfromlocationname` / `pickingorderPositionRepository.save(pp)`). Then `syncForMovedStockUnit`.
- Nothing writes the stock unit before Fix D's lock.
- `findByIdForUpdate` is JPQL (`@Lock(PESSIMISTIC_WRITE) @Query("SELECT s FROM Stockunit s WHERE s.id = :id")`, StockunitRepository:33-47). Even if the stock unit were dirty, the query space overlaps it, so Hibernate would auto-flush first and resync the version. Only a concurrent committed writer can make it throw, which matches pre-mortem 2.
- No stock-unit lock precedes the order lock on the move path. The only earlier lock is the destination `locationRepository.findByIdForUpdate` (UBS:245). So "order → current → target" is accurate.

**Test impact is under-specified (M-A).**
- `ReplenishmentOrderMaintenanceServiceReassignTest` builds `movedStock = new Stockunit(); movedStock.setId(MOVED_STOCK_ID)` (:83-84), with amount and reserved both null.
- Unstubbed, `findByIdForUpdate(MOVED_STOCK_ID)` returns `Optional.empty()`, so `locked = null` and no release happens.
- AC3 (:204-206 `verify(...).changeReservedAmount(eq(movedStock), …)`) and M4 (:307-309 `times(1)` … `eq(movedStock)`) then go red.
- The stub must return **the same `movedStock` instance**, because `eq()` on an entity compares identity. The fixture also needs reserved 10, and the class needs `@Mock PickingorderPositionRepository`.

### 2d. Fix E: is the same-row re-point reachable, and does anything rely on redirect resizing?

**Recalc path: reachable.**
- The ROMS:510-514 comment says so, and the `isSourceUsable` location-mismatch route (ROMS:449) is the trigger.
- `processTransfer` only calls `syncForMovedStockUnit` for `BLOCK_REALIGN` activity codes (UBS:534). So PASS_THROUGH moves leave `requestedlocationId` stale.
- DEV today: 0 PROCESSABLE orders with a location mismatch, so exposure is 0 now.

**Move path: designed-unreachable (M-B).**
- The destination is non-replenishable by precondition (ROMS:224, SourceSync:77). The candidate query requires `area.useforreplenish = true` and applies the same lane predicate (StockunitRepository:326-328).
- The moved UL's new `storagelocation_id` is dirty in the persistence context (UBS:521-522 `unitload.setStoragelocationId(...); save`). A native query through the JPA `EntityManager` triggers a full auto-flush, so the moved stock unit drops out of the candidate set.
- The existing tests say this is intended:
  - `// the moved SU sits on a useforreplenish=false area and self-excludes` (ReassignTest:275-276)
  - `AC5-guard: … does not re-point the order onto the moved (non-replenishable) source` (:313)
- If a same-row candidate ever did appear here, it would mean the query read a stale location. Re-pointing the order to that stale location is exactly what AC5-guard forbids.
- So the plan's "On the move path, sizing waits for the next cron" describes an unreachable case, and it would do the wrong thing if the case were reached.

**Nothing relies on redirect resizing a same-row order.**
- Every redirect test uses distinct ids: ROMS UnitTest candidates 21 vs 20, ReassignTest 99 vs moved, FirstTouch 99 vs `SU_SRC`.
- The grep for same-row fixtures in `src/test` found none.
- AC2 (R-5) "downsizes requestedamount to the alternate's available quantity" (ReassignTest:178-189) is a different-row redirect and is unaffected.

**Share reuse after Fix E.** The id does not change, so the `Share` from `isSourceUsable` is still valid (no reservation writes happened). "Only after a redirect changes the source" should say "changes `stockunitId`", so the executor does not recompute it and trip U-8's `times(1)`.

### 3. §8.1 checked against the actual tests

`ReplenishmentOrderMaintenanceServiceUnitTest`:

| Row | Verified? |
|---|---|
| `cancelsOrderWhenShortageAtOrBelowThreshold` (:595-629), 100/0/10 → F with reserved 10 | ✓ `held = 10` → −10 |
| SBDEV-3605 U-A1 (:1116-1154) → F | ✓ numerically (−10). The fixture becomes 0/10/10, i.e. `res > amount`. Rename "consistent" to "held == requested". |
| `updatesRequestedAmountWhenDiffers` (:740-776) → A: requested 50, delta +50 | ✓ held 0, free 50, capacity 50, delta +50 |
| `fallsBackToDefaultUpperBoundOnNonNumeric` (100/0/10, delta 74) → F | ✓ held 10, free 90, desired 84, delta 74 |
| `cancelsWhenRedirectedSourceHasNoAvailability` (:671-737) → A | **Problem (M-A2).** Keeping the cancel needs `capacity = 0`. With `amount > 0` that means `held = 0`, so the post-redirect cancel releases **0** and the verified `−5 CANCELLED` pair (:734-736) cannot survive. The honest rewrite verifies `never()` on the CANCELLED release on the candidate. More broadly, once the order holds its own SWITCHED reservation, `held ≥ newReq > 0` and `capacity > 0`, so ROMS:313 `desiredAmount <= 0` after a redirect is effectively dead in production. Record that. |
| Reassign release-once pins → F plus the new stub | ✓ only with the same-instance stub, `@Mock PickingorderPositionRepository` and reserved 10 (M-A) |
| FirstTouch `verifyNoMoreInteractions` → unchanged | ✓ All three tests end with `source == null`: :130/:189/:235 stub `findByIdForUpdate(SU_SRC)` to empty, and the post-redirect `findById(99L)` is unstubbed → empty → `recalculateOrder` returns at ROMS:297. No share query runs. |

**Missing rows (M-A1):**
- **`noUpdateWhenAmountUnchanged`** (:779-811), 84/0/84.
  - New code: `held = min(84, 0) = 0`, free 84, capacity 84, desired 84, delta **+84**.
  - So `verify(stockunitBusinessService, never()).changeReservedAmount(...)` and `verify(replenishorderRepository, never()).save(order)` both go red.
  - Treatment F (reserved 84): `held = 84`, delta 0, return.
- **`treatsEmptyTotalsRowsAsZero`** (:1406-1458), 50/0/10.
  - It asserts `isEqualByComparingTo(new BigDecimal("60"))`, which is above amount 50. This is the same bug-pin as `updatesRequestedAmountWhenDiffers`.
  - Treatment A: requested 50, delta +50.
- **DI wiring.** ROMS UnitTest (:62-81) and ReassignTest (:61-68) declare no `PickingorderPositionRepository` mock. The new ROMS constructor parameter is injected as null and NPEs inside the `recalculateForItem` catch. Every test reaching a non-null source then reds with a misleading WARN-and-skip. Add `@Mock` and the lenient zero stubs to both classes, and say so in §8.1.

**Integration tests I checked that survive:**
- `ReplenishmentStaleVersionAtLockReadIntegrationTest` AC-5: req 0, res 99950, no other order. `held = 0`, free 50, desired 50. Same result as today.
- `ReplenishmentOrderMaintenanceServiceIntegrationTest` concurrency: req = res = 0, so the second thread gets `delta = 0`.
- `ReplenReassignOnNonReplenishableMoveIT`: SU_MOVED 100/REQ is consistent, so release REQ → 0 ✓.
- `ReplenishFinishStaleSourceIT`: asserts only relative post-redirect values.

### 4. New false or over-strong claims

- **§7 pre-mortem 1:** "§8.1 lists every expected flip". False: two rows and the DI wiring are missing (M-A1).
- **§9 #6:** "Fix B steps 3–4 remove the throw paths when … `res > amount`". This covers only `updateRequestedAmount`, not cancel or redirect (M-C).
- **§3 Fix E:** "On the move path, sizing waits for the next cron". This describes an unreachable path whose outcome would be wrong if reached (M-B).
- **§8 U-4 and U-9** are green on today's code:
  - U-4: capacity `20 − 12 + 5 = 13`, desired 5 == requested, so it returns early.
  - U-9: capacity `20 − 2 + 9 = 27`, desired 9 == requested, so it returns early (unless the WARN is asserted).
  - They kill mutants of the new code, but they do not fail at the TDD gate (L-B).
- **§8 IT-3** asserts `== 9` but never pins shortage = 9. With shortage > 9, Fix B correctly grows the order to `min(shortage, 20)` (L-C).
- **DB claims re-measured** on DEV today:
  - orders 565 · would_shrink 53 / 393 units · topup_only 2 · holderless 93 · shared 0 · broken 0 · `res > amount` with an open order 0 · null stockunit_id 0.
  - All match §1.

## Root Cause

This confirms r1 and r2: capacity and delta are priced against `requested` on the assumption that `requested ⊆ reserved` (ROMS:607-612, :615-619). The r2 design fixes that. What remains wrong is completeness bookkeeping around it: the flip list, the reach of the guard, and move-path semantics.

## Findings

**M-A1 (Medium): §8.1 misses two ROMS unit tests that go red.**
- Rows to add:
  - `noUpdateWhenAmountUnchanged` (:779-811), `never()` at :809-810 → **F**: reserved 84.
  - `treatsEmptyTotalsRowsAsZero` (:1406-1458), `isEqualByComparingTo(new BigDecimal("60"))` → **A**: requested 50, delta +50.
- Also add the `@Mock PickingorderPositionRepository` and lenient zero stubs to ROMS UnitTest and ReassignTest.
- Without these, pre-mortem 1's own mitigation fails on its first red.

**M-A2 (Medium): the redirect-then-cancel rewrite cannot keep the `−5 CANCELLED` evidence.**
- With `amount > 0`, `capacity = 0` requires `held = 0`, so the cancel releases nothing.
- State in §8.1 that the second `inOrder.verify` (:734-736) becomes `never()`. Also note that ROMS:313 after a redirect is now reachable only when the order holds nothing.

**M-B (Medium): Fix E must not re-point on the move path.**
- A same-row candidate there is either impossible (the native query auto-flushes the moved UL) or evidence of a stale read. Re-pointing it contradicts AC5-guard (ReassignTest:313-327).
- Fix: in `redirectSource`, apply the re-point only on the recalc path. On `reassignOrCancelForMovedStockUnit`, treat `candidate.stockUnitId == movedStock.getId()` as no candidate, which leads to the AC3 cancel.
- Add U-12b on the ReassignTest for this.
- Delete the "sizing waits for the next cron" sentence.

**M-C (Medium, 0 DEV exposure): the `res > amount` guard does not cover the releases, and Fix C adds one new throw in that corner.**
- Evidence:
  - SBS:519-520 `if (stockUnit.getAmount().compareTo(newReservedAmount) < 0) throw … CANNOT_RESERVE_MORE_THAN_AVAILABLE` fires on releases too.
  - `releaseReservation`'s catch (ROMS:646-648) cannot un-mark the rollback-only transaction, which the plan's own §2 notes.
- Example: amount 5, res 12, others 8, req 10.
  - Old cancel released 10 → res 2, and succeeded (stripping another holder).
  - Fix C releases `held = 4` → res 8 > 5 → throws, poisoning the shared `recalculateForItem` transaction, including the `transferStock` caller.
- Fix: apply step 4's predicate in `cancelOrder` and `redirectSource`. When `res − held > amount`, skip the release with a WARN, and still cancel or re-point.
- Add U-10b. Correct §9 #6.

**L-A: compute `Share` before `isSourceUsable`'s early returns** (`source == null` / `amount <= 0`, ROMS:425-430). Fix C's redirect release needs `held` for a current source whose amount is ≤ 0: `cancelsWhenRedirectedSourceHasNoAvailability` and U-A1 both redirect from an amount-0 source. Computing it in `ensureValidSource` right after the lock (ROMS:407-408) is simplest.

**L-B: label U-4 and U-9 as green-at-gate by design**, and mutation-check them after implementation. Or make U-9 assert the WARN, so that it is red today.

**L-C: IT-3 must pin shortage = 9** (upper bound minus destination stock minus inbound). Otherwise the asserted `== 9` is wrong.

**L-D: keep the `cancelOrder/3` and `releaseReservation/4` signatures**, which `MultiUnitLoadOwnShareContractUnitTest:196-210` pins. Pass `Share` by field or overload rather than by changing their parameter lists, or add a §8.1 row.

**L-E: Fix D wording.** Change "the release … already performs the same upgrade" to "whenever a release amount > 0 occurs". For the ReassignTest stub, name the same-instance requirement: `thenReturn(Optional.of(movedStock))`.

## Recommendations

1. **M-A1 and M-A2:** add the three §8.1 rows (the two tests plus the DI wiring) and correct the redirect-then-cancel row. Effort: trivial. Impact: the test gate stays honest.
2. **M-B:** limit Fix E to recalc; a same-row candidate on the move path is treated as no candidate. Effort: small. Impact: keeps the AC5 invariant.
3. **M-C:** add the `res > amount` skip to the release sites and U-10b. Effort: small. Impact: removes a new transaction-poisoning corner.
4. **L-A to L-E:** compute the share before the early returns, label the green-at-gate tests, pin IT-3's shortage, keep the contract-pinned signatures, and fix the Fix D wording. Effort: trivial.

## Trade-offs

| Option | Pros | Cons |
|---|---|---|
| r2 as written | Sound arithmetic; MRS really untouched; move path locked | §8.1 incomplete; Fix E wrong if reached on the move path; release-site throw in the `res > amount` corner |
| r2 plus M-B (no re-point on the move path) | Keeps AC5; the move path stays simple | A theoretically-stale same-row case cancels instead of re-pointing, which is conservative |
| r2 plus M-C (skip a release that would throw) | No shared-transaction poisoning | The order is cancelled while its `held` stays reserved on a corrupt SU. That is the same accepted leftover as step 4, visible only through the WARN |
| Release `max(held, res − amount)` instead of skipping | Repairs `res > amount` in passing | Releases another holder's share, which is the SBDEV-3605 defect class. Rejected |

## Consensus Addendum

**Antithesis (steelman).** Drop Fix E entirely.
- A same-row redirect needs a stale `requestedlocationId`, and DEV has 0 such orders.
- On the recalc path, Fix B already regrows the order in the same transaction. So the only cost of *not* having Fix E is three stockrecord rows for a no-op, on a path with no measured traffic.
- Fix E adds a branch, a test (U-12) and a move-path hazard (M-B) to remove cosmetic churn.

**Tradeoff tension.** The ledger-noise argument cuts the other way.
- Without Fix E, a same-row redirect with `held > free` shrinks the order to `min(req, free)`. On the recalc path Fix B regrows it, but it writes SWITCHED +free, CANCELLED −held, then REPLENISHMENT +x under one number. That ledger reads like a real source change to anyone auditing stockrecord.
- Fix E trades that noise for one small, recalc-only branch.

**Synthesis.** Keep Fix E, limited to the recalc path (M-B). The move path then keeps its existing semantics exactly, and the recalc path gets a clean re-point.

**Principle violations (deliberate mode):**
- **Completeness claim not met (Medium).** "§8.1 lists every expected flip" (M-A1).
- **Guard scoped narrower than its claim (Medium).** §9 #6 "remove the throw paths when … `res > amount`" (M-C).

## References

**Code** (`/Users/np1076/dev/spk/owl/v2/wms2-api`, `origin/develop` @ `652f37f7`):
- `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java`
  - :220-250 move entry; :237 order lock; :247-248 redirect or cancel
  - :279 recalc order lock; :296-318 source, shortage, desired; :407-421 `ensureValidSource`; :425-435 early returns before capacity; :449 location-mismatch route
  - :491 `newRequested`; :510-514 same-row comment; :531 target lock; :557-559 redirect release
  - :607-628 helper and `updateRequestedAmount`; :634-636 cancel release; :643-648 `releaseReservation` catch
- `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java` — :509 lock upgrade; :513 refresh; :519-520 over-amount throw on any delta
- `src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java` — :245 location lock; :521-522 UL location write; :534-538 BLOCK_REALIGN loop, `findByUnitloadId`, sync
- `src/main/java/net/aim_ai/wms/service/PickLineRealignmentService.java` — :127-138 writes only the pick position
- `src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java` — :33-47 JPQL `findByIdForUpdate`; :315-330 native candidate query (`useforreplenish`, lane predicate)
- `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderSourceSyncService.java` — :72-80 delegation
- `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java` — :1426-1433 `ownShareOfReservation`

**Tests** (`src/test/java/net/aim_ai/wms/...`):
- `unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java` — :62-81 mocks (no pick repository); :595-629; :671-737 (:734-736 the pair); :740-776; **:779-811 missing row**; :1116-1154; **:1406-1458 missing row**; ~:1497-1545 (delta 74)
- `unit/service/ReplenishmentOrderMaintenanceServiceReassignTest.java` — :61-68 mocks; :83-84 `new Stockunit()`; :204-206 AC3; :272-284 AC5-sanity; :307-309 M4; :313-327 AC5-guard
- `unit/service/ReplenishmentFirstTouchInvariantUnitTest.java` — :130/:189/:235 empty source; :213-214 and :264 `verifyNoMoreInteractions`
- `unit/repo/MultiUnitLoadOwnShareContractUnitTest.java` — :150-189 MRS pins survive; :196-210 ROMS signature pins
- `unit/service/mobile/MobileReplenishServiceUnitTest.java` — :4411-4420 reflective U-2 survives
- `integration/service/ReplenishmentStaleVersionAtLockReadIntegrationTest.java` — AC-5 (~:411-465) survives
- `service/ReplenReassignOnNonReplenishableMoveIT.java` — :153, :276-302 consistent fixtures survive

**Plan:** `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3618-evidence/plan-r2-snapshot.md`

**DB** (DEV wineco `dev_wh01_om1`, 2026-10-01; the first query dropped, the retry succeeded):
- 565 open orders; would_shrink 53 / 393 units; topup_only 2; holderless surplus 93; shared 0; invariant broken 0; `res > amount` with an open order 0; release-would-throw 0; null stockunit_id 0.
- PROCESSABLE orders with a location mismatch (the Fix E trigger): 0.

**Verdict: SOUND-WITH-CHANGES.** Apply M-A1, M-A2, M-B and M-C before the TDD gate. The Lows can go in the same pass.