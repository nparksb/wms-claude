---
title: "FLA delete vs replenishment creators: lock the FixLocationAssignment row first, everywhere an order's destination is decided from it"
ticket: "SBDEV-4031"
ticket_url: "https://app.clickup.com/t/868mtjjwt"
type: "bug"
priority: "normal"
status: "planning — pending approval"
tier: T3
project: [wms2]
version: "v2"
repos: [wms2-api]
branch: "bugfix/SBDEV-4031-fla-lock"
db_verified: true
db_verified_note: "wsl-wineco-prd (read-only) 2026-11-06 via the analysis lane: orphan=1 / bound=561 / open=584; REPL062709 timeline. wms2-wineco-dev: 2 non-race rows (REPL050528, REPL389407). The §8.4 manual-test precondition counts were run on dev_wh01_om1 on 2026-11-06: bound orders at state <= 300 = 469; empty flowbins with no FLA = 723; orphans = 2."
base_commit: "wms2-api origin/develop 05f962b3 (SBDEV-2622 6111d090 is an ancestor)"
requester: "Nam Park"
created: "2026-11-06"
updated: "2026-11-06"
related:
  - "[[SBDEV-2622]]"
  - "[[SBDEV-3244]]"
  - "[[SBDEV-3637]]"
tags:
  - plan
---

# SBDEV-4031: lock the FLA row before deciding an order's destination from it

