I could not write the analysis file. The harness blocks subagents from writing report files ("Subagents should return findings as text, not write report files"), so I did not work around it, and I removed the empty `SBDEV-3605-evidence/` directory. The full bundle is below; save it to `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3605-evidence/analysis.md` if you want it on disk. I read code from origin/develop only, at `daf64d41`, in a detached worktree that I have since removed. DB figures come from DEV WineCo on 2026-09-30.

## Verdicts in brief
- **Q1:** Picking reservations can be summed per SU from `pickingorder_position` (`pickfromstockunit_id`, `amount`, open when `state < 600`). The repo already uses that exact predicate. Manual reservations have no holder record at all. Picking and replenishment reservations can sit on one SU by code, but DEV has 0 today.
- **Q2:** The invariant holds on 430 SUs, 1,753 hold more than it explains, and 55 hold less. **No DEV SU has two open replenishment orders**, so the conditions for the ticket's bug exist nowhere on DEV right now.
- **Q3:** Recommend the invariant-based release. It needs **one new repository sum**, which trips escalation trigger #2.
- **Q4:** `fulfillMultipleUnitLoadsTx` locks nothing itself. Proposed order: template order first, then a state check, then SUs in ascending id.
- **Q6:** The self-source credit has to use the same helper as the release. That **reverses an existing unit test (AC-5 in plan 260709) and a workflow-doc rule**, which needs Nam's explicit yes.
- **Q8:** The own-leak writer is commit `c64948ab` (2025-12-05). It is not live in that form on origin/develop, but the NULL-ordernumber release it introduced still is.

## Q1 — Non-replenishment reservations
- **How picking reserves:** `ReleaseOrderJobService` calls `createPickingPosition(amt, su, …)` and then `changeReservedAmount(su, amt, false, CODE_CREATE_PICK_POSITION, …)`. In every branch, the amount reserved equals the position's `amount`.
- **How picking releases:** also by the position's own amount.
  - Pick confirm: `changeReservedAmount(stockUnit, pickingPosition.getAmount().negate(), true, CODE_PICKING, …)`.
  - Customer-order cancel: only when `state < PICKED`.
  - Position re-source: `PickingorderPositionService` releases `pickingOrderPosition.getAmount().negate()` from the old SU and reserves on the replacement.
- **Existing predicate:** SBDEV-2610 already defines a live pick hold this way, in `StockunitRepository.findStrandedReservationStockunitIds` and `countStrandedReservationById`: `NOT EXISTS (… pickingorder_position p WHERE p.pickfromstockunit_id = su.id AND p.state < 600)`.
- **Repository surface:** only `PickingorderPositionRepository.findByPickfromstockunitId(Long)`, which returns a list across all states. There is no scalar sum by pick-from SU.
- **Third holder class, manual:** `StockunitService.adjustReservedAmount` sets an absolute value with `reservedAmount.subtract(stockUnit.getReservedamount())`, writes `ordernumber` NULL, and leaves no holder record.
  - DEV example: SU 30685299 got MANUAL_ADJUSTMENT +10, then the cron put SWITCHED +5 for REPL389503 on top.
- **Can one SU carry both a picking and a replenishment reservation?** By code, yes.
  - `validateUnitLoadEntry` has no area filter.
  - The cron's `getAvailableReplenishmentSources` only requires `su.amount > su.reservedamount`.
  - Configuration allows it: DEV has area 51552 "Storage Picking and Replenish (from)" with both `useforpicking` and `useforreplenish` set, but 0 locations.
  - The generator cannot do it, because it requires `su.reservedamount = 0`.
  - Measured on DEV: 0 SUs with both holders. Blind spot: DEV only. The PRD MCP servers failed to connect this session.

## Q2 — Invariant measurement (two instruments)
In scope: 2,238 SUs, meaning `res <> 0`, or an open replenishment order, or an open pick position.

| Class | Holder | SUs | Σ(reserved − replen − picks) |
|---|---|---|---|
| holds | replenishment | 416 | 0 |
| holds | pick | 14 | 0 |
| leak | none (stranded) | 1,658 | +11,961 |
| leak | replenishment (own leak) | 94 | +468 |
| leak | pick | 1 | +4 |
| under | replenishment | 55 | −445 |

