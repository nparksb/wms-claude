---
ticket: SBDEV-4031
lane: analysis (executor/opus, T3 bug-fix plan pre-draft)
date: 2026-11-06
code_ref: origin/develop @ 05f962b3 (6111d090 ancestor; 6111d090..05f962b3 touches only ClublineOmsChunkSizeDescriptionMigrationTest, nothing in src/main)
prd_code_at_incident: origin/main first-parent at 2026-09-29T17:27Z = 085b2bde (v2.0.147). Deploy lag not verified.
note: The lane's Write was refused by the harness, so the main session saved this file verbatim from the lane's reply. Not reviewed yet.
---

# SBDEV-4031: FLA delete vs replenishment creators. Analysis bundle

All code quotes are from `origin/develop`. Data is from `wsl-wineco-prd` (read-only) and `wms2-wineco-dev` (SELECT only).

## Corrections to the brief

1. **lock_timeout is 3000 ms, not 5 s.** `application.properties` sets `wms.tenant.lock-timeout-ms=3000` (SBDEV-3398 lowered it from 10000). deadlock_timeout is 1000 ms, so a real ABBA reaches the deadlock detector (40P01) before the lock timeout (55P03).
2. **The lock-order hypothesis holds on one path and fails on the other.**
   - It holds for per-order transactions (`recalculateOpenOrders` → `self.recalculateOrder`).
   - It fails for `recalculateForItem`, because that method's shared transaction keeps the locks of orders it already processed (§3, ABBA-3/4).
   - Fix: take the FLA lock before any order lock on both recalc entry points.
3. **The PRD orphan is Race 1, not Race 2.** REPL062709 has `version 0` and `created == modified`, so its destination was written by the INSERT. `alignDestination` writes with an UPDATE, which would have bumped the version.
4. **One in-scope site was missing from the brief.** `ReplenishorderService.recalculateReplenishmentOrderWithoutFixedLocationAssignment` (cron) does the same write as Race 2. It takes no lock on the order and does not check `active`.
5. **A rail will go red.** `FunctionGuardArchTest.fixLocationAssignmentRepository_shouldStillExportItsSiblingSearches` pins the set of `exported=false` methods on `FixLocationAssignmentRepository` with `containsExactlyInAnyOrder(...)`. Every new lock finder carrying `@RestResource(exported = false)` must be added to that list. SBDEV-3128 did the same for its five methods.
6. **A javadoc claim must be retired.** `ReplenishmentOrderMaintenanceService.RecalcContext` says: *"FixLocationAssignment, Unitload and Location may stay managed at READ: nothing on the recalculateOrder path locks any of them, so no upgrade — and hence no checkVersion — can occur."* The fix breaks this. It is also why the recalc-side FLA lock must be **scalar** (§3 note U).

## §0 Affected sites

How the lane enumerated them:
- `git grep -n -E '\.(calculateOrder|calculateAutomaticOrder|createOrderFromTemplate|refillSingleFixedLocation|refillFixedLocations|setDestinationId)\(' origin/develop -- src/main`
- `git grep -n -E 'fixLocationAssignmentRepository\.(delete|deleteById|deleteAll)|fixLocationAssignmentService\.delete|DELETE FROM fix_location_assignment'`
- `git grep -i -E 'update +replenishorder'`. This found only two `prio` bulk updates. No query writes `destination_id`.

Blind spots: reflective or SpEL callers, and raw JDBC.