**Ticket:** [SBDEV-4031](https://app.clickup.com/t/868mtjjwt) · **Tier:** T3 (lock topology across delete, create, recalc and move; data-integrity: orphaned orders with held reservations) · **Branch:** `bugfix/SBDEV-4031-fla-lock` · **Evidence:** `SBDEV-4031-evidence/analysis.md` (authoritative; this plan does not re-derive it)

---

## 0. Affected sites

Enumeration method: the three `git grep` sweeps in analysis §0 (callers of the creators and `setDestinationId(`, every FLA delete, every `UPDATE replenishorder`), plus `git grep '\.(calculateAutomaticOrder|calculateOrder)\('` and `git grep '\.recalculateForItem\(|\.recalculateOrder\('` re-run on 05f962b3 for this plan. Blind spots: reflection, SpEL, raw JDBC.

| # | Site | Verdict (with 2026-11-06 decisions) |
|---|---|---|
| D1 | `FixLocationAssignmentService.deleteByUser` | **IN.** FLA entity lock is the first statement |
| D2 | `FixLocationAssignmentService.delete(Long)` + caller `ReplenishOrderJobService.deleteEmptyFixAssignmentWithoutStockToReplenish` | **IN.** Lock first; drop the caller's `findById` pre-read; `propagation = MANDATORY` (P52, Fix B) |
| D3 | `ReplenishOrderJob` catches for the delete sub-op and `generateReplenishmentForItemDataWithFixedAssignmentWithOrders` | **IN.** Add `PessimisticLockingFailureException` |
| C0 | `ReplenishGeneratorService.calculateOrder(…, boolean automatic)` | **IN.** The creator choke point; covers C1 `refillSingleFixedLocation`, C2 `refillFixedLocations`, C3 `generateReplenishmentForItemDataWithFixedAssignment` |
| C4 | `generateReplenishmentForItemDataWithoutFixedAssignment` | OUT: destination null, no FLA involved |
| C5/C6 | `ReplenishorderService.create`, `MobileReplenishService.requestReplenish` | **OUT → P69** (Q2) |
| C7/C8 | `createOrderFromTemplate`; SBDEV-3636 post-finish refill | OUT: children finish in-tx; post-finish refill removed by SBDEV-3678 |
| R1/R2 | `ReplenishmentOrderMaintenanceService.recalculateOrder` / `alignDestination` / `recalculateForItem` | **IN.** FLA scalar lock before the first order lock; destination read post-lock |
| R3 | `ReplenishorderService.recalculateReplenishmentOrderWithoutFixedLocationAssignment` | **IN, lock-fix** (Q3) |
| M1 | `FixLocationAssignmentService.move` | **IN, widened** (Q1): lock first AND re-point PROCESSABLE orders still headed to the old location |
| A1–A3 | `changeActive`, bound edits, `createFixedLocationAssignment` | OUT (analysis §0) |
| V1 | `MobileReplenishService.assignDestinationForMultiUnitLoads` | OUT, **and must never lock the FLA** (ABBA-5). Pinned by ArchUnit (AC-8b) |

---

## 1. Problem

An open replenishment order can point at a location that no longer holds its item's FixLocationAssignment. The order keeps its source reservation and cannot be confirmed:
- confirm to the order's destination fails with *"53-C01 has different fixed assignment"* (another item's FLA moved in) or *"is wrong location!"* (the item's FLA is elsewhere);
- if the destination had no FLA and were an empty flowbin, confirm would silently re-create the FLA, undoing the user's delete.

**DB evidence (wsl-wineco-prd, 2026-11-06, analysis §6):** open orders = 584, bound to their item's FLA = 561, **orphaned = 1**: REPL062709 (id 35616403, item PN2021SCA, dest 53-C01). Timeline (UTC 2026-09-29): 17:27:17.323 user cancels REPL062707 → 17:27:24.219 cron INSERTs REPL062709 with dest 53-C01 (`version 0`, `created == modified`, so the destination came from the INSERT) → 17:27:24.228 cron reserves 12 on SU 21813425 → the user's FLA delete commits inside that ~7 s window. SU 21813425 has been 12/12 reserved for 5+ weeks. Per Q4 the order is left as-is.

DEV (`dev_wh01_om1`): REPL050528, REPL389407 have the same *shape* but predate any delete. They come from an FLA move (F1) or an operator create (C5/C6), not this race.

---

## 2. Root cause

**Race 1 — creator vs delete (the PRD orphan).** `refillSingleFixedLocation` reads the FLA with a plain `findById`, then `self.calculateAutomaticOrder(...)` inserts in a REQUIRES_NEW transaction whose only guard is order-side:

```java
// Idempotency: skip if a pending replenish order already exists for same item + destination
Replenishorder blocking = findBlockingPendingOrder(itemDataId, destinationId).orElse(null);
```

`delete(Long)` guards with a plain read, then deletes:

```java
if (!replenishorderService.getActive(fla.getItemdataId(), null).isEmpty()) {
    throw new BusinessException(OPEN_REPLENISHMENT_MSG);
}
applyRemoval(fla, checkRemovable(fla));
```

The two transactions share no row. Under READ COMMITTED each one's check runs before the other commits, so both commit: classic write skew. `deleteByUser` has the same skew, because its holder projection (`findHoldersByStateLessThanAndItemdataIdAndDestinationIdOrderById`) runs before any lock, and the creator's order is not committed yet.

**Race 2 — recalc vs delete/move.** `recalculateOrder` locks the order, then `resolveActiveAssignment(order.getItemdataId(), ctx)` reads the FLA from `RecalcContext`. That context was built from a plain `findByItemdataIdIn` before the loop. `alignDestination` then writes `order.setDestinationId(assignment.getAssignedlocationId())`. If the FLA is deleted or moved in between, the order gets a stale destination. R3 does the same write with no lock and no `active` check.

**Move staleness (deterministic, F1).** `move` refuses only on `replenishOrder.getState() > WmsConstants.State.PROCESSABLE`. PROCESSABLE orders keep `destination_id = old location`. `alignDestination` only fills **null** destinations (`if (order.getDestinationId() == null)`), so nothing repairs them. The mobile app sends the operator to the old location, and `assignDestinationForMultiUnitLoads` refuses: `currentItemDataOpt.get().getAssignedlocationId().equals(storageLocation.getId())` is false → *"is wrong location!"*. The reservation is held until someone cancels.

---

## 4. Architecture

### 4.1 Lock order (proposed). Rule: **FLA → orders ascending (`findByIdForUpdate`, first touch) → SU → location**

| Path | Today | Proposed |
|---|---|---|
| `delete(Long)` | no order lock; SU/UL versioned writes; DELETE | **F (entity)** → SU/UL → DELETE |
| `deleteByUser` | ord(L) asc → SU per cancel → SU/UL → DELETE | **F (entity)** → ord(L) asc → SU → … |
| C0 automatic, dest ≠ null | slot → SU | **F (scalar, item + location)** → slot → SU |
| `recalculateOrder` (per-order tx) | order → SU | **F (scalar) iff dest-null projection hits** → order → SU |
| `recalculateForItem` (shared tx) | ord₁ → SU₁ → ord₂ … | **F (scalar), unconditionally, before the loop** → orders |
| R3 | plain reads, UPDATE at flush | per order: **F (scalar)** → order (`findByIdForUpdate`) → re-read FLA → UPDATE |
| `move` | location (`transferUnitLoadToLocation`) → FLA UPDATE | **F (entity)** → ord(old L) asc → location → UL/SU → FLA UPDATE |
| multi-UL confirm | T → plain FLA reads → SUs → location | unchanged; **never F** |

### 4.2 ABBA verdicts (compact; full derivations in analysis §3)

| # | Pair | Verdict |
|---|---|---|
| 1 | deleteByUser × per-order recalc | no cycle (both take F first) |
| 3/4 | deleteByUser × recalculateForItem | **cycle today if F were taken after an order**; closed by F-before-loop |
| 5 | multi-UL confirm × deleteByUser | no cycle **only while confirm never locks F**: invariant, pinned by AC-8b |
| 7 | Location row as the lock object | **cycle** with confirm (T → location) → rejected |
| 8 | C0 × deleteByUser / move | F first on both, no cycle |
| 9 | R3 (multi-item tx) × item-scoped paths | no cycle: item paths touch only their own F and orders |
| 10 (new) | move × a concurrent UL move of O's **source** onto the FLA's target L′ | move: F → O → L′; UL move: L′ → SU → holder O. **Theoretical cycle.** Same class as today's confirm (order → location) vs UL move (location → holder order). The deadlock detector resolves it in 1 s and the loser gets 409. Accepted residual: it needs an operator to drop O's source pallet into the empty flowbin chosen as the move target during the same second |

**Monotonicity premise (load-bearing for every pre-lock hint below):** no code sets `destination_id` back to null. Analysis §2 checked all 7 `setDestinationId(` sites; Fix E adds none. So a pre-lock read of "dest is null" can only become stale toward non-null, and the post-lock re-check absorbs that.

### 4.3 Key files

| File | Role |
|---|---|
| `repo/jpa/FixLocationAssignmentRepository.java` | 4 new finders (Fix A) |
| `repo/jpa/ReplenishorderRepository.java` | 2 new scalar finders (Fix A) |
| `service/FixLocationAssignmentService.java` | D1, D2, M1 |
| `service/job/ReplenishOrderJobService.java` | D2 caller |
| `schedulejob/ReplenishOrderJob.java` | D3 |
| `service/ReplenishGeneratorService.java` | C0 + javadoc |
| `service/ReplenishmentOrderMaintenanceService.java` | R1/R2 + `RecalcContext` javadoc |
| `service/ReplenishorderService.java` | R3 |

---

## 5. Fix design

### Fix A — repository finders (all `@RestResource(exported = false)`)

`FixLocationAssignmentRepository`, scalar shapes copied from `LocationRepository.lockById` (`@Lock(LockModeType.PESSIMISTIC_WRITE) @Query("SELECT l.id FROM Location l WHERE l.id = :id")`, whose javadoc says it "materialises no {@code Location} entity" and throws `TransactionRequiredException` outside a tx):

```java
@Lock(PESSIMISTIC_WRITE) @Query("SELECT f FROM FixLocationAssignment f WHERE f.id = :id")
Optional<FixLocationAssignment> findByIdForUpdate(Long id);                          // delete, deleteByUser, move
@Lock(PESSIMISTIC_WRITE) @Query("SELECT f.id FROM FixLocationAssignment f WHERE f.itemdataId = :i AND f.assignedlocationId = :l")
Optional<Long> lockIdByItemdataIdAndLocation(Long i, Long l);                         // C0
@Lock(PESSIMISTIC_WRITE) @Query("SELECT f.id FROM FixLocationAssignment f WHERE f.itemdataId = :i")
Optional<Long> lockIdByItemdataId(Long i);                                            // recalc, R3
@Query("SELECT f.assignedlocationId FROM FixLocationAssignment f WHERE f.itemdataId = :i AND f.active = true")
Optional<Long> findActiveLocationIdByItemdataId(Long i);                              // post-lock read
```

Uniqueness: PRD has unique indexes on `itemdata_id` and `assignedlocation_id`, so each finder returns at most one row. Under READ COMMITTED, a `FOR UPDATE` that waited on a row that was then deleted returns nothing. If the row was moved instead, the predicate is re-evaluated (`assignedlocationId = :l` fails) and it also returns nothing. Callers treat empty as "FLA gone".

`ReplenishorderRepository`, which is a `@RepositoryRestResource` (exported), so `exported = false` is mandatory:
- `findItemdataIdByIdAndDestinationIdIsNull(Long id)`: `SELECT r.itemdataId … WHERE r.id = :id AND r.destinationId IS NULL`. A scalar, so no `Replenishorder` enters the context before its lock (SBDEV-3244).
- `findIdsByStateLessThanEqualAndDestinationIdIsNullOrderById(Integer state)`: R3's id list.

Rail: append the four FLA names to `FunctionGuardArchTest.fixLocationAssignmentRepository_shouldStillExportItsSiblingSearches`' `containsExactlyInAnyOrder(...)`, with a SBDEV-4031 comment beside SBDEV-3128's.

### Fix B — delete side (D1, D2, D3, P52)

- **D1 `deleteByUser`:** replace `fixLocationAssignmentRepository.findById(fixedLocationAssignmentId)` with `findByIdForUpdate`. `checkRemovable`, the holder projection, and the order locks and cancels all run after it, unchanged. The projection now sees any order a creator committed while the delete waited. Javadoc: add step 0, *"Lock the assignment row (SBDEV-4031). Every check below runs under it"*. This also closes F4, the stale `checkRemovable` that today only `@Version` fences.
- **D2 `delete(Long)`:** same first statement. The caller loses its pre-read: `deleteEmptyFixAssignmentWithoutStockToReplenish` today calls `fixLocationAssignmentRepository.findById(...).orElseThrow(...)` and then `delete(fixedLocationAssignment.getId())`. With an entity lock inside `delete`, that read would make the lock a version-checked upgrade (SBDEV-3244, `LockReadRail` would flag it). Call `delete(fixedLocationAssignmentId)` and log the id. If the FLA is already gone, the lock returns empty, `delete` throws its existing `"Can't find fix assignment by ID."` BusinessException, and the existing catch returns. Today that case throws `EntityNotFoundException`.
- **P52 decision: annotate `delete(Long)` with `@Transactional(value = "tenantTransactionManager", propagation = Propagation.MANDATORY)` and deliberately NO `rollbackFor`.** The brief's `REQUIRED + rollbackFor = {BusinessException…}` walks into the SBDEV-3854 trap, verified in the code:
  - the only caller catches the refusal (`catch (BusinessException | FacadeException e) { … return; }`) inside its REQUIRES_NEW;
  - a rollback rule on BusinessException would mark that transaction rollback-only;
  - the commit would then throw `UnexpectedRollbackException`;
  - `ReplenishOrderJob`'s delete catch (`OptimisticLockException | OptimisticLockingFailureException`) does not catch that exception, so it reaches the per-tenant outer catch and **aborts the tenant's run**. It would do so on every ordinary refusal, which the new lock makes more common.

  `BusinessException extends Exception` (checked), so with no `rollbackFor` Spring's default does not roll back on it. Behaviour is then identical to today, plus MANDATORY makes "no transaction" fail fast at the proxy instead of at the lock query. Javadoc cites SBDEV-3854 and `checkRemovable`'s existing comment.
- **D3:** `ReplenishOrderJob` delete sub-op `catch (OptimisticLockException | OptimisticLockingFailureException e)` → add `| PessimisticLockingFailureException`, the shape the cancel sub-ops already use. Do the same for the `generateReplenishmentForItemDataWithFixedAssignmentWithOrders` catch, because C0's lock can now time out behind a user delete that holds F longer than 3 s. Without it, that exception reaches `drainPageZero`'s caller and aborts the tenant run.

### Fix C — creator side (C0)

First statement of `calculateOrder(Long, BigDecimal, Long, Integer, boolean automatic)`:

```java
if (automatic && destinationId != null
        && fixLocationAssignmentRepository.lockIdByItemdataIdAndLocation(itemDataId, destinationId).isEmpty()) {
    LOG.info("SBDEV-4031: no fix assignment for itemData={} at destination={} under lock: skipping", itemDataId, destinationId);
    return null;
}
```

- The lock is held only for this REQUIRES_NEW (milliseconds). The INSERT and the lock share one transaction, so there is no self-deadlock.
- Null is already a tolerated return. All three automatic callers discard the result (`self.calculateAutomaticOrder(ass.getItemdataId(), …)` ×2, `replenishGeneratorService.calculateAutomaticOrder(flaItemData.getId(), …)`), and `createIdempotently` already returns null on the dup-index race.
- Widen the javadoc *"Returns null ONLY when a pending replenish order already exists"* to also say *"…or, for an automatic create with a destination, when that destination no longer holds the item's FLA under lock (SBDEV-4031)"*.
- It is gated on `automatic` because operator creates may target FLA-free destinations by design (SBDEV-2854). That gap is P69.

### Fix D — recalc side (R1, R2) and the `RecalcContext` claim

`recalculateOrder(Long orderId, RecalcContext ctx)`, before the existing `findByIdForUpdate`:

```java
// SBDEV-4031: F before the order. A scalar hint, not an entity read: the first-touch rule (SBDEV-3244) is about
// loading the Replenishorder; this returns one Long. Destinations only go null→non-null, so a stale "null" costs one
// unnecessary lock and a stale "non-null" cannot occur.
Optional<Long> nullDestItem = replenishorderRepository.findItemdataIdByIdAndDestinationIdIsNull(orderId);
nullDestItem.ifPresent(fixLocationAssignmentRepository::lockIdByItemdataId);
Replenishorder order = replenishorderRepository.findByIdForUpdate(orderId).orElse(null);
```

The existing *"do not add a pre-lock read above it"* comment gets one clause: *"…of the entity. The SBDEV-4031 scalar hint above is not one."*

`alignDestination(order, assignment)` changes to take the location post-lock:

```java
if (order.getDestinationId() == null) {
    Optional<Long> loc = fixLocationAssignmentRepository.findActiveLocationIdByItemdataId(order.getItemdataId());
    if (loc.isPresent()) { order.setDestinationId(loc.get()); replenishorderRepository.save(order); }
}
```

`recalculateForItem`: when `openOrderIds` is non-empty, call `fixLocationAssignmentRepository.lockIdByItemdataId(itemDataId)` **before the loop, unconditionally**. This closes ABBA-3/4 without a second pre-lock query, and the inner hint lock is then re-entrant. All four callers hold no locks when they call it: the trigger runs in a new tx after commit, `fulfillMultipleUnitLoads` calls it after its tx, and the cron thread calls it outside a tx.

Retire the `RecalcContext` javadoc and the matching comment in `buildRecalcContext`: *"FixLocationAssignment… may stay managed at READ: nothing on the recalculateOrder path locks any of them"*. Replace it with: *"FixLocationAssignment IS locked on this path (SBDEV-4031), by the scalar `lockIdBy*` finders only. They materialise no entity, so the READ entries here are never upgraded. Never lock an FLA with the entity finder on this path."* `resolveUpperBound(assignment)` keeps reading bounds from ctx: stale bounds self-heal (A2, out of scope).

### Fix E — R3 lock-fix

`recalculateReplenishmentOrderWithoutFixedLocationAssignment` stops loading entities with `findByStateLessThanEqualAndDestinationIdIsNull`. Per id from `findIdsByStateLessThanEqualAndDestinationIdIsNullOrderById(PROCESSABLE)`:
1. `findItemdataIdByIdAndDestinationIdIsNull(id)`; if empty, `continue`.
2. `lockIdByItemdataId(item)`.
3. `findByIdForUpdate(id)` (first touch). If the order is null, or `state > PROCESSABLE`, or its destination is already set, `continue`.
4. `findActiveLocationIdByItemdataId(item)`; if present, set it and save.

The order lock is needed: without it a concurrent confirm's `template.setDestinationId(...)` races R3's save. **Behaviour change:** inactive FLAs are no longer assigned (today R3 ignores `active`), which matches `alignDestination`. The removed `Optional.get()` calls shrink frozen ArchUnit store `5fb3fee0-…` (entries cite `ReplenishorderService.java:314/316/317`). Refresh the store in the same commit.

### Fix F — `move` (Q1 folded in)

**Choice: re-point, not cancel.**
- **Why re-point:** the source SU and its reservation are unchanged, and only the destination is wrong. The FLA's own unit load physically travels to L′ inside this same transaction, so "the order delivers to wherever the FLA is" stays true.
- **Why not cancel:** cancelling releases the reservation, throws away the order number and priority, and leaves the item unreplenished until the next cron tick re-creates the order, possibly from a different source.
- **Guard rails:** no source or reservation write, so no SU lock is added.

New body order:
1. `FixLocationAssignment fla = fixLocationAssignmentRepository.findByIdForUpdate(id).orElseThrow(...)`: first touch.
2. Existing destination checks, unchanged.
3. Replace `replenishorderService.getActive(fixedLocationAssignment.getItemdataId(), null)`, which would load order entities at READ and turn step 4's lock into a version-checked upgrade that `LockReadRail` flags:
   - the "in processing" refusal becomes a scalar `existsByItemdataIdAndStateGreaterThanAndStateLessThan(item, PROCESSABLE, FINISHED)` (new, `exported = false`);
   - **refuse** the move if `findHoldersByStateLessThanAndItemdataIdAndDestinationIdOrderById(FINISHED, item, destinationId)` is non-empty, with *"ReplenishmentOrder=X already targets the destination"*. `idx_replenishorder_active_item_dest` would reject the re-point otherwise. This is reachable only via C5/C6 (P69).
4. `holders = findHoldersByStateLessThanAndItemdataIdAndDestinationIdOrderById(FINISHED, item, oldLocation.getId())`. For each, ascending: `findByIdForUpdate`; skip if null or `state >= FINISHED`; throw `inProcessing` if `state > PROCESSABLE` (claimed after the projection). Collect.
5. Existing unit-load checks and `transferUnitLoadToLocation`, unchanged.
6. For each collected order: `setDestinationId(destination.getId())`, save, and `LOG.info("SBDEV-4031: re-pointed replenishmentOrder={} from {} to {}", …)`.
7. Rest unchanged.

Lock order: F → orders asc → location (ABBA-10 residual, §4.2).

**Out of scope:** `alignDestination` re-pointing non-null stale destinations in general. That would turn every recalc into a destination rewriter for operator-chosen FLA-free destinations (SBDEV-2854), which is wrong. The stale-destination detector is P70.

### Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Lock the Location row | ABBA-7 cycle with confirm; hot row (every put, move, confirm) |
| Per-item advisory lock | Works, but invisible to `pg_blocking_pids` probes and `LockReadRail`; advisory locks here are job-scoped. Reserve if P69 widens scope |
| Re-check FLA after insert, no lock | Write skew survives |
| DB trigger / constraint | Contradicts SBDEV-2854 FLA-free destinations |
| SERIALIZABLE | Cron catches are not built to retry 40001 |
| Lock F in C1/C3's outer tx | 3 edits instead of 1; holds F across a second connection's lifetime |
| F after the order in recalc (the brief's hypothesis) | ABBA-3: deadlock in `recalculateForItem`'s shared tx |
| `delete(Long)` `@Transactional(REQUIRED, rollbackFor=BusinessException)` | SBDEV-3854 trap (Fix B) |
| Do nothing | Not a fix; 1 live PRD orphan with a 5-week-held reservation |

### File change summary

| File | Change |
|---|---|
| `FixLocationAssignmentRepository` | +4 finders |
| `ReplenishorderRepository` | +3 scalar finders (`findItemdataIdByIdAndDestinationIdIsNull`, R3 id list, `existsByItemdataIdAndStateGreaterThanAndStateLessThan`) |
| `FixLocationAssignmentService` | D1, D2 (+MANDATORY), Fix F |
| `ReplenishOrderJobService` | drop pre-read |
| `ReplenishOrderJob` | 2 catches |
| `ReplenishGeneratorService` | C0 + javadoc |
| `ReplenishmentOrderMaintenanceService` | Fix D + javadoc retirements |
| `ReplenishorderService` | Fix E |
| `FunctionGuardArchTest`, archunit store | pin + store refresh |
| New `FixLocationAssignmentLockCallSiteArchTest` | AC-8b |

---

## 6. Implementation steps

### 6.1 Prerequisites

| # | Prerequisite | Value |
|---|---|---|
| 1 | Database state | N/A: no Flyway. Unique indexes on `fix_location_assignment(itemdata_id)` / `(assignedlocation_id)` already exist (PRD verified) |
| 2 | Sysprops | N/A: none added. `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` stays as-is per tenant (PRD `false`) |
| 3 | Config | N/A: uses existing `wms.tenant.lock-timeout-ms=3000` |
| 4 | Deploy order | SBDEV-2622 (`deleteByUser`) merged as 6111d090; it is an ancestor of 05f962b3 ✓ |
| 5 | Data migration | N/A. REPL062709 left as-is (Q4) |
| 6 | External systems | N/A |
| 7 | Access | N/A: no new function or endpoint |
| 8 | Monitoring | N/A: INFO tokens `SBDEV-4031:` only; detector is P70 |

### 6.2 Checklist (commit order)

1. **Fix A + rail:** finders and the `FunctionGuardArchTest` pin. Gate: the rail is green and `FixLocationAssignmentLockCallSiteArchTest` (AC-8b) is written.
2. **Failing ITs first** (wms-tdd-gate): AC-1..AC-7, AC-10, AC-11 red on the orphan/destination assertion, never on a timeout.
3. **Fix B + C:** delete side and C0. Gate: AC-1, 2, 3, 6, 7, 9 green.
4. **Fix D + E:** recalc and R3, plus javadoc retirements. Gate: AC-4, AC-5 green; `ReplenishorderServiceUnitTest` R3 nested tests rewritten; archunit store refreshed.
5. **Fix F:** move. Gate: AC-10, AC-11 green.
6. **Floor:** mutation pass (§8.3), full `mvn verify` vs the adjacent baseline, code review, fix every finding including Low.

---

## 8. Testing plan

### 8.1 Harness rules
- Two real-Postgres threads. Park with `@MockitoSpyBean` on **repositories only** plus `doAnswer` (call the real method, then await a latch), as in `ReplenishDupConcurrencySliceIT`. That file documents why spying a CGLIB `@Transactional` service breaks.
- Seed like `FixLocationAssignmentDeleteByUserIT`.
- Prove "blocked by our holder" with `HeldRowLockRace` / `BlockedBackendReads` (`holderPid = ANY(pg_blocking_pids(pid))`), never a bare `wait_event_type` probe, because the container DB is shared.
- Pre-fix runs must fail on the **business assertion**. Time-box the "B returns" branch at 2 s (under the 3 s lock timeout), so that "blocked" is an asserted state and not a hang.

### 8.2 Acceptance criteria (new class `FixLocationAssignmentLockRaceIT` unless noted)

| AC | Test method | Setup → assertion | Mutation → expected attributable failure |
|---|---|---|---|
| AC-1 | `userDelete_vsRefillParkedInCreate_leavesNoOrphan` | A: `refillSingleFixedLocation`, parked by a spy on `findByStateLessThanAndItemdataId` (after C0's lock). B: `deleteByUser`. Assert B is blocked by A's pid, then 0 open orders with dest L and no FLA; B either cancelled the order and deleted the FLA, or refused | Remove the C0 lock → `orphan count expected 0 but was 1`. Move D1's lock after `checkRemovable` + projection → same message |
| AC-2 | `userDeleteHoldingFla_refillSkipsWithNull` | B holds F (parked after `findByIdForUpdate`); A runs the refill and is observed blocked; B commits → A returns null, 0 orders | Drop the C0 lock → A is not observed blocked (`blocked-by-holder expected true`) and `orders expected 0 but was 1`. The location predicate is killed by AC-6/AC-11, not here |
| AC-3 | `cronDelete_vsRefill_refusesAndKeepsOrder` | As AC-1 via `ReplenishOrderJobService.deleteEmptyFixAssignmentWithoutStockToReplenish` → FLA kept, order kept, no `UnexpectedRollbackException` | Restore the caller's `findById` pre-read → `StaleObjectStateException`/`LockReadRail` failure. Add `rollbackFor = BusinessException.class` to `delete(Long)` → `UnexpectedRollbackException` |
| AC-4 | `recalcForItem_vsUserDelete_doesNotAlignToDeletedFla` | Null-dest PROCESSABLE order + F; A `recalculateForItem` parked after `findByItemdataIdIn`; B `deleteByUser` commits → order dest stays null | `alignDestination` reads `ctx` again → `destination expected null but was <L>` |
| AC-4b | `perOrderRecalc_vsMove_alignsToNewLocation` | Same, with per-order `recalculateOrder` vs `move` → dest = L′ | Same mutation → `expected <L′> but was <L>` |
| AC-5 | `recalcForItem_vsUserDelete_noDeadlock` | Order B (dest L, lower id) + O (dest null, higher id); A parked after locking B's SU; B `deleteByUser` → both finish, no 40P01/55P03 | Move the outer `lockIdByItemdataId` after the loop's first lock → `PessimisticLockingFailureException / 40P01` |
| AC-6 | `refillParkedBeforeLock_vsMove_skips` | Refill parked in C0 just before its lock (spy on `fixLocationAssignmentRepository.lockIdByItemdataIdAndLocation`: the answer awaits the latch, *then* calls the real method); `move` commits → lock returns empty, refill returns null, 0 orders to old L | `lockIdByItemdataIdAndLocation` → lock by item only → `orders to old location expected 0 but was 1` |
| AC-7 | `ReplenishOrderJobUnitTest#deleteSubOp_pessimisticLockFailure_continuesRun` (+ `fixedAssignmentSubOp_…`) | the sub-op throws `PessimisticLockingFailureException` → the next sub-op still runs | Remove the new catch arm → `verify(...) wanted but not invoked` |
| AC-8 | `FunctionGuardArchTest#fixLocationAssignmentRepository_shouldStillExportItsSiblingSearches` | pin lists the 4 names | Drop `exported = false` on one → `containsExactlyInAnyOrder` diff names it |
| AC-8b | `FixLocationAssignmentLockCallSiteArchTest#flaLockFinders_onlyCalledFromAllowedServices` | ArchUnit: `findByIdForUpdate` / `lockIdBy*` on `FixLocationAssignmentRepository` called only from `FixLocationAssignmentService`, `ReplenishGeneratorService`, `ReplenishmentOrderMaintenanceService`, `ReplenishorderService`. `MobileReplenishService` is the named ABBA-5 exclusion | Add a `lockIdByItemdataId` call in `assignDestinationForMultiUnitLoads` → violation naming it |
| AC-9 | `FixLocationAssignmentControllerIT#delete_whileFlaHeldPastLockTimeout_returns409` | `HeldRowLockRace` holds F > 3 s → DELETE `/v3/fixedAssignment/delete/{id}` → 409 "Resource Locked", `retryable: true` | Revert D1 to `findById` → 200/other, not 409 |
| AC-10 | `FixLocationAssignmentMoveIT#move_repointsProcessableOrdersToNewLocation` | PROCESSABLE order to L, reservation R on SU S → `move(L→L′)` → dest L′, `stockunitId` S and reserved R unchanged; follow-up `fulfillMultipleUnitLoads` scanning L′ succeeds | Delete step 6 → `destination expected <L′> but was <L>` |
| AC-10b | `FixLocationAssignmentMoveIT#move_refusesWhenAnOrderAlreadyTargetsDestination` | open order item→L′ (operator-created) → BusinessException "already targets the destination", nothing written | Remove the guard → `DataIntegrityViolationException` on `idx_replenishorder_active_item_dest` |
| AC-11 | `moveHoldingFla_vsRefill_createsNothingAtOldLocation` | `move` parked after step 4 (holding F + orders); refill for (item, L) observed blocked; move commits → refill's location-predicated lock returns empty → null | `lockIdByItemdataIdAndLocation` → `lockIdByItemdataId` → `orders to old location expected 0 but was 1` |

### 8.3 Regression
- Existing to keep green: `FixLocationAssignmentDeleteByUserIT`, `ReplenishDupConcurrencySliceIT`, `LockReadRailIT`, `ReplenishmentMaintenanceCallSiteArchTest`.
- Expected to change: `ReplenishorderServiceUnitTest` R3 nested tests (rewritten to the id-loop shape) and `ReplenishOrderJobServiceUnitTest` (no pre-read). Rewrite their assertions; do not delete them.
- Every new assertion is mutation-checked per the column above. A kill counts only when the failure message names the assertion.

### 8.4 Manual test plan (DEV, `dev_wh01_om1`, wms-dev-probe)

| Scenario | Precondition query → dev count | Steps | Expected |
|---|---|---|---|
| User delete cancels the bound order | `SELECT count(*) FROM replenishorder r JOIN fix_location_assignment f ON f.itemdata_id=r.itemdata_id AND f.assignedlocation_id=r.destination_id WHERE r.state<=300;` → **469** (2026-11-06) | DELETE `/v3/fixedAssignment/delete/{id}` as a System user with MANAGE_REPLENISHMENT_ORDER | order 700, FLA gone, SU reservation released |
| Move re-points | same query → **469** (plus an empty flowbin: `SELECT count(*) FROM location l JOIN location_type t ON t.id=l.type_id WHERE lower(t.sltname)='flowbin' AND NOT EXISTS (SELECT 1 FROM fix_location_assignment f WHERE f.assignedlocation_id=l.id) AND NOT EXISTS (SELECT 1 FROM unitload u WHERE u.storagelocation_id=l.id);` → **723** (DEV spells it `flowbin`; `='FLOWBIN'` returned a false 0, positive control: 1344 flowbins hold an FLA)) | move FLA L→L′ | order dest = L′, same stockunit_id/reserved |
| No new orphans after a cron tick | `SELECT count(*) FROM replenishorder r WHERE r.state<700 AND r.destination_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fix_location_assignment f WHERE f.itemdata_id=r.itemdata_id AND f.assignedlocation_id=r.destination_id);` → **2** (2026-11-06; matches the analysis) | wait one cron minute after the two scenarios | count unchanged |

If a count is 0, seed with out-of-band ids and prove restore with `snapshot.sh`.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| User delete/move now waits up to 3 s behind a cron create or recalc | Both hold F for milliseconds; on timeout the 409 is retryable (AC-9) |
| A pre-lock hint read mistaken for a SBDEV-3244 regression by a later reader | Comment at the site; the hint is scalar; `LockReadRail` still guards entities |
| R3 skips inactive FLAs (behaviour change) | Matches `alignDestination`; stated in the commit |
| ABBA-10 residual | Detector-resolved within 1 s; same class as existing confirm × UL-move |
| ArchUnit freeze store drift (R3 `Optional.get()` lines) | Refresh the store in the same commit (cf. 1c94c64) |
| `MANDATORY` surprises a future non-tx caller | It fails fast with `IllegalTransactionStateException`, which is the intent |

---

## 7. Horizontal scalability

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | No | Row locks only |
| 2 | Pool math | No | Locks taken in existing transactions; no new connection (C0 lock lives in the inserting REQUIRES_NEW) |
| 3 | Scheduled jobs | No new job | Cron stays serialized per tenant by `advisoryLockService.tryLock(REPLENISH_ORDER, tenantId)`; the fix is for cron × interactive across replicas, which row locks cover |
| 4 | Long transactions | Slightly longer worst case | ≤ 3 s wait behind F, bounded by `lock-timeout-ms` |
| 5 | Request affinity | N/A | Stateless |
| 6 | Retry / idempotency | Yes, satisfied | C0 skip is a null return; next tick recomputes. 409 is retryable |
| 7 | Tenant context | No | No async boundary added |
| 8 | Distributed lock correctness | **Yes, the point** | All new locks are DB row locks inside `tenantTransactionManager` transactions; `delete(Long)` now MANDATORY |
| 9 | Cache invalidation | No | FLA and Replenishorder not cached on these paths |
| 10 | External notifications | No | None added |

### v2 constraints

| # | Constraint | Status |
|---|---|---|
| 1 | `tenantTransactionManager` on every `@Transactional` | ✓ (only new one: `delete(Long)` MANDATORY) |
| 2 | No OSIV reliance | ✓ |
| 3 | Constructor injection | ✓ `ReplenishGeneratorService`, `ReplenishorderService` already hold `fixLocationAssignmentRepository`; `ReplenishmentOrderMaintenanceService` too (`buildRecalcContext`) |
| 4 | JPQL only | ✓ all new finders JPQL |
| 5 | No controller/payload change | ✓ (409 mapping exists) |
| 6 | No new `FunctionEnum` | ✓ |
| 7 | New repo methods `exported = false` | ✓ + pin |
| 8 | Lock first touch (SBDEV-3244) | ✓ every entity lock is first touch; others scalar |

### Completeness checklist

| # | Item | Filled |
|---|---|---|
| 1 | Sibling sweep (every creator, deleter, destination writer) | §0, by the named greps |
| 2 | Invariant over instance | Lock rule §4.1 + ArchUnit AC-8b, not just the PRD order |
| 3 | DB verified | §1 PRD counts; §8.4 DEV counts run 2026-11-06 (469 / 723 / 2) |
| 4 | Lock-order matrix + ABBA | §4.1/4.2 |
| 5 | SBDEV-3244 upgrade trap | Fix B (D2 pre-read), Fix D (scalar), Fix F (`getActive` removed) |
| 6 | SBDEV-3854 rollback-only trap | Fix B P52 |
| 7 | Cron abort paths | D3 |
| 8 | Null-return contract | Fix C, all 3 callers checked |
| 9 | Rails touched | `FunctionGuardArchTest`, archunit store |
| 10 | Mutation per AC | §8.2 |
| 11 | Proposals for out-of-scope findings | §10 |

**Verify script: NONE.** Every invariant is behavioural (the two-thread ITs) or structural and pinnable in ArchUnit (AC-8, AC-8b), and those run in CI and survive refactors. No cross-file invariant remains that a grep row would catch and a test would not.

---

## 10. Decisions

### Resolved (Nam, 2026-11-06)
- **T3 confirmed.**
- **Q1, move(): folded in.** F entity lock as first touch; PROCESSABLE orders to the old location are **re-pointed** (Fix F, the planner's choice, justified there); refuse if one already targets the destination.
- **Q2, operator creates (C5/C6): OUT → P69** in `2-Areas/proposals-register.md`.
- **Q3, R3: lock-fix, keep** (Fix E).
- **Q4, PRD REPL062709: leave as-is** (known stranded order).
- **F3 detector: OUT → P70.**
- **P52: closed here** with `MANDATORY` and no `rollbackFor`. The brief's REQUIRED + `rollbackFor` form was rejected on the SBDEV-3854 trap (Fix B).

### Open
- None blocking. The §8.4 DEV counts were run by the main session on 2026-11-06.

### ADR
- **Decision:** the FixLocationAssignment row is the lock object for "which location does this item's replenishment go to". Every path that creates, aligns, re-points or deletes against it locks it first: entity lock where it is the first touch, scalar where the tx may already hold the entity. Lock order: F → orders ascending → SU → location. Confirm never locks F.
- **Drivers:** (1) correctness: kill the write skew that produced PRD REPL062709; (2) no new deadlock edge on the hot confirm path; (3) the smallest change at the choke points (C0 covers 3 creators).
- **Alternatives:** location-row lock, advisory lock, post-insert re-check, trigger/constraint, SERIALIZABLE, outer-tx lock in C1/C3, F-after-order, do nothing (§5 table).
- **Why chosen:** the FLA row has zero existing lock edges, is unique per item and per location, and makes moved or deleted rows vanish from a waiting `FOR UPDATE` under READ COMMITTED, so callers get "gone" for free.
- **Consequences:** user delete/move can wait ≤ 3 s or get a retryable 409; recalc does one extra PK scalar per order; R3 stops assigning inactive FLAs; ABBA-10 residual is accepted.
- **Follow-ups:**
  - **P69:** operator creates refuse a destination holding another item's FLA (T1 proposal).
  - **P70:** stale-destination detector as a cron WARN metric.
  - **P52:** closed by this plan.
  - **F2 (T0):** `refillFixedLocations` has no caller, and the FLA repo javadoc cites stale `MobileReplenishService:720/:1128`. Delete or fix on this ticket.
  - **F5 (T0 doc):** the transaction-boundary map §8.5 and the ticket say lock_timeout is 5 s; it is 3000 ms.

### Recommended OMC composition

| Aspect | Value |
|---|---|
| Tier | T3 |
| Pre-draft | done (analysis lane) |
| Plan review | ralplan one round: `architect` + `critic` |
| Implementation | wms-tdd-gate → `ralph` in `.claude/worktrees/wms2-api/SBDEV-4031` |
| Verification | the floor + `verifier` lane; no verify script |
| Code review | `code-reviewer`, fix every finding including Low |
| Commit | `git-master`, §6.2 order |