- **Second instrument:**
  - The repo's own stranded SQL, run verbatim, returns 1,658, matching the leak/none bucket.
  - There are 565 open orders, and 416 + 94 + 55 = 565 SUs, with 0 open orders that have a NULL `stockunit_id`. So every open order sits on its own SU, and the number of SUs with two open orders is 0.
  - Also measured: 0 NULL reservations, 0 negative reservations, 1 SU with reserved > amount.
- **Positive controls:** 852143738 (REPL389450, requested 12) and 916462814 (REPL389452, requested 12) are both in "holds".
- **Examples:**
  - Own leak: 988285734 (reserved 12, REPL049628 requested 7), 988282819 (12 vs REPL049480 7), 986897866 (11 vs REPL049420 9).
  - Stranded: 988285738 (reserved 2), 988285728 (5), 988285719 (5).
  - Pick leak: 66350 (reserved 112, picks 108).
  - Under: 987376483 (amount 3, reserved 3, REPL049495 requested 9); 985090431 (amount 5, reserved 5, REPL049523 requested 12); 985090423 (amount 2, reserved 2, REPL050103 requested 6). In each, the order asks for more than the SU holds.
- **Has the ticket's bug ever fired on DEV?** Three whole-amount FINISHED releases since 2026-01-01: REPL050660 (−12), REPL049240 (−12) and REPL050443 (−82).
  - Each SU's ledger shows only the releasing order's own rows beforehand. For example, SU 21568079 has +53 and then +29 from REPL050443.
  - So all three were the order cleaning up its own leak, not stripping another order. This matches SBDEV-3561 §1.

## Q3 — Release formula
- **(a) Invariant-based, recommended.** Under the old-SU lock:
  `release = max(0, min(res, res − Σreq(other open replen on SU, excluding the template) − Σamount(open picks on SU)))`
  - IT-M1b case: release 5, so B keeps 3.
  - Own-leak case: release 12.
  - Already broken, e.g. reserved 2 with Y requesting 3: release 0, and nothing is written.
  - Named side effect: manual reservations with no holder get released, which is consistent with the SBDEV-2610 stranded model.
- **(b) Requested-based, rejected.** It strands the order's own leaks.
  - REPL049240 released 12 from SU 916462814, where its requested was 5. The requested-based rule would have left 7 stranded.
  - Stranded, the SU becomes invisible to the generator. In reality it was reused the same second by REPL389452 (+12).
  - Live analogue: REPL049628 would strand 5.
- **(c) What to reuse.**
  - `sumRequestedAmountForOpenOrders` is keyed on state equality plus item and destination, not SU, so it cannot be used.
  - The two Optional finders keyed on SU throw when two orders share an SU.
  - `findByStateLessThanAndItemdataId` filtered in Java would return managed entities with a stale `requestedamount`.
  - **So add one scalar JPQL sum by SU** (`state < 700`, excluding the template's id, `@RestResource(exported = false)`). The pick term can reuse `findByPickfromstockunitId`.
  - Side effect: this query auto-flushes the dirty template (from its destination save) earlier than today.

## Q4 — Locking
- **Available primitives:**
  - `ReplenishorderRepository.findByIdForUpdate` and `StockunitRepository.findByIdForUpdate`, both PESSIMISTIC_WRITE.
  - Both entities are `@Version`-ed.
  - `wms.tenant.lock-timeout-ms=3000`, applied per acquisition via `SET LOCAL lock_timeout`.
- **Current `fulfillMultipleUnitLoadsTx`:**
  - The template is read with plain `findById`, and there is no state check before it is modified.
  - SUs are read with plain `findByUnitloadId` and `findById`.
  - The only locks come from `changeReservedAmount`, which runs `findByIdForUpdate` and then `refresh`, but applies the delta the caller already computed. So the whole-amount delta is stale by construction.
  - When the entity is already loaded, the lock is an upgrade that version-checks and throws at the lock read.
- **SBDEV-3561 `redirectSource`:** order first, then state check F1, then SUs in ascending id (D7).
- **Cron:** order first, then current SU, then target SU, which is not ascending. That ABBA risk is already accepted in the code's own comment.
- **Proposed order:**
  1. Lock the template with `findByIdForUpdate` as its first read.
  2. Reject a null state or state > PROCESSABLE.
  3. Lock the old SU before the validation loop, so that is its first read too. A missing SU gets no lock and nothing is released.
  4. Compute the release once and pass it to both the credit and the release.
  5. Lock the new SUs in ascending id. These are upgrades, so a stale row makes them throw instead of proceeding.
- **Deadlocks:** against the web redirect, no cycle, since both take the order first and SUs ascending. Against the cron, a residual of the same class as the accepted one, bounded by Postgres deadlock detection (40P01) or the 3 s lock timeout.

## Q5 — Sibling sweep
I read all 27 `changeReservedAmount(` delta arguments. The sweep finds the known site, `MobileReplenishService.java:1417`, as a positive control.

| Site | What it does | In scope |
|---|---|---|
| `MobileReplenishService.applyExplicitSourceToOrder` | Whole-SU release from an unlocked read | **Yes** (the defect) |
| `ReplenishmentReservationReconciliationService` (`stockUnit.getReservedamount().negate(), true,`) | Admin-only (`POST /v3/admin/reconcile-stranded-reservations`, `IS_SB_ADMIN`), not scheduled, not transactional by design. Zeroes SUs with no holder after re-checking `countStrandedReservationById`; only a narrow race window remains | No, it is meant to zero |
| `StockunitService.adjustReservedAmount` | Deliberate admin absolute set | No |

Every other release uses the holder's own amount (`requestedamount` or the pick position's amount).

