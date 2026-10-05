# SBDEV-3605 — Architect review, round 1 (2026-09-30)

Checked against origin/develop daf64d41, plus 2 DEV wineco probes.

**Verdict:** SOUND-WITH-CHANGES.

## Antithesis, tension, synthesis

**Antithesis.** Release on requested (`min(req, res)` under the lock) and let the SBDEV-2610 reconcile clean up. Once X reaches 700, any own-leak remainder is holder-less, and `countStrandedReservationById` zeroes it. So the leak is stranded until the next admin reconcile, not forever.

**Tension.** The chosen design breaks its own Principle 1. It releases a MANUAL_ADJUSTMENT reservation and books it as one `CODE_REPLENISHMENT_FINISHED` row under X's number, for more than X ever requested. Fix D exists to make the ledger attributable, and Fix B then writes a misattributed row.

**Synthesis.** Write two rows:

- `FINISHED −min(X.req, ownShare)` under X's number;
- the remainder (`ownShare − X.req`, when > 0) under a distinct code.

The credit is still the total release, so D2 holds.

## Findings

- **H1. U-4 contradicts the code.** `verify(never()).findById(orderId)` cannot pass, because the same transaction calls `findById(mOrder.getId())` again: `finishReplenishmentOrderWithoutRefill` → `readReplenishOrder`, with `mOrder.setId(order.getId())`.
  - The 18 test stubs must gain a `findByIdForUpdate` stub alongside `findById`. Moving them from one to the other breaks the later read.
  - Fix: assert with `InOrder` that the lock comes before any `findById`.
- **H2 (Medium-High). The `max(0)` mutant is masked on the release path.** The apply guard `ownShare.signum() > 0` hides it.
  - The mutant's only live effect is on the Fix C credit.
  - Fix: add a same-SU case (amount 10, res 2, Y req 3, qty 8: accept vs reject), or drop the guard.
- **M1. The §7 #4 "no cycle vs web redirect" claim is false for different orders.**
  - redirect Z holds B and waits for A; multi-UL X holds A (the old SU, which is out of ascending order) and waits for B, a scanned SU.
  - F3's check runs after both locks, so it does not prevent the wait.
  - It is bounded by 40P01 or lock_timeout.
  - Recommend locking {old ∪ scanned} as one ascending set, after resolving the SU ids via a projection.
- **M2. Fix E adds a new order-after-SU ABBA.**
  - Processed one order at a time, the moved-SU path holds {o1, T1, M} and then asks for o2. A multi-UL on o2 holds o2 and asks for M.
  - Fix: two phases. Lock every id ascending, check STARTED on all of them, and only then write. U-B1 already implies this.
  - As written this is T3 scope. Either keep S5/S6 with the two-phase lock and an IT, or split them off.
- **M3. Bug 3 overstates today's harm.** On develop, the stale `findById(X)` fails `@Version` at the A.2 flush, so the path is already fail-closed with a 409.
  - Fix A is liveness plus the state guard. It also removes a real ABBA on develop: multi-UL takes SU A and then X's row lock at the flush, while the cron takes the order and then the SU.
  - The IT-7 mutant description is wrong: the mutant waits on SU A and then 409s. It is still killed via the `awaitOrderLockWait` filter.
- **M4. R4 and §7 #10 say "500"; they are 409.** `RestExceptionHandler` maps `ObjectOptimisticLockingFailureException` and `PessimisticLockingFailureException` to `HttpStatus.CONFLICT`, `retryable: true`. The handheld handles only a 200 `{errors}`.
- **L1. Fix A's message.** Keep `REPLENISH_ALREADY_FINISHED` for state ≥ 700.
  - DEV states: 300 = 565, 700 = 170, 800 = 388,356.
  - `startOrder` has 0 callers, so the guard rejects only 700 and 800 today.
- **L2. Fix D breaks four pins:**
  - `ReplenishmentOrderMaintenanceServiceReassignTest:206,:309`;
  - `ReplenishmentOrderMaintenanceServiceUnitTest:628,:736` (`eq(CODE_REPLENISHMENT_CANCELLED), isNull(), isNull()`).
  - No src consumer relies on NULL. Grep the 3561 §5.1 #0 classifier SQL.
  - Sibling: `cancelOrder` ignores its `activityCode`. Thread it through, or delete the parameter.
- **L3. Fix E test references.** 25 references need migrating (Reassign 9, SourceSync 11+3, ReplenishorderService 2).
- **L4. The pick term** loads `PickingorderPosition` entities: DEV max 52 per SU, p99 about 50. A scalar `SUM(p.amount) … state < 600` would be cleaner.
- **L5. The manual-test row "web redirect then cron" is infeasible**, because F3 refuses a target with reserved ≠ 0. Use the cron candidate path.

## Verified OK

- The Fix A lock is the first touch of the order in the transaction.
- `state < PICKED` matches customer-order cancel and SBDEV-2610's `< 600`.
- Replenishment orders are created only at PROCESSABLE.
- No children exist when the sum is computed.
- The credit is at most `amount − others − picks`, so the SU cannot be over-booked.
- The early lock changes error precedence only under contention.
- Pick confirm and ReleaseOrderJobService keep their existing lock shapes.
- The `others` read runs after the SU lock.

## Principles

- P1 is violated by D3; the synthesis fixes it.
- P3 is violated by Fix E's loop (M2).
- P4 holds.
- P5 is arguable (L4).