| # | Site | Construct | Same cause? | In scope? |
|---|---|---|---|---|
| D1 | `FixLocationAssignmentService.deleteByUser` · `fixLocationAssignmentRepository.findById(fixedLocationAssignmentId)` | Plain FLA read, then `checkRemovable`, then holder projection, then `findByIdForUpdate` per order, then cancel, then `deleteById` | yes | **IN.** The FLA lock must be the first statement, with every check after it. |
| D2 | `delete(Long)` · `if (!replenishorderService.getActive(fla.getItemdataId(), null).isEmpty())` | `getActive` is a plain `readOnly` read. **It locks nothing.** | yes | **IN.** Lock the FLA first. The caller `ReplenishOrderJobService.deleteEmptyFixAssignmentWithoutStockToReplenish` reads the FLA with `findById` earlier in the same transaction. An entity lock inside `delete(Long)` would therefore be a version-checked upgrade (SBDEV-3244). Drop the caller's read; it is only used for logging. |
| D3 | `ReplenishOrderJob` delete sub-op · `catch (OptimisticLockException \| OptimisticLockingFailureException e)` | catch clause | consequence | **IN.** The new lock can throw `PessimisticLockingFailureException`. That escapes this catch and `drainPageZero` and hits the per-tenant outer catch, which **aborts the rest of that tenant's replenish run**. Add it to the catch, as `:695` and `:720` already do. Same for `:813`. |
| C0 | `ReplenishGeneratorService.calculateOrder(…, boolean automatic)` | The REQUIRES_NEW transaction that does the INSERT | the choke point | **IN.** Best single fix site for the creator side. |
| C1 | `refillSingleFixedLocation` · `findById(flaId)` … `self.calculateAutomaticOrder(ass.getItemdataId(), required, ass.getAssignedlocationId())` | REQUIRES_NEW outer, REQUIRES_NEW inner | **Race 1** | IN, covered by the C0 fix |
| C2 | `refillFixedLocations` (non-transactional loop) | same call as C1 | yes | IN via C0. Probably dead code (§8 F2). |
| C3 | `ReplenishOrderJobService.generateReplenishmentForItemDataWithFixedAssignment` · `calculateAutomaticOrder(flaItemData.getId(), required, assignedLocation.getId())` | REQUIRES_NEW, plain FLA read | yes | IN via C0 |
| C4 | `generateReplenishmentForItemDataWithoutFixedAssignment` · `calculateAutomaticOrder(itemDataId, amount, null)` | creates orders with no destination | no | OUT |
| C5 / C6 | `ReplenishorderService.create` (admin); `MobileReplenishService.requestReplenish` | operator chooses the destination; **no FLA validation** | different defect: creators that ignore the FLA | **DECISION (Q2)** |
| C7 | `createOrderFromTemplate` | REQUIRED; each child is finished (state 700) and flushed in the same transaction | no | OUT. No child order stays open at commit. |
| C8 | SBDEV-3636 "post-finish refill" | — | — | **Not live on develop.** SBDEV-3678 removed the post-confirm refill. The only `calculateAutomaticOrder` callers are C1–C4. |
| R1 | `alignDestination` · `order.setDestinationId(assignment.getAssignedlocationId()); replenishorderRepository.save(order);` | order is locked; the FLA comes from `RecalcContext`, read before the lock | **Race 2** | IN |
| R2 | `recalculateForItem` | one shared transaction across all of the item's orders, ascending by id | where the ABBA lives | IN |
| R3 | `ReplenishorderService.recalculateReplenishmentOrderWithoutFixedLocationAssignment` · `replenishOrder.setDestinationId(assignedLocation.get().getId())` | no lock on the order, plain `findByItemdataId`, **ignores `active`** | Race 2 twin | IN, or delete it (Q3) |
| M1 | `move` · `fixedLocationAssignment.setAssignedlocationId(destination.getId())` | plain FLA read | yes: changes where the FLA is while orders point at it | IN for the lock. Separately it leaves stale orders (§8 F1). |
| A1 | `changeActive` | plain read, toggle, save | partial | OUT. `resolveActiveAssignment` skips inactive FLAs, but the mobile checks ignore `active`. An order to a deactivated FLA's location can still be delivered. |
| A2 | bound adjust / reset / defaults edit | bounds only, version-checked | no | OUT. Stale bounds self-heal through the post-commit trigger. |
| A3 | `createFixedLocationAssignment` | locks the location row, then inserts | no | OUT. The create's own trigger realigns the order after commit. The unique index on `itemdata_id` serializes duplicate creates. |
| V1 | `assignDestinationForMultiUnitLoads` | plain FLA reads while holding the template order lock | reads only | OUT. It must **not** take the FLA lock (ABBA-5). |

PRD unique indexes on `fix_location_assignment`: `itemdata_id`, `assignedlocation_id`, `assignedunitload_id`. So each item has at most one FLA and each location at most one.

## §1 Root cause

**Race 1.** `refillSingleFixedLocation` reads the FLA with a plain `findById`. It then calls `self.calculateAutomaticOrder`, which inserts in its own REQUIRES_NEW transaction. `calculateOrder` never reads the FLA again; its idempotency check (`findBlockingPendingOrder`) only looks at orders.

On the other side, `delete(Long)` checks `getActive` (plain read) and then calls `applyRemoval` → `deleteById`. Under READ COMMITTED this is write skew:
- the delete's `getActive` runs before the creator's insert commits;
- the creator's FLA read runs before the delete commits;
- no row is shared, so both commit.

