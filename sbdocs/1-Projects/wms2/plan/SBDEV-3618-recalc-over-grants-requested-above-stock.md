---
title: "Recalc books against the order's held share, not its requested amount: no over-grant, reserved == requested after recalc"
ticket: "SBDEV-3618"
ticket_url: "https://app.clickup.com/t/868mbz1jp"
type: "bugfix"
priority: "high"
status: "implemented"
tier: T3
repos: [wms2-api]
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-10-01"
updated: "2026-10-01"
revision: "r2.1 — round 2: architect SOUND-WITH-CHANGES (0 High), critic APPROVE (0 High); all r2 Mediums and Lows applied. r2 applied round 1 (2+2 High). Reviews in SBDEV-3618-evidence/"
db_verified: true
db_verified_note: "DEV wineco (dev_wh01_om1) only, 2026-10-01. PRD not measured: every PRD MCP failed to connect this session. §5.1 prerequisite; it does not gate."
base_commit: "wms2-api 652f37f7 (origin/develop, fetched 2026-10-01)"
related:
  - "[[SBDEV-3605]]"
  - "[[SBDEV-3244]]"
  - "[[SBDEV-2610]]"
tags:
  - plan
---

# SBDEV-3618 — Replenishment recalc over-grants an order's requested amount

**Ticket:** [SBDEV-3618](https://app.clickup.com/t/868mbz1jp) · **Tier:** T3 (reservation data integrity) · **Branch:** `bugfix/SBDEV-3618-recalc-held-share` · **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3618` · **Reviews:** `SBDEV-3618-evidence/{architect,critic}-r1.md`

## 0. Affected sites

**Method.**
- For the arithmetic: the symbol `getAvailableIncludingReservation` (2 callers) and the pattern `subtract(.*reserved.*).add(` (1 site).
- For release amounts: the full `changeReservedAmount(` inventory on `origin/develop`, with each call site classified by where its amount comes from. There are 27 call sites.
- The table shows only the replenishment-order sites. The rest of the 27 book picks or customer orders, not replenishment orders, and are out of scope: `CustomerorderService`, `PickingorderBusinessService`, `ReleaseOrderJobService`, and the MRS multi-UL sites SBDEV-3605 already fixed.
- Blind spot: sites that reserve through another API (for example, `StockunitService.adjustReservedAmount`'s absolute set). That one is P-2.

| # | Site (file · quoted snippet) | Construct | Same cause? | In scope? |
|---|---|---|---|---|
| 1 | ROMS · `return amount.subtract(reserved).add(currentRequest);` | capacity adds back full requested | **yes** | **yes**, Fix A (deleted) |
| 2 | ROMS · `BigDecimal desiredAmount = shortage.min(getAvailableIncludingReservation(source, order));` | caller (`recalculateOrder`) | yes | yes, Fix A |
| 3 | ROMS · `BigDecimal availableForOrder = getAvailableIncludingReservation(source, order);` | caller (`isSourceUsable`) | yes | yes, Fix A |
| 4 | ROMS · `BigDecimal delta = desiredAmount.subtract(currentRequested);` | delta booked against requested | **yes** | **yes**, Fix B |
| 5 | ROMS · `BigDecimal releaseAmount = safe(order.getRequestedamount());` (`cancelOrder`) | releases requested | yes | **yes**, Fix C |
| 6 | ROMS · `releaseReservation(currentSource, safe(order.getRequestedamount()),` (`redirectSource`) | same | yes | **yes**, Fix C |
| 7 | ROMS · `reassignOrCancelForMovedStockUnit` → `redirectSource(order, movedStock)` / `cancelOrder(order, movedStock, …)` | Fix C would read an **unlocked** SU: `UnitloadBusinessService` passes `stockunitRepository.findByUnitloadId(…)` | yes (precondition) | **yes**, Fix D |
| 8 | ROMS · `BigDecimal newRequested = safe(order.getRequestedamount()).min(candidate.getAvailable());` when the candidate is the current SU | same-row redirect, shrink then regrow | adjacent | **yes**, Fix E |
| 9 | `ReplenishorderService` · `changeReservedAmount(oldSource, requested.negate(), true, WmsConstants.CODE_REDIRECT_REPLENISHMENT_SOURCE` | admin redirect releases requested | yes | no → P-1 |
| 10 | `ReplenishorderService` · `changeReservedAmount(sourceStock, replenishOrder.getRequestedamount().negate(), true, WmsConstants.CODE_REPLENISHMENT_CANCELLED` | admin cancel | yes | no → P-1 |
| 11 | `MobileReplenishService` · `changeReservedAmount(stockUnit_old, requestedAmount.negate(), true, WmsConstants.CODE_REPLENISHMENT_SWITCHED` | single-UL switch | yes | no → P-1 |
| 12 | `MobileReplenishService` · `changeReservedAmount(sourceStock, replenishOrder.getRequestedamount().negate(), true,` (finish, runs on **STARTED** orders) | single-UL finish | yes | no → P-1. ⚠ Recalc never repairs a STARTED order |
| 13 | `ReplenishGeneratorService` · `…getRequestedamount(), false, WmsConstants.CODE_REPLENISHMENT_CREATED` | create reserves requested | no: it adds, and the over-amount check refuses | no |
| 14 | `MobileReplenishService.ownShareOfReservation` | the SBDEV-3605 invariant | building block | arithmetic extracted, Fix A |

**Why #9–#12 are out of scope.** Once Fix B holds, every PROCESSABLE order leaves recalc with `held == requested`, so a later release of `requested` releases exactly `held`. The residual is limited to three cases:
- the gap between drift and the next recalc;
- STARTED orders (#12), which recalc never touches;
- shared SUs, of which DEV has **0** (§1).

## 1. Problem statement and DB evidence

Recalc can raise `requestedamount` above the stock unit's physical `amount`. The picker is then sent for stock that does not exist, and the destination's refill is suppressed.

**Live case, DEV, 2026-10-01.** SU **30685299** holds `amount 18` with `reserved 18`. **REPL389503** (state 300) has `requested 26`. The ticket has the ledger. In short:
1. An admin absolute set (`StockunitService.adjustReservedAmount`) cut the reservation to 1 while the order requested 9.
2. Recalc then computed `18 − 1 + 9 = 26` and booked `+17`.

**Population, DEV, 2026-10-01.** The query is in the appendix. The critic re-ran it and got the same numbers. All 565 open orders are in state 300.

| Measure | Count | Meaning |
|---|---|---|
| `would_shrink` (req > capacity) | **53** orders, **393** units | the over-grants. 393 equals the ticket's "units unbacked" (cross-check) |
| `topup_only` | **2** | under-reserved, and capacity covers requested |
| `holderless_surplus` (ownShare > req) | **93** | reservation no order explains. **Must not be released**, hence `held = min(req, ownShare)` |
| `shared_su`, orders with open picks on the SU | **0**, **0** | the `others` and `picks` terms get unit-test coverage only (§8) |
| broken invariant (`res < others + picks`) | **0** | Fix B's post-condition precondition (§3) holds on all DEV rows |
| SUs with `res > amount` and an open order | **0** (1 SU overall: 30022257, amount −1, no order) | Fix B's `amount` cap (M-2) is defensive |

## 2. Root cause

- **Bug 1: capacity adds back reservation that is not there.** The code computes `amount − reserved + requested`, which assumes `requested ⊆ reserved`. On an under-reserved SU this inflates capacity. `recalculateOrder` grows the order, and `isSourceUsable` keeps an exhausted source "usable".
- **Bug 2: the delta is booked against requested.** `desired − requested` is the wrong base. Fixing Bug 1 alone leaves 18/18/26 at reserved 10 against requested 18: stable, but still under-reserved. The early return `if (desiredAmount.compareTo(currentRequested) == 0) return;` also skips re-reserving an under-reserved order.
- **Bug 3: releases use requested.** `cancelOrder` and `redirectSource` release `requested`. When the order holds less than that, the excess comes out of another holder's reservation. `zeroIfNegative=true` hides it.
- **Guard that does not help.** `changeReservedAmount` throws `CANNOT_RESERVE_MORE_THAN_AVAILABLE` whenever `newReserved > amount`. That check runs on **every** delta, releases included. So a partial release that leaves `res > amount` throws, and the shared tx is marked rollback-only (§3 Fix B step 4).

## 3. Fix design

### Options considered
| Option | Verdict |
|---|---|
| Clamp only: Fix A plus `requested ≤ amount` | Rejected. It leaves `reserved ≠ requested`, so Bug 3 keeps stripping shared SUs. It also does no top-up, against D2 |
| Audited reconciliation job (the SBDEV-2610 `ReplenishmentReservationReconciliationService` precedent) | Rejected as the primary fix. It is an operator step, and Nam declined a repair step (D3). Drift also reappears between runs. That service deliberately zeroes stranded reservations, a different contract from sizing the order |
| New `@Service` holding queries and arithmetic, consumed by both services | Rejected (r1). Mockito `@InjectMocks` passes null or a null-returning mock, which breaks the SBDEV-3605 suites. Every consumer test would also stop exercising the rule |
| **Pure static arithmetic shared by both services, each keeping its own two queries** | **Chosen.** One home for the invariant, testable directly. MRS keeps its queries, so its tests are unchanged in fact, not just in claim. The cost is two duplicated scalar-query call lines |

### Definitions (`ReservationShare`, new `final` class with static methods only, in `service/`)
- `ownShare(res, others, picks) = max(0, min(res, res − others − picks))`, the SBDEV-3605 formula, moved verbatim.
- `held(req, ownShare) = min(max(req,0), ownShare)`. The order never claims holder-less surplus beyond its requested amount.
- `free(res, amount) = max(0, amount − res)`.
- `capacity(held, free, amount) = min(held + free, max(amount,0))`. The `amount` cap handles a SU where `res > amount`: `free` is 0, but `held` could still exceed stock.
- `invariantHolds(res, others, picks) = res ≥ others + picks`.
- **Every input treats `null` as 0.** An unstubbed Mockito `BigDecimal` returns null, and the entity columns are nullable.

### Fix A: `ReservationShare` plus one share per order
- `MobileReplenishService.ownShareOfReservation` keeps its two queries and its signature. Its return line becomes `ReservationShare.ownShare(...)`.
- ROMS gets `PickingorderPositionRepository` as a new constructor parameter. It computes a `Share` record `(ownShare, held, free, capacity, invariantHolds)` from the locked source.
  - **Where:** in `ensureValidSource`, straight after the first-touch `findByIdForUpdate`. That is before `isSourceUsable`, so its early returns (`source == null` / `amount <= 0`) still leave a `held` for `redirectSource` and `cancelOrder`.
  - **Recomputed** only when a redirect changes `stockunitId`, and then only after the post-redirect `findById` re-read. If that re-read is empty, no query runs, so `ReplenishmentFirstTouchInvariantUnitTest`'s `verifyNoMoreInteractions` still holds.
  - Common path: **2 scalar queries per order**. A `times(1)` verify pins it.
  - `cancelOrder(order, source, code)` and `releaseReservation` **keep their arities**, which `MultiUnitLoadOwnShareContractUnitTest` pins (`cancelOrder/3`). The Share reaches them through a private overload or by on-demand computation from `source`. A null source gives held 0, so no release.
- `getAvailableIncludingReservation` is deleted. `isSourceUsable` tests `share.capacity > 0`, and `desired = shortage.min(share.capacity)`.
- Update the comment `// Treat the source as usable if it still has availability for this order (amount - reserved + current request)`.

### Fix B: `updateRequestedAmount(order, source, share, desired)` books against held
1. Compute `delta = desired − share.held`.
2. If `delta == 0` and `desired == requested`, return. That is the steady state, so a second recalc is a no-op.
3. If `delta > 0` and `!share.invariantHolds`: skip the booking, set `requested = min(desired, requested)`, and log at WARN ("another holder is short"). Recalc must not ratchet a broken shared SU. Attribution caveat: when the invariant holds, the ledger cannot tell which holder is short. A top-up is booked under the number of the order being recalculated. The quantities converge, but the attribution may not. DEV `shared_su` = 0.
4. If `delta < 0` and `res + delta > amount`, the release would throw. Skip the booking with a WARN and still set `requested = desired`. `res > amount` stays for the admin/reconciliation path, and 0 such SUs have an open order on DEV.
5. If `delta ≠ 0`, call `changeReservedAmount(source, delta, true, CODE_REPLENISHMENT, number, null)`. Keep the same catch: WARN, then return.
6. Log at INFO when `desired < shortage && desired < requested` (the order is bounded by its stock unit), and on the cancel branch when the source leaves the order nothing. That is the convergence signal.
7. Set `requested = desired` and save.

**Post-condition, when `invariantHolds`:** `held' == requested'` and, unless `res` already exceeded `amount` (then step 4 skips the booking), `res' ≤ amount`.
- Write `O = others + picks`. Then `ownShare = res − O ≥ held`.
- `res' = res + desired − held`, so `ownShare' = ownShare + desired − held ≥ desired`, and therefore `held' = desired`.
- If `delta > 0`: `res' ≤ res + free ≤ amount`.
- If `delta < 0`: `res' ≥ O ≥ 0`.
- Both the architect and the critic checked this. **When the invariant is broken** (0 DEV rows), the order is only capped at `min(requested, capacity)` and nothing is booked (D2⁗); a zero-request order is cancelled. The post-condition is not claimed.

### Fix C: releases use held
- `cancelOrder` releases `share.held`. The existing `> 0` guard stays on `held`: the pin "does not call changeReservedAmount when requestedAmount is zero" still holds.
- `redirectSource` releases `held` from the current source. It computes `held` before the target reservation. A `held` of 0 skips the release call, as in `cancelOrder`.
- **Same `res > amount` guard as Fix B step 4.** If `res − held > amount`, the release would throw (`changeReservedAmount` checks `amount` on every delta). In that case skip the release, log at WARN, and still cancel or re-point. Otherwise the shared `recalculateForItem` tx would be marked rollback-only, `transferStock` included. Today's code has the same exposure. DEV has 0 such rows.

### Fix D: lock the moved SU (move path)
- In `reassignOrCancelForMovedStockUnit`, right after the order's state guard, take `Stockunit locked = stockunitRepository.findByIdForUpdate(movedStock.getId()).orElse(null)`. Pass `locked` to `redirectSource` and `cancelOrder`, then compute `Share` from it.
- This is a lock *upgrade* of a READ-managed row, so it is version-checked (the SBDEV-3244 mechanism). That is no worse than today: whenever this path releases an amount above 0, `changeReservedAmount`'s own `findByIdForUpdate` performs the same upgrade later. Fix D also takes it when nothing is released, and the throw arrives earlier. `movedStock` is not dirty at that point: `processTransfer` writes only the unit load and the pick positions before the sync. A concurrent committed writer is the only way it throws (pre-mortem 2).
- The move path's lock order becomes order → current → target, matching recalc. That removes the move-path half of the ABBA named in `redirectSource`'s comment ("reassignOrCancelForMovedStockUnit's redirect/release path is still target->current"). Update the comment; the cross-order residual stays.

### Fix E: a same-row redirect is a re-point, on recalc only
- **Recalc path.** If the chosen candidate is the current SU, which the code allows ("So current and target CAN be the same row"), update only the location fields, write no reservation, and return true. The precedent is `ReplenishmentOrderSourceSyncService`: "stockunitId / reservedamount / requestedamount intentionally UNCHANGED". The `Share` stays valid because `stockunitId` does not change. Fix B then sizes the order in the same tx. The trigger is the location-mismatch route in `isSourceUsable`, and DEV has 0 such orders today.
- **Move path.** A same-row candidate is treated as **no candidate**, which leads to the AC3 cancel.
  - The candidate query requires `useforreplenish = true` and auto-flushes the moved UL's new location. A moved SU on a non-replenishable destination therefore cannot be offered.
  - If it were offered, that would mean a stale read. Re-pointing to it would break AC5-guard ("does not re-point the order onto the moved (non-replenishable) source").
- This removes today's shrink to `min(req, free)` on a same-row redirect, and its SWITCHED/CANCELLED ledger noise.

### Behaviour changes
1. The 53 DEV orders (393 units) shrink on their next recalc. An order below the cancel threshold is cancelled instead. Also, `others` sums the other orders' *requested* amounts, so an over-granted sibling can make this order's SU look invariant-broken until the sibling has shrunk. With **two or more** over-granted orders on one SU, each sees the other as the short holder and neither converges: each is at most capped to its capacity once, then stays. That SU stays as it is, with a WARN every cycle, until an admin repairs it. This was accepted by Nam (2026-10-01, re-review M-A) and is pinned by U-16. Otherwise `would_shrink → 0` can take more than one cron; a stock unit with ≥2 over-granted orders never reaches 0 without an admin.
2. Under-reserved orders (an admin cut, including the live case and the 2 DEV `topup_only` orders) shrink to what they hold, and are cancelled at 0. Nothing is re-reserved (D2″).
3. Cancel and redirect release only what the order holds.
4. Holder-less surplus is untouched.
5. A source whose capacity is 0 because other holders take it all is now "unusable", so the order is redirected or cancelled.
6. Maintenance can now also *shrink* a PROCESSABLE template inside a multi-UL pick. SBDEV-3605 computes `ownShare` after that step, so the two stay consistent.

## 4. File change summary
| File | Change |
|---|---|
| `service/ReservationShare.java` | **new**: static arithmetic |
| `service/ReplenishmentOrderMaintenanceService.java` | new ctor param `PickingorderPositionRepository`; `Share` record; Fixes A–E; two comments updated |
| `service/mobile/MobileReplenishService.java` | `ownShareOfReservation` return line only |
| tests | §8 and §8.1 |
| docs | `design/wms2-replenishment-design.md` §7, `design/wms2-stockunit-design.md` §6, `architecture/wms2-transaction-osiv-boundary-map.md` §8.5 (move-path lock order), `architecture/wms2-function-to-docs-map.md` §9 |

## 5. Implementation steps
1. **TDD gate.** The tests must compile against today's code, so no test may reference `ReservationShare` directly.
   - `ReservationShareContractUnitTest` is a reflection test. It asserts that the class exists and that its static-method set matches by name and parameter count. It fails with a class-not-found assertion.
   - U-1 to U-10 go through the existing ROMS surface. `@Mock PickingorderPositionRepository` compiles today.
   - IT-1 to IT-3.
2. Add `ReservationShare`, then switch MRS's return line. The SBDEV-3605 suites must pass with **zero** test edits. That is the check that the extraction is behaviour-neutral.
3. ROMS Fix A plus the ctor param. Apply the §8.1 fixture and pin changes in the same commit.
4. Fix B, then C, then D, then E, each as its own commit.
5. Update docs, run the full `mvn clean verify` against a fresh baseline, and run PIT scoped to ROMS and `ReservationShare`.

### 5.1 Prerequisites
| Item | State |
|---|---|
| Flyway / sysprop / flag | N/A. Both indexes exist (`replenishorder_stockunit_id`, `index_pickingorder_position_pickfromstockunit_id`) |
| PRD measurement | **Before and after deploy; does not gate.** Run the ticket's query on the 4 PRD tenants. Positive control: DEV SU 30685299 |
| Deploy order | N/A |

## 6. Horizontal scalability and v2 constraints
| # | Concern | Verdict |
|---|---|---|
| 1 | In-JVM state | No. The class is static and pure |
| 2 | Pool math | No |
| 3 | Scheduled jobs | No new job. The replenish cron gets +2 indexed scalar queries per order (+2 more after a redirect). The JPQL sums may auto-flush the dirty order row, which is harmless |
| 4 | Long tx | No |
| 5 | Affinity | N/A |
| 6 | Retry / idempotency | **Yes, improved.** When the invariant holds, a re-run writes nothing (IT-2) |
| 7 | Tenant context | Unchanged |
| 8 | Locks | **Yes.** No new lock on recalc. The move path gains one SU lock (Fix D), which aligns it with recalc's order |
| 9 | Cache | N/A |
| 10 | External notify | N/A |

v2 constraints: no new `@Transactional` (joins the caller) · no OSIV reliance · constructor injection · JPQL only (H2-safe) · no controller change · existing cron metrics plus INFO/WARN logs.

## 7. Risks and pre-mortem
| Scenario | Mitigation |
|---|---|
| **Pre-mortem 1.** An executor meets a wall of existing reds and edits assertions until green, hollowing out the SBDEV-3244 and SBDEV-3605 pins | §8.1 lists every expected flip with old and new values. Method: two review lanes read all four ROMS/contract test classes and the replenishment ITs; blind spot: classes neither lane opened. An existing assertion **not** in §8.1 may not change without stopping and recording it there, with its reason. MRS suites: zero edits (§5 step 2) |
| **Pre-mortem 2.** Fix D's lock upgrade throws stale on busy moves, and the operator sees 409s | This is the same throw point the release already hits today on that path. The move is operator-paced. ReassignTest pins the lock order |
| **Pre-mortem 3.** Recalc ratchets a broken shared SU, backfilling another order's deficit under this order's number | D2⁗: on a broken invariant the order is only capped, nothing is booked, and no order is picked to be cancelled; WARN. U-9 and U-9b |
| The shrink surprises an operator | Only PROCESSABLE orders, and only down to what physically exists |
| `res > amount` release throws, and the whole `recalculateForItem` tx rolls back | Fix B step 4 skips the booking. U-10 |

## 8. Testing plan
Each test names the mutant it kills. Shortage is stated where it matters. "Delta" means the `changeReservedAmount` argument.

**Unit, ROMS (existing surface).** Default: `sumRequestedAmountOfOtherOpenOrdersOnStockunit` and `sumOpenAmountByPickfromstockunitId` are `lenient()`-stubbed to 0 in `@BeforeEach`.
- **U-1:** 18/1/9, shortage 40 → requested 18, delta +17. Kills the old add-back, which gives 26.
- **U-2:** 18/18/26, shortage 40 → requested 18, no `changeReservedAmount`. Kills delta-against-requested (−8). Current code gives 26.
- **U-3:** 20/5/9, shortage 9 → delta +4, requested 9. Kills the old early return.
- **U-4:** holder-less surplus, 20/12/5, shortage 5 → no call, requested 5. **Green at the gate by design**: the old and new formulas agree when held == requested. It is a mutant pin for `held = ownShare` (which would book −7), and is mutation-checked after implementation.
- **U-5:** `isSourceUsable` on 18/18 where another order requests 18 and this order requests 4 (the invariant holds: 18 ≥ 18) → unusable, so the redirect/cancel path is taken. Kills the old helper: `18 − 18 + 4 = 4 > 0`, which says usable. New: own 0, held 0, free 0, capacity 0.
- **U-6:** `cancelOrder` on 20/3/9 → delta −3. Kills release-of-requested (−9).
- **U-7:** redirect from current 20/3/9 to another SU → current delta −3. Same kill as U-6.
- **U-8:** the common path calls `sumRequestedAmountOfOtherOpenOrdersOnStockunit` exactly `times(1)`. Kills per-call recomputation.
- **U-9:** broken invariant: 20/2/9 with others 5, **shortage 12** → no `changeReservedAmount`, requested 9. Today's code gives +3 and requested 12. Kills a top-up without the invariant check (+9).
- **U-10b:** cancel on 5/12/10 with others 7 (held 5; `res − held = 7 > 5`) → no release, order CANCELED, WARN. Today's code releases −10, which would throw. Kills an unguarded release.
- **U-10:** 5/12/10, sole holder, shortage 10 → no `changeReservedAmount`, requested 5. Kills the booking that throws. Current code: 5 − 12 + 10 = 3, so requested 3 and delta −7, which would throw in reality.
- **U-11, move path (`ReplenishmentOrderMaintenanceServiceReassignTest`):** `InOrder` shows `findByIdForUpdate(movedId)` before any `findByIdForUpdate(candidateId)`, and releases use the locked instance's held (20/3/9 → −3). Kills Fix D's absence.
- **U-12, same-row redirect (recalc):** the candidate id equals the current id → no `changeReservedAmount` with `CODE_REPLENISHMENT_SWITCHED`, and the location fields are re-pointed. Kills Fix E's absence.
- **U-12b, same-row candidate on the move path (`ReassignTest`):** → treated as no candidate, so the order is cancelled and not re-pointed. Kills applying Fix E on the move path.

**Unit, `ReservationShareUnitTest`** (written in §5 step 2, after the class exists): a table of cases for each function, including null, negative and zero inputs. Mutation-checked with PIT.

**Integration** (Testcontainers, commit semantics; `ReplenishmentOrderMaintenanceServiceIntegrationTest`). Assert by id; counts use `stockrecord WHERE fromstockunitidentity=? AND ordernumber=?` (the column the existing fixtures use, `AbstractReplenishRedirectPgFixture`), with no `created` or `id` watermark.
- **IT-1:** the live sequence. Create the order (req 9), call `adjustReservedAmount` to 1, then `recalculateForItem` with **shortage ≥ 26**. Assert `requested == reserved == 18 ≤ amount`. Current code gives requested 26.
- **IT-2:** a seeded 18/18/26, shortage ≥ 26. Run 1 gives requested 18 and **0** new stockrecord rows for the SU and order. Run 2 gives 0 rows again. Kills dropping the `delta ≠ 0` guard, which writes a zero-delta row on run 1. Current code gives requested 26.
- **IT-3:** a same-row redirect. The SU is 20/1/9 in a replenishable area, and the order's `requestedlocationId` does not match the SU's location (the SBDEV-2492 route), so recalc finds the SU unusable and picks the same SU as candidate. **Shortage is exactly 9**, with the cancel threshold below it. Assert `stockunit.reservedamount == replenishorder.requestedamount == 9`, and no `REPLENISHMENT_SWITCHED` row. Current code ends at reserved 1 against requested 9.

**Regression:** full `mvn clean verify` against a fresh `origin/develop` baseline. PIT scoped to ROMS and `ReservationShare`.

### 8.1 Existing pins that change
These are in `ReplenishmentOrderMaintenanceServiceUnitTest` unless noted. The default fixture `buildStockunit(…, amount, BigDecimal.ZERO)` with requested 10 is **under-reserved**, which is the state this fix re-prices. The treatment for each row is either **F** (fixture made consistent, reserved = requested, assertion unchanged; the old and new formulas agree when `held == requested`) or **A** (the assertion changes, because the pin encoded the bug).

| Test (snippet) | Old | New | Treatment |
|---|---|---|---|
| `cancelsOrderWhenShortageAtOrBelowThreshold` | release −10 on reserved 0 | −10 | F: reserved 10 |
| SBDEV-3605 U-A1 redirect release | −10 from `originalSu`, reserved 0 | −10 | F |
| `"updates requested amount when desired amount differs from current"` (50/0/10) | requested **60** (> amount 50) | requested 50, delta +50 | **A**: the pin *is* the bug |
| default-upperbound test (100/0/10) | delta 74 | 74 | F: reserved 10 |
| redirect-then-cancel (`// The ENTITY disagrees with the projection: 15 - 20 + 5 = 0 availability.`) | cancel; SWITCHED +5, then CANCELLED −5 | candidate entity `buildStockunit(21L, 51L, BigDecimal.ZERO, new BigDecimal("5"))`, others 0: own 5, held 5, free 0, capacity `min(5, 0) = 0`. Still cancelled, and the SWITCHED +5 / CANCELLED −5 pair is **preserved**. The mocked `changeReservedAmount` does not mutate the entity, so the fixture models the post-reserve state | **F** (fixture, comment updated) |
| `noUpdateWhenAmountUnchanged` (84/0/84) | `never()` on `changeReservedAmount` and on `save` | the same | F: reserved 84 (held 0 would book +84) |
| `treatsEmptyTotalsRowsAsZero` (50/0/10) | `changeReservedAmount(… 50 …)`, requested **60** (> amount 50) | delta +50, requested 50 | **A**: the same bug-pin as `"updates requested amount when desired amount differs from current"` |
| DI wiring: ROMS UnitTest and `ReassignTest` | no `PickingorderPositionRepository` mock, so the new ctor param would be null | add `@Mock PickingorderPositionRepository`, plus `lenient()` zero stubs for both sums in `@BeforeEach` | test infra |
| `ReplenishmentOrderMaintenanceServiceReassignTest` release-exactly-once pins (moved SU `new Stockunit()`, reserved null) | release requested | set the fixture's amount and reserved so that held == requested | F, plus `findByIdForUpdate(MOVED_STOCK_ID)` → `Optional.of(movedStock)`. It must be the **same instance**, because the `eq(movedStock)` pins compare entities |
| `MultiUnitLoadOwnShareContractUnitTest` `cancelOrder/3`, `releaseReservation/4` | pinned arities | unchanged (Fix A keeps them) | none; if it reds, stop |
| `ReplenishmentFirstTouchInvariantUnitTest` `verifyNoMoreInteractions(replenishorderRepository)` | — | the path has `source == null`, so no share query runs | expected unchanged; if it reds, stop |

**Added during implementation (D2″, respect the cut):**

| Test | Old | New | Treatment |
|---|---|---|---|
| `"updates requested amount when desired amount differs from current"` and `treatsEmptyTotalsRowsAsZero` | 50/0/10 → 60, delta 50 | under-reserved now shrinks, so the fixture becomes 50/10/10 → requested 50, delta **40** | A + F |
| `isSourceUsable_gateOff_unchanged` (50/0/10) and `ignoresInactiveFla` (500/0/10) | stay PROCESSABLE / requested 84 | the order holds its 10 | F: reserved 10 (an incidental under-reserved fixture; these tests are about lanes and the inactive FLA) |
| Gate tests U-1, U-3, U-9, IT-1, IT-3 | re-reserve expectations | shrink to held (U-1 → 1, U-3 → 5, IT-1 → 1/1, IT-3 → 1/1); U-9 re-pointed to a zero-request order | design change, not weakening; each still fails on `652f37f7` |
| `NeverMatcherNullBlindnessArchTest` inventory | ROMS UnitTest 4, ReassignTest absent | 6 and 1 | three new `never()` spans on the primitive `boolean zeroIfNegative` |
| `OptionalSafetyArchTest` frozen store | 3 ROMS `Optional.get()` entries | removed | those `.get()` calls were rewritten (the signature change made them "new") |

Any other red in an existing test means stop and add a row here before editing it.

**Manual test plan**
| Scenario | Env | Steps | Expected |
|---|---|---|---|
| Live case converges | DEV wineco | after deploy, one replenish cron (`NEW_CRON_JOB_ACTIVATED=true` on DEV) | REPL389503 requested 18; SU 30685299 reserved 18 |
| Population | DEV, then PRD | appendix query, before and after | `would_shrink` → 0 (possibly after >1 cron); `holderless_surplus` unchanged |
| Unit-load move with an open order | DEV | move a UL holding an order's source within a replenishable area | order re-pointed; reserved == requested |
| Normal refill | DEV | an unaffected FLA below its lowerbound | order created and sized as before |

## 9. Completeness checklist
| # | Concern | Considered |
|---|---|---|
| 0 | DB verified | ✓ §1 (DEV, 7 measures). PRD is §5.1 |
| 1 | Callsites | ✓ §0: 14 rows from the full `changeReservedAmount(` inventory |
| 2 | Adjacent bugs | ✓ §0 #9–#12 → P-1; admin set → P-2 |
| 3 | Backward compat | ✓ no API, schema or payload change; behaviour changes in §3 |
| 4 | Concurrency | ✓ Fix D; §6 #8; pre-mortem 2 |
| 5 | Multi-tenant | ✓ no cross-tenant path |
| 6 | Error handling | ✓ Fix B step 4 and the Fix C guard skip any booking or release that would leave `res > amount` (the only throw `changeReservedAmount` raises on this path). The existing catch is kept |
| 7 | Observability | ✓ INFO when the order is shrunk below its shortage, or cancelled because the source leaves it nothing; WARN on a broken invariant (top-up refused) and on a skipped booking with `res > amount`; ERROR `SBDEV-3618 STRANDED_RESERVATION` on a release skipped because `res > amount`; WARN `SBDEV-3618 UNATTRIBUTED_RESERVATION` when a cancel or redirect off a broken SU releases nothing |
| 8 | Rollback | ✓ plain revert; the old and new formulas agree once `held == requested` |
| 9 | Tests | ✓ §8 and §8.1 |
| 10 | v1↔v2 | no: v1 is reference-only |

## 10. Resolved decisions and proposals
**Resolved (Nam, 2026-10-01):**
- **D1** held share comes from the SBDEV-3605 invariant under the SU lock. Refined to `held = min(req, ownShare)` (93 DEV SUs have holder-less surplus).
- **D2** re-reserve, then shrink. Refined: no top-up while the invariant is broken (Fix B step 3).
- **D2″ (supersedes D2's re-reserve half; Nam, 2026-10-01, during implementation): respect the cut.** An order that holds *less* than it requests is shrunk to what it holds, and cancelled when that is 0. It is never re-reserved. Only an order holding all it requests grows, from free stock: `bound = held < requested ? min(held, capacity) : capacity`, and `desired = min(shortage, bound)`.
  - Found while implementing: [SBDEV-2033](https://app.clickup.com/t/868hyr110) (urgent, WineCo PRD, Closed) was "an admin clears a replenishment reservation and the WMS puts it back".
  - v2's `adjustReservedAmount` still does not cancel the order. Its own comment says "re-triggering replenishment would immediately re-reserve the stock the user just released".
  - Under D2, the once-a-minute WineCo PRD cron would undo every such cut. DEV records 2–3 admin cuts a month.
  - Consequences:
    - the live DEV row (18/18/26, already re-reserved by the old code's +17) shrinks to requested 18 == reserved 18: the order holds `min(26, 18) = 18`. Only the pre-bug state, 18/1/9 (IT-1), shrinks to the admin's 1. ⚠ Corrected 2026-10-01 after deploy: an earlier revision said the live row would settle at 1;
    - the 2 DEV `topup_only` orders shrink instead of being topped up;
    - Fix B step 3 (the broken-invariant top-up refusal) fires for every positive-request order on a broken SU under D2⁗, which logs the WARN each cycle. A zero-request broken order is cancelled before it;
    - a *partial* cut can still be grown back on a later cycle, from the shrunk amount, if the shortage persists. That is also true today.
- **D2⁗ (Nam, 2026-10-01, from code review M-2): when another holder is short** (`res < others + picks`), every order's held share is 0 and the ledger cannot say whose reservation was cut. Respect-the-cut would have cancelled whichever order the cron reached first. Instead:
  - `bound = min(requested, capacity)` and nothing is booked (step 3 refuses the top-up); a WARN is logged;
  - a zero-request order in that state is cancelled, rather than WARNed every cycle (review L-3);
  - the stock unit waits for an admin (P-2). With ≥2 over-granted orders on one SU it never converges on its own; that is accepted (re-review M-A, U-16), and P-1's PRD measurement must count SUs with ≥2 open orders where Σrequested > reserved.
- **D2‴ (Nam, 2026-10-01): a redirect still reserves `min(requested, candidate.available)` at the new SU, as today.** The conformance lane noticed that a cut order whose source has no capacity left is redirected with its full requested amount.
  - Nam's view: the admin's cut belongs to the stock unit that was cut, and that stock unit is still left alone.
  - A redirect means "this source is unusable", which usually means its stock is gone, so moving the order to new stock is the correct outcome.
  - Not changed in this ticket.
- **D3** no data script; recalc converges. PRD is measured before and after.

**Review dispositions (r1 → r2):**
- architect H-1 and critic M-1 → Fix D;
- architect H-2 and critic H-1 → the static-function option and zero MRS test edits;
- critic H-2 → §8.1;
- architect M-1 → Fix E;
- architect M-2 → Fix B step 3 and U-9;
- critic M-2 → the `amount` cap, Fix B step 4 and U-10;
- critic M-3 and architect L-1 → §0 #9;
- critic M-4 and architect L-2 → Share computed once, U-8;
- critic M-5 and M-6 → IT-2 and IT-3 respecified;
- critic M-7 → options table and pre-mortem; round 2 (architect M-A1, M-A2, M-B, M-C, L-A to L-E; critic M-A, M-B, M-C, L-A to L-E) → §8.1 rows and DI wiring, the redirect-then-cancel fixture, Fix E limited to recalc, the release guard, Share placement and arities, null inputs, U-4 labelled, U-9 shortage 12, U-10b, U-12b, IT column and shortages, §0 note;
- critic M-8 → reflection contract test at the gate;
- the Lows → U-7 numbers, shortage stated, the held-guard kept, the INFO condition, the class count (3), and #12's STARTED exposure.

**Proposed (not filed):**
- **P-1 (T3), FILED 2026-10-01 as SBDEV-3621.** §0 #9–#12 release `requested` outside maintenance. #12 runs on STARTED orders, which recalc never repairs. This merges with SBDEV-3605 P-S5S6. Blast radius: shared or under-reserved SUs (DEV 0 shared). Cost: about ½ day with `ReservationShare`. **Do first** of the two.
- **P-2 (T3), FILED 2026-10-01 as SBDEV-3622.** `StockunitService.adjustReservedAmount` (the admin absolute set) can cut below what open orders hold, which is this bug's precondition. The fix would warn or refuse below Σheld. It is a UI and contract change.

## Appendix — DEV population query (2026-10-01)
```sql
WITH o AS (SELECT r.id, r.state, r.requestedamount req, s.amount, coalesce(s.reservedamount,0) res,
 (SELECT coalesce(sum(r2.requestedamount),0) FROM replenishorder r2 WHERE r2.stockunit_id=s.id AND r2.state<700 AND r2.id<>r.id) oth,
 (SELECT coalesce(sum(p.amount),0) FROM pickingorder_position p WHERE p.pickfromstockunit_id=s.id AND p.state<600) picks
 FROM replenishorder r JOIN stockunit s ON s.id=r.stockunit_id WHERE r.state<700),
 h AS (SELECT *, greatest(0, least(res, res-oth-picks)) own FROM o),
 c AS (SELECT *, least(req, own) held, least(least(req,own)+greatest(0,amount-res), greatest(amount,0)) cap FROM h)
SELECT state, count(*) orders, count(*) FILTER (WHERE req>cap) would_shrink, sum(req-cap) FILTER (WHERE req>cap) units_shrunk,
 count(*) FILTER (WHERE held<req AND req<=cap) topup_only, count(*) FILTER (WHERE own>req) holderless_surplus,
 count(*) FILTER (WHERE oth>0) shared_su, count(*) FILTER (WHERE res<oth+picks) invariant_broken FROM c GROUP BY state;
```

## 11. Implementation status

**TDD gate, 2026-10-01.** Commit `6d8c78aa` on `bugfix/SBDEV-3618-recalc-held-share`, base `652f37f7`. Worktree: `.claude/worktrees/wms2-api/SBDEV-3618`.

| Suite | Result on unfixed code |
|---|---|
| `ReservationShareContractUnitTest` | 2/2 red, on assertions: the class is missing, and so is the ctor param |
| `ReplenishmentOrderMaintenanceServiceUnitTest$HeldShareBooking` | 11/12 red, on assertions. U-4 is green by design |
| `ReplenishmentOrderMaintenanceServiceUnitTest` (all nested) | 63 `@Test`s (51 existing + 12 new). The run reported 74, which included the targeted sibling classes. The only failures were those 11 |
| `ReplenishmentOrderMaintenanceServiceReassignTest` | 13 run: U-11 and U-12b red; the 11 existing tests green |
| `ReplenishmentHeldShareIT` | 3/3 red. IT-1 and IT-2 show `26` (the live DEV value); IT-3 shows 1 SWITCHED row (positive control: the same-row route is reached) |

The §8.1 pins are not edited yet. That happens in the Fix A commit.

IT-1 seeds the result of the admin absolute set (18/1 with requested 9) by SQL, because the admin set is the precondition, not the code under test. IT-3 sets its shortage through the FLA upper bound. Destination stock would itself be a redirect candidate.


**Implementation, 2026-10-01.** Branch `bugfix/SBDEV-3618-recalc-held-share`, base `652f37f7`.

| Commit | What |
|---|---|
| `6d8c78aa` | TDD gate |
| `3d0cf1e7` | Fixes A–E, the §8.1 pin changes, the NeverMatcher inventory, and the OptionalSafety store. ⚠ This is ONE commit for Fixes B–E. That deviates from §5 step 4: the fixes share `Share` and `shareOf`, and each depends on the previous one's signature change. |
| `3839d6d0` | PIT survivors closed: U-5b, U-10c, and U-12's re-point fields and share reuse |
| `930860eb` | U-11b pins Fix D's lock order. The conformance lane's mutant had passed every test before this |
| `084e53ac` | Review round 1: D2⁗ (cap-only on a broken invariant), M-3 logging, the security-L2 STRANDED_RESERVATION error, and tests U-9 (restored), U-9b, U-10d, U-14, U-15. U-7 now pins the D2‴ redirect. IT-3 asserts the re-point. Stale comments fixed |

**Tests added beyond §8:**
- **U-5b:** capacity exactly 0 is redirected. Kills `<=` → `<` on `isSourceUsable`.
- **U-10c:** a release landing exactly on `amount` is booked. Kills the step-4 boundary.
- **U-10d:** the release guard compares `reserved − held`, not `reserved`.
- **U-10e:** a release landing exactly on `amount` (the `>` vs `>=` boundary).
- **U-16 / U-16b:** ≥2 over-granted orders, left as is; and the broken-invariant cap at free stock.
- **U-11b:** lock the moved SU, then read its share, then lock the target. Kills the conformance lane's unlocked-share mutant.
- **U-13:** fully-held growth. Green by design.
- **U-14:** an under-reserved order with `res > amount` shrinks to `amount`. Kills the reviewer's `held` without `min(capacity)` mutant.
- **U-15:** an open pick reduces `held`. Kills the reviewer's picks → 0 mutant, checked by hand.

**PIT:** 60 changed-line mutants killed. The 7 survivors are all equivalent: four on the INFO-log condition, two at the `delta == 0` boundaries, and `Share.NONE` → null, which is never read.

**Full suite** (at `3d0cf1e7`): surefire 7622/0/0/1 against a baseline of 7572/0/0/1; failsafe 584 with 1 F / 2 E against a baseline of 581 with 1 F / 2 E. The same three classes fail in both: `CancellationReversalParcelSourceIntegrationTest` ×2 and `SequenceTransactionServiceConcurrencyIT`.

**Review lanes:**
- Conformance (opus): FAIL on one gap, untested Fix D, which U-11b closed.
- Code review (opus): APPROVE with 0 High, 3 Medium (1 DESIGN, which became D2⁗) and 10 Low.
- Security: PASS with 2 Low.
- Everything was fixed in the review-fix commit. L-6, the commit split, is recorded above rather than re-split.
| `80d73bad` | Re-review (APPROVE, 0 High; M-A DESIGN kept as "waits for admin" by Nam), all Lows applied: U-10e is the true release boundary (U-10d relabelled); U-16/U-16b pin D2⁗'s two-order freeze and its free-stock cap; U-7/U-5b make the mocked reserve take effect and assert post-redirect sizing; the WARN is reworded and an UNATTRIBUTED_RESERVATION WARN added; the reconciliation claim and the `bound()` javadoc are corrected |

| `0402208a`, `95f032bb` | Final scoped-review Lows: the WARN logs the real outcome, UNATTRIBUTED only when the SU carries a reservation, the post-redirect growth bookings are verified, and U-16 has a symmetric side. Reviewed SHA = tip `95f032bb` |

**Final full suite (tip `95f032bb`):**
- Surefire: 7633 run / 0 F / 0 E / 1 skip.
- Failsafe: 584 run / 1 F / 3 E / 31 skip.
  - Three of these are the baseline set: `CancellationReversalParcelSourceIntegrationTest` ×2 and `SequenceTransactionServiceConcurrencyIT`.
  - The 4th is `MobileTruckLoadingRaceIT` (`unitload_pkey` id 9805, while its fixture seeds a pallet). This is an order-dependent id collision with a fixed-id row from another IT or script. It is not in this diff: it passes 3/3 alone, and it passed in the three earlier full runs. It is proposed as a sub-T3 fixture fix.
- One earlier run (`0402208a`) was stopped by the harness for low memory.

**PR:** https://github.com/SiteBossInc/wms2-api/pull/439. Five inline review notes cover the cut rule, D2⁗, D2‴, the Fix D upgrade and the equivalent mutants. ClickUp → `pr submitted`.

**Merged 2026-10-01.**
- PR #439 → `develop` merge commit `1c51d790`. CI `test` and `build` passed, and DEV `/api/public/version` reports `develop-1c51d790` (drift false). ClickUp → `on dev`, with ACs 1–3 ticked.
- AC-4, the PRD population before and after, stays open and gates the promotion to PRD.
- **Live convergence is not yet observed.** DEV's recalc sweep has not run since 2026-09-30 22:56 UTC, even though the timer sysprops are on. That is a pre-existing gate, not this change. Expected on the next recalc: REPL389503 at 18/18 (corrected from an earlier "1/1").

**Live DEV test, 2026-10-01 05:24–05:26 UTC (`panderson`, `develop-1c51d790`).**
- The trigger was `setUpperBound` on FLA 21552864, re-set to its existing 84. That runs `recalculateForItem` for item 20370204, which has 1 open order. `triggerOrderReplenish` was avoided because it would also release the 2,793-order DEV backlog.
- **(1) Convergence:** REPL389503 went 26 → 18, reserved stayed 18, 0 ledger rows.
- **(2) Idempotency:** a second call changed nothing.
- **(3) Respect the cut:** an admin `adjustReservedAmount` to 10, then a recalc. Requested went 18 → 10, reserved stayed 10, and the only new row was the admin's `MANUAL_ADJUSTMENT −8`, with no re-reserve.
- All three matched the predictions. End state: 10 = 10.

**Follow-ups filed 2026-10-01:** SBDEV-3621 (P-1), SBDEV-3622 (P-2), and SBDEV-3623 (the `MobileTruckLoadingRaceIT` fixture-id flake).

**AC-4 PRD baseline, "before" (2026-10-01 11:03 UTC, pre-#439 code on PRD):**

| Tenant | Open (300) | req > amount | Would shrink (units) | Under-reserved | Shared | Broken | Multi |
|---|---|---|---|---|---|---|---|
| WineCo | 554 | 14 | 14 (171) | 20 | 0 | 0 | 0 |
| ShipItEZ LA | 99 | 5 | 5 (106) | 6 | 0 | 0 | 0 |
| Hydra | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| ShipItEZ NY | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

The PRD sweep is live: `LAST_RUN` was 11:03:20 on all four tenants. The "after" half is due after the PRD promotion.

**DEV sweep suppression (pre-existing, found 2026-10-01):** 3 unfulfillable FLAs in `generateReplenishmentForItemDataWithFixedAssignmentWithOrders` keep `affectedItemIds` non-empty, so `recalculateOpenOrders` never runs on DEV. The last run was 09-30 22:56. It is latent on PRD. **Filed 2026-10-01 as SBDEV-3624.**