Adjacent findings, ranked:
1. `releaseReservation` passes NULL as the order number (`…CANCELLED, null, null`). This is still live, it is what makes the ledger unusable, and it is a one-line fix below T3, so it goes on this ticket.
   - Related: when `changeReservedAmount` clamps a release to zero, it still records the requested delta rather than the real change. That is a second source of ledger drift; propose.
2. `getAvailableIncludingReservation` (`amount − reserved + currentRequest`) over-grants once the invariant is broken, and produces the "under" class. Example: REPL050060 was raised to 13 on a 12-unit SU. Propose.
3. The Optional finders keyed on SU (`findIdByStateLessThanAndStockunitId`, `findByStateLessThanAndStockunitId`) throw once two orders share an SU, which is exactly the state the multi-unit-load path and the cron can create. T2; propose.

## Q6 — Same-SU consistency

| Case | Release (new) | Credit (new) | Credit today |
|---|---|---|---|
| IT-M1b (B reserved 8: X 5, Y 3) | 5 | 5 | 5 |
| Own leak (B reserved 12, X requested 5) | 12 | 12 | 5 |
| Broken (B reserved 2, Y requested 3) | 0 | 0 | 2 |

In the own-leak case, the existing test `fulfillMultipleUnitLoads_shouldRejectUnitLoad_whenSelfSourceAddBackStillBelowRequestedQty` (reserved 12, requested 5, qty 12) flips from reject to accept. It also contradicts line 110 of `wms2-multi-unitload-replenish.md` ("Do NOT 'correct'…"). This needs Nam's yes.

## Q7 — Tests
- **Existing harness:**
  - `src/test/java/net/aim_ai/wms/integration/service/ReplenishorderRedirectSourceIT.java` extends `AbstractReplenishRedirectPgFixture`, which extends `BasePostgresIntegrationTest`.
  - Fixture: SU_A/B/C = 9990–9992, ORDER_X/Y = 9995/9996, `REQUESTED=5`, `SOURCE_AMOUNT=20`.
  - Helpers: `stockunit(…)`, `replen(…)`, `reservationSequence`, `otherOrdersForItem`.
  - Latch helper: `raceRedirectAgainstHeldRecalc` plus `awaitOrderLockWait`, which polls `pg_stat_activity`.
  - IT-M1b is `@Disabled`; the measured result was B reserved 0, FINISHED −8.
  - Also relevant: `MobileReplenishMultiUnitLoadIT`, `MobileReplenishServiceIntegrationTest.fulfillMultipleUnitLoads_success`, and the unit tests in the `FulfillMultipleUnitLoads` and `PartitionAvailabilityGuard` nested classes.
  - The unit test class has 18 calls to `fulfillMultipleUnitLoads*` and 61 `findById` stubs on the order repository; the multi-unit-load ones must move to `findByIdForUpdate`.
- **Run one IT:** on JDK 21, `mvn -Dit.test=ReplenishorderRedirectSourceIT -Dtest=NoSuchTest -Dsurefire.failIfNoSpecifiedTests=false verify`.

Proposed tests, each with the change that must turn it red:

| # | Test | Mutant that must turn it red |
|---|---|---|
| 1 | IT-M1b enabled | Revert to the whole-amount release |
| 2 | Own leak, different SU: B ends at 0, FINISHED −12 | Requested-based release (B stays 7) |
| 3 | Own leak, same SU: amount 12, reserved 12, requested 5, scanned qty 12 is accepted | Old credit rule |
| 4 | Pick reservation survives: B keeps 2 | Drop the pick term |
| 5 | Broken-invariant clamp: B stays 2 and no row is written | Remove `max(0, …)` |
| 6 | Wrapper-level via `fulfillMultipleUnitLoads`: FLA lowerbound ≤ post-transfer amount, Y's `manuallyoverridepriority=true`, only X-numbered rows, Y keeps 3 | Whole-amount release |
| 7 | R10 overlap: T1 = held `redirectSource`, T2 must wait on the order row, then release from B | Template read back to `findById` |
| U-1 to U-6 | Unit tests: formula; low clamp (`never()` with typed matchers); high clamp; template locked and `findById` never called; `InOrder` lock sequence; credit equals release | One mutant per assertion |

## Q8 — Own-leak writer
- **Source:** `git log -S` points to `c64948ab` (Leonardo Castro, 2025-12-05, "feat: Enhance replenishment order management"). It is an ancestor of origin/develop.
- **Mechanism:** in that commit, `recalculateOrder(Replenishorder)` had no transaction and no lock. Each `changeReservedAmount` committed on its own, and `save(order)` was a separate unit. If the order save was lost, the reservation delta stayed committed.
- **DEV evidence:** SU 988285734 has SWITCHED +7 then REPLENISHMENT +5 eight milliseconds later, followed by a one-minute loop of CANCELLED −7 (NULL order number) and SWITCHED +7.
- **Status on origin/develop:** `recalculateOrder(Long, RecalcContext)` is now `@Transactional REQUIRED` and starts with `findByIdForUpdate`, so this writer is not live in that form. The NULL-ordernumber release is still live.
- **DEV, last 45 days:** 8 REPLENISHMENT/SWITCHED rows, none with the Dec-2025 shape, and at most 24 rows a month since June.

## Q9 — Docs the fix makes stale
- `wms2-replenishment-design.md` §7:
  - The transaction boundary is already wrong: it says the whole method is `@Transactional`, but the transaction is on `fulfillMultipleUnitLoadsTx`.
  - Step 1 "Load template order" and step 4 "release any existing reservation" both change.
- `wms2-multi-unitload-replenish.md`:
  - Line 110: the credit rule and the "Do NOT correct" note.
  - Lines 54 and 100: "release it".
- `wms2-stockunit-design.md:389`: add the holder invariant.
- `wms2-transaction-osiv-boundary-map.md`: no multi-unit-load entry (0 hits; the positive control hits at :172). Add the lock order.

## Q10 — Affected sites (from the 27-site grep)
In scope:
1. The `applyExplicitSourceToOrder` release.
2. The `validateUnitLoadEntry` credit, which is coupled to it.
3. The unlocked template read in `fulfillMultipleUnitLoadsTx`, which enables R10.

Out of scope:
- Reconciliation service and `adjustReservedAmount`: same construct, but intended.
- `updateRequestedAmount`: the historic cause, now closed by transaction plus lock.
- The mobile `checkSource` switch, finish, `redirectSource` and cancel, the generator, and all 12 picking sites: holder amounts, different root cause.

Proposed: `releaseReservation` NULL order number (on this ticket), `getAvailableIncludingReservation`, and the Optional-by-SU finders.

## Q11 — Horizontal scalability and v2 constraints
- **Locks:** all inside `tenantTransactionManager` through the `self.` proxy, as DB row locks, so they hold across replicas. No JVM-local lock is relied on for correctness.
- **Lock timeout:** 3 s per acquisition. Worst case is about (N + 2) × 3 s for N scanned unit loads. The IT comment says 10 s, so check the test profile before sizing latch holds.
- **Post-commit refill/recalc:** must stay outside the transaction. The AC-6b rail pins this, and IT-6 exercises it.
- **Cron:** it locks the order first, so the template lock serialises against it. The cron can put two orders on one SU, so read the "others" sum after taking the SU lock.
- **Migrations:** none needed; the index on `stockunit_id` already exists (V2.1.04).