`deleteByUser` has the same skew. Its holder projection runs before any lock, and the orders it would lock do not exist yet in committed state.

**Race 2.** `recalculateOrder` locks the order (`findByIdForUpdate`), then calls `resolveActiveAssignment(item, ctx)`. `ctx` is a plain `findByItemdataIdIn` built before the loop. `alignDestination` then saves that ctx location. If the FLA is deleted or moved between building the context and the save, the order gets a stale destination. R3 does the same write with no lock at all.

## §2 Supporting facts

- **The cron is serial per tenant.** `ReplenishOrderJob` holds `advisoryLockService.tryLock(REPLENISH_ORDER, tenantId)`, and its delete sub-op runs before its creators in the same thread. So the cron never races itself. The real pairings are:
  - user `deleteByUser` (HTTP) vs cron creators C1/C3;
  - cron `delete(Long)` vs HTTP and mobile writers.
- **The cron delete is off on PRD:** `los_sysprop FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY='false'`.
- **The inner REQUIRES_NEW transaction never touches the FLA row.** The lane read the full body of `calculateOrder(…automatic)`. It reads itemdata, orders, stock units, unit loads and locations, generates a number, saves and flushes the order, and calls `changeReservedAmount` (which locks the source SU).
  - So a lock taken in the outer transaction cannot self-deadlock against the inner one.
  - The C0 design locks inside the inner transaction anyway, which removes the question.
- **Cancel locks only order then SU.** `cancelReplenishmentOrder` → SU `findByIdForUpdate` → `HeldShareRelease` (sum projections only) → `changeReservedAmount` (same SU) → `markCancelled`. It locks no other order.
- **The maintenance trigger holds no producer locks.** It runs in `afterCompletion(STATUS_COMMITTED)`, after the producer's locks are released.
- **No code sets a destination back to null.** The 7 `setDestinationId(` sites never pass a literal null. A destination only goes from null to non-null.
- **HTTP mapping.** `FixLocationAssignmentController` lives in `net.aim_ai.wms.controller`, not `.rest`. `RestExceptionHandler` therefore maps `PessimisticLockingFailureException` to **409 "Resource Locked"** with `retryable: true`.
- **A stale `checkRemovable` is fenced by `@Version`, by accident.** If a confirm adds stock to the FLA's stock unit after the check:
  - `sendStockUnitToNirvana` is given the stale stock unit (amount 0), so it skips `changeAmount`;
  - it then saves the stale entity, and the version check fails;
  - result: 409, and no stock goes to Nirvana.

## §3 Lock-order matrix

Notation: F = FLA row for item I at location L. `ord(L)` = I's open orders to L. `ord(∅)` = I's orders with no destination.

| Path | Today | Proposed |
|---|---|---|
| `delete(Long)` | no order locks; SU and UL versioned writes; FLA DELETE | **F** → SU/UL → DELETE |
| `deleteByUser` | ord(L) ascending → source SU per cancel → SU/UL → DELETE | **F** → ord(L) ascending → source SU → … |
| cancel by id | order → SU | unchanged |
| C0, automatic with a destination | unique-index slot → SU | **F (scalar, by item + location)** → slot → SU |
| C5/C6 | slot → SU | unchanged (Q2) |
| `recalculateOrder`, per-order transaction | order → SU (→ target via SKIP LOCKED) | **F (scalar) if the projection says dest is null** → order → SU |
| `recalculateForItem`, shared transaction | ord₁ → SU₁ → ord₂ … ascending | **F (scalar) first, if any PROCESSABLE ord(∅) exists** → orders |
| R3 | plain reads; order UPDATE at flush | per order: F (scalar) → re-read → UPDATE |
| `move` | destination location (`transferUnitLoadToLocation` with `ignoreLock=false`, then `lockById`, re-entrant) → FLA UPDATE | **F (entity, first touch)** → location → … |
| multi-UL confirm | template → plain FLA reads (FLA create takes the location lock) → SUs ascending → destination location | unchanged; **no FLA lock** |

**ABBA analysis**

- **ABBA-1. `deleteByUser` vs per-order `recalculateOrder` taking F *after* the order (the brief's hypothesis). No cycle, so the hypothesis is proved for this path.**
  - Recalc holds order O (dest ∅) and waits for F.
  - O cannot be in `ord(L)`. Its committed destination is ∅, and nothing can change that while recalc holds O's row lock.
  - Recalc holds no SU yet, because it aligns before `ensureValidSource`.
- **ABBA-2. `delete(Long)` vs anything that locks orders. No cycle:** `delete(Long)` locks no order.
- **ABBA-3. `deleteByUser` vs `recalculateForItem` with F taken after the order. The cycle exists.**
  - Recalc locks B (dest L, lower id), then reaches O₂ (dest ∅, higher id) and waits for F.
  - Delete holds F and waits for B.
  - **The hypothesis is refuted for `recalculateForItem`.** The partial unique indexes allow one open order to L and one with no destination per item, so this is reachable in principle.
  - PRD census on 2026-11-06: **0** items have both kinds. There are 21 open orders with no destination, none for an item that has an FLA.
  - When it fires, 40P01 is rethrown via `hasSqlCause` and poisons the whole item sweep.
  - **Fix: take F before the first order lock.**
- **ABBA-4.** Same as ABBA-3, but through a shared source SU. Closed by the same fix.
- **ABBA-5. Multi-UL confirm vs `deleteByUser`, *if* confirm took F.** Confirm holds the template order T and would wait for F. Delete holds F and waits for T. Therefore confirm must not lock F. Without that lock there is no cycle: delete waits for T, then sees state 700 and skips.
- **ABBA-6. `move` vs FLA create.** Create inserts a different row, so the only contention is on the index slot. No cycle.
- **ABBA-7. If the Location row were the lock object.** Delete would hold L and wait for T. Confirm holds T and locks the destination location in `transferStockToUnitLoad`. **That is a reachable cycle, so the location row is rejected.**
- **ABBA-8. C0 vs `deleteByUser`.** Both take F first. No cycle.
- **ABBA-9. R3 (many items in one transaction) vs a delete on item 2.** The delete needs neither F₁ nor O₁. No cycle.

**Verdict.** The order FLA → order(s) → SU is sound if three rules hold:
1. Every recalc entry point locks F before its first order.
2. The confirm path never locks F.
3. The lock is scalar wherever the transaction may already hold the FLA entity at READ.

**Note U (upgrade trap).** `buildRecalcContext` loads FLA entities into the persistence context of `recalculateForItem`. An entity `@Lock` finder on the same row would be a version-checked upgrade (the SBDEV-3244 mechanism), and `LockReadRail` flags exactly that. So:
- lock with the `LocationRepository.lockById` shape: `@Lock(PESSIMISTIC_WRITE) @Query("SELECT f.id …")`;
- read the destination afterwards with a scalar JPQL query, not from `ctx`.

## §4 Fix design

**New repository methods.** Each gets `@RestResource(exported=false)` and must be added to the `FunctionGuardArchTest` pin.
- `findByIdForUpdate(id)`: entity lock, used by delete and move as the first touch.
- `lockIdByItemdataIdAndLocation(i, l)`: scalar lock, used by C0.
- `lockIdByItemdataId(i)`: scalar lock, used by the recalc paths.
- `findActiveLocationIdByItemdataId(i)`: scalar read, run after the lock.

Under READ COMMITTED, a `FOR UPDATE` that waited on a row:
- that was **deleted** returns nothing;
- that was **moved** is re-evaluated, so `assignedlocationId = :l` no longer matches and it also returns nothing.

Either way the caller treats the FLA as gone and skips.

**Delete side**
- **D1.** Make `findByIdForUpdate` the first statement in `deleteByUser`. Everything else stays in its current order. The holder projection then runs after the lock and sees any order a creator committed while the delete was waiting.
- **D2.** Same change in `delete(Long)`, and remove the caller's pre-read in `deleteEmptyFixAssignmentWithoutStockToReplenish`.
- **D3.** Add `PessimisticLockingFailureException` to the catches in `ReplenishOrderJob` at `:754` and `:813`.

**Creator side: one change at C0.** In `calculateOrder`, as the first statement:

```java
if (automatic && destinationId != null
        && fixLocationAssignmentRepository.lockIdByItemdataIdAndLocation(itemDataId, destinationId).isEmpty()) {
    return null;   // FLA gone, so skip
}
```

- This covers C1, C2 and C3.
- The lock lives in the transaction that inserts:
  - no self-deadlock risk;
  - no extra pool connections;
  - the lock is held for milliseconds.
- A waiting delete's next statement sees the new order. `delete(Long)` refuses; `deleteByUser` cancels it.
- It is gated on `automatic` because operator creates may target FLA-free destinations by design (SBDEV-2854).
- Rejected: putting the lock in C1/C3's outer transaction. It needs three edits instead of one, and it holds F across a second connection's whole lifetime.

**Recalc side**
- **`recalculateOrder`:**
  1. Before `findByIdForUpdate`, read a scalar projection of the order: item id and whether the destination is null.
  2. If the destination is null, call `lockIdByItemdataId`.
  3. Lock the order as today.
  4. In `alignDestination`, take the location from `findActiveLocationIdByItemdataId`, not from `ctx`.
- **`recalculateForItem`:** before the loop, if any of the item's PROCESSABLE orders has no destination, call `lockIdByItemdataId`. The per-order lock taken later is then re-entrant.
- Update the `RecalcContext` javadoc.
- **R3:** lock, re-read with the `active` filter, then save. Or delete it (Q3).
- **M1:** make `findByIdForUpdate` the first statement in `move`.

**Alternatives rejected**

| Alternative | Why rejected |
|---|---|
| Lock the Location row | Creates the ABBA-7 cycle with confirm, and the row is hot (every put, move and confirm). The FLA row has zero existing lock edges. |
| Advisory lock per item | It works, but advisory locks here are job-scoped, and the lock is invisible to the `pg_blocking_pids` probes and `LockReadRail`. Keep it in reserve if Q2 widens the scope. |
| Re-check the FLA after the insert, with no lock | The write skew survives. |
| DB trigger or constraint | Contradicts SBDEV-2854 FLA-free destinations. |
| SERIALIZABLE isolation | The cron's catches are not built to retry on 40001. |
| Do nothing | Not a fix. Kept as a detector idea (§8 F3). |

## §5 Acceptance-criteria candidates

**Harness to start from**
- `ReplenishDupConcurrencySliceIT`: `@MockitoSpyBean` on a repository, with `doAnswer` that calls the real bean and then waits on a latch. Spy only repositories; that file documents why `@MockitoSpyBean` on a CGLIB `@Transactional` service breaks.
- Seed data: `FixLocationAssignmentDeleteByUserIT`.
- Proving "blocked by our holder": `common/fixtures/HeldRowLockRace` and `BlockedBackendReads` (`holderPid = ANY(pg_blocking_pids(pid))`). Do not use a bare `wait_event_type` probe; the Testcontainers DB is shared.

**Candidates**

- **AC-1 (Race 1, user delete).**
  - Setup: thread A runs `refillSingleFixedLocation`, parked inside C0 by a spy on `findByStateLessThanAndItemdataId`. Thread B runs `deleteByUser`.
  - Pre-fix: an orphan order exists.
  - Post-fix: B blocks on F. Then B either cancels the order and deletes the FLA, or refuses with `OPEN_REPLENISHMENT_MSG`. No orphan remains.
  - Mutations that should turn it red: remove the C0 lock; move D1's lock after the checks.
- **AC-2 (reversed).** B holds F, and A is observed blocked. Post-fix: A's lock query returns empty, A returns null, 0 orders.
- **AC-3 (cron delete).** As AC-1, with the cron delete path. Post-fix: the delete refuses and the order is kept. Restoring the caller's pre-read should show the stale-version throw, with no `UnexpectedRollbackException`.
- **AC-4 (Race 2).** A null-destination PROCESSABLE order plus F. Thread A runs `recalculateForItem`, parked after `findByItemdataIdIn`. Thread B runs `deleteByUser`. Post-fix: the destination stays null. Mutation: read the destination from `ctx`.
- **AC-5 (no ABBA).** Seed B (dest L, lower id) and O (no destination, higher id). Thread A runs `recalculateForItem`, parked after locking B's SU. Thread B runs `deleteByUser`. Both must finish with no 40P01 or 55P03. Mutation: lock F after the order (the original hypothesis) gives a deadlock, so red.
- **AC-6 (move).** The refill is parked in C0 before the lock; `move` commits. Post-fix: the lock query returns empty and the refill skips. Mutation: lock by id only.
- **AC-7 (cron catch).** The delete sub-op throws `PessimisticLockingFailureException`. The run must continue.
- **AC-8 (rail).** The `FunctionGuardArchTest` pin is updated.
- **AC-9 (HTTP).** F is held past 3 s, then the delete endpoint returns 409 "Resource Locked".

Before the fix, AC-1/3/4 must go red on the orphan assertion, not on a timeout. Time-box the pre-fix "B returns" branch so the harness can tell "blocked" from "slow".

## §6 Orphan verdict

**PRD REPL062709 (id 35616403) is Race 1: the user's `delete(Long)` against a cron creator. Confidence: high.** Item PN2021SCA (624617214), location 53-C01 (3223192).

| UTC 2026-09-29 | Event | Who |
|---|---|---|
| 17:26:13 | cancel REPL061829 | adriantorres |
| 17:26:23 | create REPL062707 | cron (`anonymous`) |
| 17:26:39 | MANUAL_SPLIT −10 at 53-C01, stock now 0 | adriantorres |
| 17:27:17.323 | cancel REPL062707 | adriantorres |
| **17:27:24.219** | REPL062709 INSERT with dest 53-C01 (`version 0`, `created == modified`) | cron |
| 17:27:24.228 | 12 reserved on SU 21813425 | cron |
| 17:39:26 | 21WH put away at 53-C01; FLA 35616696 created for item 34985890 | adriantorres |

Why this conclusion:
- The INSERT wrote the destination, so it is not Race 2.
- The cron delete was off, and the only other deleter in `085b2bde` is the controller, so the user deleted the FLA.
- `delete(Long)` refuses on any open order for the item, and REPL062709 is still open. So the delete's check ran in a window of about 7 seconds, between 17:27:17 and roughly 17:27:24.23.
- The same cancel → cron-recreates loop appears for PN2021IND at 53-C03.
- **Remaining uncertainty:** no stockrecord marks the delete itself, so its exact time is bounded but not observed.

**Current harm.**
- SU 21813425 at 01-YB04 has been 12/12 reserved for more than 5 weeks.
- A confirm to 53-C01 gets **"53-C01 has different fixed assignment"**. 53-C01 now holds another item's FLA.
- "is wrong location!" does not fire, because the item has no FLA at all.
- If the destination had no FLA and were an empty flowbin, confirm would quietly **re-create** the FLA, undoing the user's delete.

**Recommendation:** a supervisor cancel from the web Replenishment screen, which releases the 12 units. This needs Nam's or ops' yes; nobody has done it.

**DEV REPL050528 and REPL389407 are not delete orphans. Confidence: medium.**
- Both items still have an FLA, at a different location, created in 2024 and 2023, well before the orders (2025-04 and 2025-12).
- 63793 holds another item's FLA, created 2024-08, also before its order. 63795 has no FLA.
- Cause: either an FLA move (§8 F1) or an operator create that ignores the FLA (C5/C6). There is no history to tell which.
- PRD census for this shape: 0 rows.

## §7 Open questions for Nam

1. **Q1.** Should `move`'s stale PROCESSABLE orders (§8 F1) be fixed in this ticket, or proposed separately? It is the same rule (an open order's destination must hold its item's FLA), but it is deterministic, not a race.
2. **Q2.** What to do about operator creates (C5/C6) that target another item's FLA location?
   - (a) leave them out of scope;
   - (b) refuse at create time — the lane recommends this, as a separate T1 proposal;
   - (c) also lock.
3. **Q3.** Should R3 be lock-fixed or deleted? `alignDestination` already does its job, but R3 also covers orders at state ≤ 300 and manually-prioritised orders, which the recalc paths skip.
4. **Q4.** Cancel REPL062709 on PRD: yes or no?

## §8 Findings outside the race

| ID | Finding | Tier | Impact |
|---|---|---|---|
| F1 | `move` refuses only when an order is past PROCESSABLE (`> PROCESSABLE`). PROCESSABLE orders keep the old destination, `alignDestination` only fills null destinations, and confirm then refuses with "wrong location!". | T2 (Q1) | Orders stuck with their reservations held. DEV shows 2 rows of this shape. |
| F2 | `refillFixedLocations` has no caller left after SBDEV-3678. The FLA repository javadoc still cites `MobileReplenishService:720` and `:1128`, which is stale. | T0 | Misleads readers |
| F3 | No detector exists for "open order whose destination holds no FLA for its item". The census SQL in §6 could become a cron WARN metric. | proposal, T1 | Observability |
| F4 | `deleteByUser`'s pre-lock `checkRemovable` is protected only by `@Version`. Record that the checks must run after the FLA lock. | note | — |
| F5 | §8.5 of the transaction boundary map and the ticket still say lock_timeout is 5 s. It is 3000 ms. | T0 doc | Docs only |

## Reading done
- Transaction boundary map §8.5.
- SBDEV-3637 plan.
- **No SBDEV-2622 plan exists in sbdocs**; its contract is the `deleteByUser` javadoc.
- SBDEV-3244 plan, archived at `4-Archieves/wms2/plan/SBDEV-3244-concurrent-recalculate-stale-version-under-lock.md`.
