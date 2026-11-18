---
title: "FLA delete vs replenishment creators: lock the FixLocationAssignment row first, everywhere an order's destination is decided from it"
ticket: "SBDEV-4031"
ticket_url: "https://app.clickup.com/t/868mtjjwt"
type: "bug"
priority: "normal"
status: "archived"
tier: T3
project: [wms2]
version: "v2"
repos: [wms2-api]
branch: "bugfix/SBDEV-4031-fla-lock"
revision: "r3 — final edit pass on review-critic-r2.md (APPROVE) and review-architect-r2.md (round 1 closed, 5 Lows). r2 answered round 1. Disposition tables in §11."
db_verified: true
db_verified_note: "wsl-wineco-prd (read-only) 2026-11-06 via the analysis lane: orphan=1 / bound=561 / open=584, REPL062709 timeline; 21 open null-destination orders, none for an item holding an FLA. DEV precondition counts: §8.4 only."
base_commit: "wms2-api origin/develop d6424491 (05f962b3..d6424491 touches only SecurityConfiguration + 2 tests; SBDEV-2622 6111d090 is an ancestor)"
requester: "Nam Park"
created: "2026-11-06"
updated: "2026-11-07"
related:
  - "[[SBDEV-2622]]"
  - "[[SBDEV-3244]]"
  - "[[SBDEV-3637]]"
tags:
  - plan
---

# SBDEV-4031: lock the FLA row before deciding an order's destination from it

**Ticket:** [SBDEV-4031](https://app.clickup.com/t/868mtjjwt) · **Tier:** T3 (lock topology across delete, create, recalc and move; data integrity: orphaned orders with held reservations) · **Branch:** `bugfix/SBDEV-4031-fla-lock` · **Evidence:** `SBDEV-4031-evidence/{analysis,review-critic-r1,review-architect-r1}.md`

> **Archived 2026-11-07.** On dev as #637 `65444c6b`; manual DEV scenarios passed (§12). Findings: P69, P70, P71 and P72 (F2) in `2-Areas/proposals-register.md`; P52 delete half done here (row updated); architect N1 is an accepted 40P01 residual (§4.2); PRD REPL062709 left as-is (Q4).
> No acceptance script (none was written).
> Implementation worktree(s) removed 2026-11-07: wms2-api/SBDEV-4031, .baseline/SBDEV-4031

---

## 0. Affected sites

Enumeration method: the three `git grep` sweeps in analysis §0, re-run on d6424491 together with `git grep -n -E '\.(calculateAutomaticOrder|calculateOrder)\(' origin/develop -- src/main` and `git grep -n -E '\.recalculateForItem\(|\.recalculateOrder\(' origin/develop -- src/main`. Blind spots: reflection, SpEL, raw JDBC, Spring Data REST writes on the exported `ReplenishorderRepository` (§4.2).

| # | Site | Verdict |
|---|---|---|
| D1 | `FixLocationAssignmentService.deleteByUser` | **IN.** The FLA entity lock is the first statement |
| D2 | `FixLocationAssignmentService.delete(Long)` and its caller `ReplenishOrderJobService.deleteEmptyFixAssignmentWithoutStockToReplenish` | **IN.** Lock first; drop the caller's `findById` pre-read; `propagation = MANDATORY` (Fix B) |
| D3 | `ReplenishOrderJob` catches: the delete sub-op, `generateReplenishmentForItemDataWithFixedAssignmentWithOrders`, R3 | **IN** |
| C0 | `ReplenishGeneratorService.calculateOrder(…, boolean automatic)` | **IN.** The creator choke point. It covers C1 `refillSingleFixedLocation`, C2 `refillFixedLocations` and C3 `generateReplenishmentForItemDataWithFixedAssignment` |
| C4 | `generateReplenishmentForItemDataWithoutFixedAssignment` | OUT: its destination is null, so no FLA is involved |
| C5/C6 | `ReplenishorderService.create`, `MobileReplenishService.requestReplenish` | **OUT → P69** (Q2) |
| C7/C8 | `createOrderFromTemplate`; SBDEV-3636 post-finish refill | OUT. The template's children finish inside the same tx, and SBDEV-3678 removed the post-finish refill |
| R1/R2 | `ReplenishmentOrderMaintenanceService.recalculateOrder` / `alignDestination` / `recalculateForItem` | **IN.** Scalar FLA lock before the first order lock; destination read after the lock |
| R3 | `ReplenishorderService.recalculateReplenishmentOrderWithoutFixedLocationAssignment` | **IN.** Lock-fix, one REQUIRES_NEW per order (Q3) |
| M1 | `FixLocationAssignmentService.move` | **IN, widened** (Q1): lock order F → P → L′ → O, and re-point PROCESSABLE orders still headed to the old location |
| A1–A3 | `changeActive`, bound edits, `createFixedLocationAssignment` | OUT (analysis §0). `changeActive` has no `@Transactional`; that stays with P52 |
| V1 | `MobileReplenishService.assignDestinationForMultiUnitLoads` | OUT, and it **must never lock the FLA** (ABBA-5). Pinned by AC-8b |

---

## 1. Problem

An open replenishment order can point at a location that no longer holds its item's FixLocationAssignment. It keeps its source reservation and cannot be confirmed: confirm fails with *"53-C01 has different fixed assignment"* or *"is wrong location!"*, or, on an empty FLA-less flowbin, quietly re-creates the deleted FLA.

**DB evidence (wsl-wineco-prd, 2026-11-06, analysis §6):** 584 open orders, 561 bound to their item's FLA, **1 orphaned**: REPL062709 (id 35616403, item PN2021SCA, destination 53-C01). UTC 2026-09-29: 17:27:17.323 the user cancels REPL062707 → 17:27:24.219 the cron INSERTs REPL062709 with destination 53-C01 (`version 0`, `created == modified`: written by the INSERT) → 17:27:24.228 it reserves 12 on SU 21813425 → the user's FLA delete commits inside that ~7 s window. SU 21813425 has been 12/12 reserved for 5+ weeks; left as-is (Q4). DEV's same-shape rows predate any delete (F1 or C5/C6, not this race).

---

## 2. Root cause

**Race 1: creator vs delete (the PRD orphan).** `refillSingleFixedLocation` reads the FLA with a plain `findById`, then `self.calculateAutomaticOrder(...)` inserts in a REQUIRES_NEW whose only guard is order-side:

```java
Replenishorder blocking = findBlockingPendingOrder(itemDataId, destinationId).orElse(null);
```

`delete(Long)` guards with a plain read, then deletes:

```java
if (!replenishorderService.getActive(fla.getItemdataId(), null).isEmpty()) {
    throw new BusinessException(OPEN_REPLENISHMENT_MSG);
}
applyRemoval(fla, checkRemovable(fla));
```

No shared row; under READ COMMITTED each check runs before the other commits: write skew. `deleteByUser` has the same skew, because its `findHoldersByStateLessThanAndItemdataIdAndDestinationIdOrderById` projection runs before any lock.

**Race 2: recalc vs delete or move.** `recalculateOrder` locks the order, then `resolveActiveAssignment(order.getItemdataId(), ctx)` reads the FLA from a `RecalcContext` built by a plain `findByItemdataIdIn` before the loop, and `alignDestination` writes `order.setDestinationId(assignment.getAssignedlocationId())`. R3 does the same write with no lock and no `active` check.

**Move staleness (deterministic, F1).** `move` refuses only on `replenishOrder.getState() > WmsConstants.State.PROCESSABLE`, so PROCESSABLE orders keep the old destination. `alignDestination` only fills null destinations (`if (order.getDestinationId() == null)`), and `assignDestinationForMultiUnitLoads` refuses with *"is wrong location!"*. The reservation stays held.

---

## 4. Architecture

### 4.1 Lock order

**Rule:** FLA (F) → owning Pickingorders (P, move only) → location → replenishment orders ascending (`findByIdForUpdate` as first touch) → SU.

On PostgreSQL every FLA lock (entity or scalar) renders `FOR NO KEY UPDATE` (`LockReads` javadoc: *"the same lock clause the finders get: `FOR NO KEY UPDATE` on PostgreSQL"*, measured by `StockunitSkipLockedIT`). It conflicts with itself, with `DELETE`, and with `move`'s UPDATE of the unique-indexed `assignedlocation_id`.

| Path | Today | Proposed |
|---|---|---|
| `delete(Long)` | no order lock → SU/UL versioned writes → DELETE | **F (entity)** → SU/UL → DELETE |
| `deleteByUser` | ord(L) asc → SU per cancel → SU/UL → DELETE | **F (entity)** → ord(L) asc → SU → … |
| C0 automatic, destination ≠ null | slot → SU | **F (scalar, item + location)** → slot → SU |
| `recalculateOrder` (per-order tx) | order → SU | **F (scalar), only if the destination-null hint hits** → order → SU |
| `recalculateForItem` (shared tx) | ord₁ → SU₁ → ord₂ … | ctx read → **F (scalar), unconditional, before the loop** → orders |
| R3 | one tx, plain reads, UPDATE at flush | **per order, own REQUIRES_NEW:** F (scalar) → order → UPDATE |
| `move` | location (via Hook A: P → L′) → FLA UPDATE | **F (entity)** → **P asc** (`lockOwningPickingorders` over the FLA unit-load tree) → **L′** (`locationRepository.lockById`) → **O(old L) asc** → transfer (P and L′ re-entrant) → FLA UPDATE |
| multi-UL confirm | T → plain FLA reads → SUs → location | unchanged; **never F** |

`move`'s P → L′ prefix copies what `transferUnitLoadToLocation` does for a BLOCK_REALIGN code such as `CODE_MOVE_FIX_ASSIGNMENT` (`pickLineRealignmentService.lockOwningPickingorders(treeStockUnitIds)`, then `LockReads.forUpdate(entityManager, Location.class, destinationLocationId, locationRepository::findByIdForUpdate)`), so both are re-entrant when the transfer runs.

### 4.2 Deadlock verdicts (derivations: analysis §3, review-architect-r1)

| # | Pair | Verdict |
|---|---|---|
| 1, 8 | `deleteByUser` × per-order recalc / C0 / move | No cycle: all take F first |
| 3/4 | `deleteByUser` × `recalculateForItem` | Closed: F is taken before the loop |
| 5 | multi-UL confirm × `deleteByUser` | No cycle only while confirm never locks F. Fenced by AC-8b and by `ReplenishmentMaintenanceCallSiteArchTest`'s `ALLOWED` set (the transitive fence) |
| 7 | Location row as the lock object | Cycle with confirm, so rejected |
| 9 | R3 × item-scoped paths | No cycle: one order per tx |
| 10/10b | `move` × a BLOCK_REALIGN transfer (e.g. `CODE_TRANSFER`) of O's source pallet S | **Closed by the P → L′ → O prefix.** A transfer takes P → location → holder orders (`MovedStockUnitHolders.lockForMove`), and `move` now has the same order. r1's F → O → P shape was a live cycle whenever one pick order had lines on both the flowbin SU and S. Guarded by AC-10c (its mutation restores r1's order) |

**Residual (architect N1).** The P pre-walk is a snapshot. A pick line committed on the flowbin tree between step 2 and the transfer's Hook A adds a Pickingorder lock *after* O, which can close a cycle with a concurrent `CODE_TRANSFER` of S. PostgreSQL resolves it as 40P01 within 1 s, one side rolls back, and no data is lost. **Do not** lock the flowbin SU early to close it: that SU lock would form a cycle with confirm.

**Accepted tension.** `move` takes P and L′ before its L′-dependent refusal checks (FLA or unit load already at L′; since fd1a5378 the lock-free refusals — not a flowbin, order in processing, order already at L′ — run before P/L′), so a move that ends up refused still briefly blocks pickers whose pick orders own lines on the flowbin's unit-load tree, for at most the duration of the move transaction.

**Monotonicity premise** — ⚠ **broken by SBDEV-4044's `detach`; see §10.x/§10.z.** On a stale hint `recalculateOrder` now skips alignment for that pass (§10.z), it does not take a late F lock. Original text: no code sets `destination_id` back to null. Method: `git grep -n 'setDestinationId(' origin/develop -- src/main`, no literal null; Fix F adds none. Blind spot: a Spring Data REST PUT/PATCH on the exported `ReplenishorderRepository`. That only defeats the hint: the post-lock re-check still runs, so the worst case is one missed F lock, i.e. today's behaviour.

---

## 5. Fix design

### Fix A: finders, all `@RestResource(exported = false)`

`FixLocationAssignmentRepository`. The scalar shape copies `LocationRepository.lockById` (`@Lock(LockModeType.PESSIMISTIC_WRITE) @Query("SELECT l.id FROM Location l WHERE l.id = :id")`, which *"materialises no {@code Location} entity"* and throws `TransactionRequiredException` outside a transaction):

```java
@Lock(PESSIMISTIC_WRITE) @Query("SELECT f FROM FixLocationAssignment f WHERE f.id = :id")
Optional<FixLocationAssignment> findByIdForUpdate(Long id);                                // delete, deleteByUser, move
@Lock(PESSIMISTIC_WRITE) @Query("SELECT f.id FROM FixLocationAssignment f WHERE f.itemdataId = :i AND f.assignedlocationId = :l")
Optional<Long> lockIdByItemdataIdAndLocation(Long i, Long l);                               // C0
@Lock(PESSIMISTIC_WRITE) @Query("SELECT f.id FROM FixLocationAssignment f WHERE f.itemdataId = :i")
Optional<Long> lockIdByItemdataId(Long i);                                                  // recalc, R3
@Query("SELECT f.assignedlocationId FROM FixLocationAssignment f WHERE f.itemdataId = :i AND f.active = true")
Optional<Long> findActiveLocationIdByItemdataId(Long i);                                    // post-lock read
```

At most one row each: the UNIQUE constraints on `itemdata_id`, `assignedlocation_id` and `assignedunitload_id` come from Flyway `V2.2.00__base_v2_schema.sql` (every tenant). Under READ COMMITTED a waiting lock whose row was deleted returns nothing, and a moved row fails the re-evaluated predicate, so every caller treats empty as "FLA gone".

`ReplenishorderRepository` is exported, so **exactly three** new finders carry `exported = false`: `findItemdataIdByIdAndDestinationIdIsNull(Long id)` (`SELECT r.itemdataId … WHERE r.id = :id AND r.destinationId IS NULL`, scalar, so no `Replenishorder` enters the context before its lock, SBDEV-3244); `findIdsByStateLessThanEqualAndDestinationIdIsNullOrderById(Integer state)` (R3's ids; `@Query("SELECT r.id FROM Replenishorder r WHERE r.state <= :state AND r.destinationId IS NULL ORDER BY r.id")`; the old entity finder `findByStateLessThanEqualAndDestinationIdIsNull` is **retired** with its test stubs, so no caller can reintroduce the pre-lock entity read); `existsByItemdataIdAndStateGreaterThanAndStateLessThan(Long, Integer, Integer)` (`move`'s "in processing" refusal).

Rails: append the four FLA names to `FunctionGuardArchTest.fixLocationAssignmentRepository_shouldStillExportItsSiblingSearches`' `containsExactlyInAnyOrder(...)`, and add `FunctionGuardArchTest#replenishorderRepository_sbdev4031FindersAreUnexported` for the three.

### Fix B: delete side (D1, D2, D3, P52)

- **D1 `deleteByUser`:** `findById(fixedLocationAssignmentId)` → `findByIdForUpdate`; everything after it is unchanged, so the holder projection sees any order a creator committed while the delete waited. Javadoc step 0: *"Lock the assignment row (SBDEV-4031); every check below runs under it."* This **narrows, not closes** F4: the FLA's SU is not locked, so `@Version` still fences a confirm that adds stock after `checkRemovable`.
- **D2 `delete(Long)`:** same first statement; `flaOpt.get()` goes away (remove its archunit store entry). The caller drops `fixLocationAssignmentRepository.findById(...).orElseThrow(...)` and calls `delete(fixedLocationAssignmentId)`, because that read would make the entity lock a version-checked upgrade (SBDEV-3244, flagged by `LockReadRail`). An already-gone FLA throws `"Can't find fix assignment by ID."`, which the existing catch handles.
- **P52: `@Transactional(value = "tenantTransactionManager", propagation = Propagation.MANDATORY)`, deliberately NO `rollbackFor`.** The only caller catches `BusinessException | FacadeException` inside its REQUIRES_NEW and returns. A `rollbackFor = BusinessException` would mark that tx rollback-only and its commit would throw `UnexpectedRollbackException` (the SBDEV-3854 trap). `BusinessException extends Exception`, so with no `rollbackFor` Spring's default leaves it alone: today's behaviour, plus a fast failure when no tx exists. `changeActive`'s missing `@Transactional` (the other half of P52) stays open.
- **D3, `ReplenishOrderJob` catches** (each currently `catch (OptimisticLockException | OptimisticLockingFailureException e)`):
  - delete sub-op: `+ | PessimisticLockingFailureException`, **plus a final `catch (Exception e)` logging at ERROR with `e` itself as the throwable, not only the message** (architect r2) (architect F9; the cancel sub-ops' shape). A `FacadeException` in `sendStockUnitToNirvana` marks the REQUIRES_NEW rollback-only, so the commit throws `UnexpectedRollbackException`, which today aborts the tenant run;
  - `generateReplenishmentForItemDataWithFixedAssignmentWithOrders`: `+ | PessimisticLockingFailureException` (C0 can time out behind a user delete);
  - R3 (`replenishOrderJobService.recalculateReplenishmentOrderWithoutFixedLocationAssignment()`): `+ | PessimisticLockingFailureException`, defence in depth behind Fix E's per-order catch.

### Fix C: creator side (C0)

First statement of `calculateOrder(Long, BigDecimal, Long, Integer, boolean automatic)`:

```java
if (automatic && destinationId != null
        && fixLocationAssignmentRepository.lockIdByItemdataIdAndLocation(itemDataId, destinationId).isEmpty()) {
    LOG.info("SBDEV-4031: no fix assignment for itemData={} at destination={} under lock: skipping", itemDataId, destinationId);
    return null;
}
```

- The lock lives in the inserting REQUIRES_NEW (no new connection, held for milliseconds). Null is already safe: every automatic caller from the `calculateAutomaticOrder` grep discards the result, and `createIdempotently` returns null on the duplicate-index race.
- **Javadoc:** *"Returns null ONLY when a pending replenish order already exists"* is widened to add *"…or, for an automatic create with a destination, when that destination no longer holds the item's FLA under lock (SBDEV-4031)"*.
- **Scope:** it is gated on `automatic` because operator creates may target FLA-free destinations (SBDEV-2854); that gap is P69.

### Fix D: recalc side (R1, R2)

**`recalculateOrder(Long orderId, RecalcContext ctx)`.** Insert before the existing `findByIdForUpdate`:

```java
// SBDEV-4031: F before the order. A scalar hint, not an entity read (the SBDEV-3244 first-touch rule is about loading
// the Replenishorder). Superseded by §10.z: the hint is load-bearing — a stale hint (destination detached after it)
// means no F lock was taken, so alignment is skipped this pass rather than locking F after the order.
replenishorderRepository.findItemdataIdByIdAndDestinationIdIsNull(orderId)
        .ifPresent(fixLocationAssignmentRepository::lockIdByItemdataId);
```

The comment *"do not add a pre-lock read above it"* gains: *"…of the entity. The SBDEV-4031 scalar hint is not one."*

**`alignDestination` reads the location after the lock and returns the assignment the rest of the method uses** (critic F8 / architect F8):

```java
private FixLocationAssignment alignDestination(Replenishorder order, FixLocationAssignment assignment) {
    if (order.getDestinationId() != null) return assignment;
    Optional<Long> loc = fixLocationAssignmentRepository.findActiveLocationIdByItemdataId(order.getItemdataId());
    if (loc.isEmpty()) return null;                       // FLA gone or inactive under lock: no ctx bounds either
    order.setDestinationId(loc.get()); replenishorderRepository.save(order);
    return assignment;
}
```

The caller does `assignment = alignDestination(order, assignment);`. The existing `if (alignDestination(...)) return;` always returned false, so control flow is unchanged. `resolveUpperBound(assignment)` therefore no longer reads a deleted FLA's bounds in the null-destination case. When the destination is set it still reads ctx bounds, which self-heal (A2).

**`recalculateForItem`:** call `fixLocationAssignmentRepository.lockIdByItemdataId(itemDataId)` unconditionally, at a pinned position: **after** `RecalcContext ctx = buildRecalcContext(openOrderIds);`, immediately before `for (Long orderId : openOrderIds)`, guarded by `!openOrderIds.isEmpty()`. AC-4 depends on that position. The lock is scalar because `buildRecalcContext` already put FLA entities in the context at READ (analysis Note U), and the inner hint lock becomes re-entrant. No caller holds locks: `git grep '\.recalculateForItem\('` gives 3 hits, `ReplenishOrderJob` (no tx), `ReplenishmentMaintenanceTrigger` (new tx after commit) and `MobileReplenishService.fulfillMultipleUnitLoads` (javadoc *"deliberately NOT {@code @Transactional}"*, pinned by AC-8b).

**Retire** the `RecalcContext` javadoc and the matching `buildRecalcContext` comment (*"FixLocationAssignment… may stay managed at READ: nothing on the recalculateOrder path locks any of them"*). Replace them with: *"FixLocationAssignment IS locked on this path (SBDEV-4031), only through the scalar `lockIdBy*` finders. Those materialise no entity, so these READ entries are never upgraded. Never use the entity lock here."*

### Fix E: R3 lock-fix, one transaction per order

Today R3 is one tx over every order; with row locks one 55P03 would roll back the whole run while holding N locks. Use the `recalculateOpenOrders` pattern:
- `ReplenishorderService` gains `@Lazy @Autowired private ReplenishorderService self;` (the `ReplenishmentOrderMaintenanceService` idiom). The loop method keeps its name, becomes **non-transactional**, reads `findIdsByStateLessThanEqualAndDestinationIdIsNullOrderById(PROCESSABLE)`, and calls `self.assignFixedDestination(id)` per id inside `try { … } catch (Exception e) { LOG.warn(… id …) }`.
- `ReplenishOrderJobService.recalculateReplenishmentOrderWithoutFixedLocationAssignment` drops its `@Transactional(REQUIRES_NEW)`, so no suspended outer tx holds a second connection.
- New `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW, rollbackFor = {BusinessException.class, FacadeException.class}) public void assignFixedDestination(Long orderId)`: (1) `findItemdataIdByIdAndDestinationIdIsNull(orderId)`, return if empty; (2) `lockIdByItemdataId(item)`; (3) `findByIdForUpdate(orderId)` as first touch, return if null, `state > PROCESSABLE` or destination set; (4) `findActiveLocationIdByItemdataId(item)`; if present and **no other open order already targets (item, that location)** (`findHoldersByStateLessThanAndItemdataIdAndDestinationIdOrderById(FINISHED, item, loc)` empty; reachable via C5/C6), set and save. Otherwise log `SBDEV-4031: skip … already targeted` at INFO, so `idx_replenishorder_active_item_dest` does not WARN every tick (architect N5).
- **Behaviour changes (in the commit message):** inactive FLAs are no longer assigned (matches `alignDestination`); today's `locationRepository.findById(...)` existence check is **dropped**, because the FK on `assignedlocation_id` guarantees it. The removed `Optional.get()` calls shrink archunit store `5fb3fee0-…`; refresh it in the same commit.

### Fix F: `move` (Q1 folded in)

**Decision: re-point rather than cancel.** The source SU and reservation do not change, only the destination, and the FLA's unit load travels to L′ in the same tx. Cancelling would release the reservation, lose the number and priority, and wait a cron tick for a recreate, possibly from another source.

New body order:
1. `findByIdForUpdate(id)` on the FLA: first touch.
2. `pickLineRealignmentService.lockOwningPickingorders(pickLineRealignmentService.collectStockUnitIdsForUnitloadTree(unitloadRepository.getReferenceById(fla.getAssignedunitloadId())))`, then `locationRepository.lockById(destinationId)`. Do not reorder these two: §4.2 ABBA-10b depends on it. `getReferenceById` returns an uninitialised proxy, and the walk reads only `top.getId()` (`collectTree(top.getId(), …)`). A `findById().orElseThrow` here would throw before the existing business refusals and would park AC-10c too early (architect N2).
3. The existing destination checks, unchanged.
4. Replace `replenishorderService.getActive(fixedLocationAssignment.getItemdataId(), null)`. It loads entities, so step 5's lock would become an upgrade. Instead:
   - refuse "in processing" if `existsByItemdataIdAndStateGreaterThanAndStateLessThan(item, PROCESSABLE, FINISHED)`;
   - refuse with *"Can't move fix assignment. ReplenishmentOrder=X already targets the destination!"* if `findHoldersByStateLessThanAndItemdataIdAndDestinationIdOrderById(FINISHED, item, destinationId)` is non-empty. Otherwise `idx_replenishorder_active_item_dest` would reject the re-point; this case is reachable only through C5/C6 (P69).
5. For each holder from `findHoldersByStateLessThanAndItemdataIdAndDestinationIdOrderById(FINISHED, item, oldLocation.getId())`, in ascending order: `findByIdForUpdate`. Skip it if null or `>= FINISHED`; throw "in processing" if `> PROCESSABLE`. Collect the rest.
6. The existing unit-load checks and `transferUnitLoadToLocation`, unchanged (P and L′ are re-entrant there).
7. For each collected order: `setDestinationId(destination.getId())`, save, and `LOG.info("SBDEV-4031: re-pointed replenishmentOrder={} from {} to {}", …)`.

**Out of scope:** making `alignDestination` re-point stale non-null destinations in general. That would rewrite operator-chosen FLA-free destinations (SBDEV-2854). P70 is the detector.

### Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Lock the Location row | ABBA-7 cycle with confirm; the row is hot (every put, move and confirm) |
| Per-item `pg_advisory_xact_lock` | Viable. Rejected because (a) no tenant-transaction advisory helper exists (today's advisory locks are job-scoped, in a keyspace shared with job locks); (b) every path would need the same transaction-scoped call; (c) it loses the free "row gone or moved → empty" result the row lock gives (§5 Fix A). The analysis's "invisible to `pg_blocking_pids`" claim was wrong (architect F5) |
| Re-check the FLA after insert, without a lock | The write skew survives |
| DB trigger or constraint | Contradicts SBDEV-2854 FLA-free destinations |
| SERIALIZABLE isolation | The cron's catches are not built to retry 40001 |
| Lock F in C1/C3's outer tx | 3 edits instead of 1, and holds F across a second connection's lifetime |
| Take F after the order in recalc | ABBA-3 |
| `delete(Long)` `REQUIRED` + `rollbackFor = BusinessException` | SBDEV-3854 trap (Fix B) |
| `move` with F → O → transfer (r1) | ABBA-10b cycle (architect F1) |
| **Split:** ship C0 + D1–D3 now; recalc, R3 and move as separate tickets (architect steelman) | Narrower, and it fixes the one observed orphan. Rejected because Nam folded move in (Q1), and recalc/R3 write the same stale destination (Race 2). Splitting leaves a known Race 2 window open behind a closed Race 1 |
| Do nothing | One live PRD orphan with a reservation held for 5 weeks |

### File change summary

| File | Change |
|---|---|
| `FixLocationAssignmentRepository` | +4 finders |
| `ReplenishorderRepository` | +3 scalar finders |
| `FixLocationAssignmentService` | D1, D2 (+MANDATORY), Fix F, + constructor dependency `PickLineRealignmentService` (depends only on repositories, so no bean cycle) |
| `ReplenishOrderJobService` | drop the pre-read; R3 wrapper non-transactional |
| `ReplenishOrderJob` | catches for the delete sub-op (+ final `Exception`), the fixed-assignment creator and R3 |
| `ReplenishGeneratorService` | C0 + javadoc; delete `refillFixedLocations` (F2) |
| `ReplenishmentOrderMaintenanceService` | Fix D + javadoc retirements |
| `ReplenishorderService` | Fix E (+ `self`) |
| `FunctionGuardArchTest`, archunit store `5fb3fee0-…` | pins; remove entries for `delete(Long)` and R3 |
| NEW `FixLocationAssignmentLockCallSiteArchTest` | AC-8b |

---

## 6. Implementation steps

### 6.1 Prerequisites

| # | Prerequisite | Value |
|---|---|---|
| 1 | Database state | N/A: no Flyway. The UNIQUE constraints come from `V2.2.00__base_v2_schema.sql` |
| 2 | Sysprops | N/A: none added. `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` stays per tenant (PRD `false`) |
| 3 | Config | N/A: uses the existing `wms.tenant.lock-timeout-ms=3000` |
| 4 | Deploy order | SBDEV-2622 (6111d090) is an ancestor of d6424491 ✓. No UI deploy needed (§9) |
| 5 | Data migration | N/A. REPL062709 is left as-is (Q4) |
| 6 | External systems | N/A |
| 7 | Access | N/A: no new function or endpoint |
| 8 | Monitoring | N/A: INFO tokens `SBDEV-4031:` only; the detector is P70 |

### 6.2 Checklist (commit order)

1. **Fix A + rails:** finders, the two `FunctionGuardArchTest` pins, `FixLocationAssignmentLockCallSiteArchTest`.
2. **Failing tests first** (wms-tdd-gate). Each must go red with the §8.2 pre-fix message: AC-1, 2, 3, 4, 4b, 4c, 4d, 4e, 6, 7, 9, 10, 10b, 11. **Not in this list:** AC-5 and AC-10c (regression guards) and AC-8/AC-8b (rails, green after step 1). All four are proven only by their mutations.
3. **Fix B + C.** Gate: AC-1, 2, 3, 6, 7, 9 green.
4. **Fix D + E.** Gate: AC-4…4e and AC-5 green; the §8.3 tests re-stubbed; the archunit store refreshed.
5. **Fix F.** Gate: AC-10, 10b, 10c, 11 green.
6. **T0 riders on this ticket:**
   - F2: delete `refillFixedLocations` (no caller per `git grep '\.refillFixedLocations\('`) and fix the stale `MobileReplenishService:720/:1128` javadoc in `FixLocationAssignmentRepository`;
   - F5: correct "5 s" to 3000 ms in transaction-boundary map §8.5.
7. **Floor:** a mutation pass for every AC (§8.2), full `mvn verify` against the adjacent baseline, code review, and fix every finding including Low.

---

## 8. Testing plan

### 8.1 Harness rules
- **Two real-Postgres threads.** Park a thread with `@MockitoSpyBean` on **repositories only** plus `doAnswer` that calls the real method and then awaits a latch (`ReplenishDupConcurrencySliceIT`).
  - Park on a call that runs **both before and after the fix**, so the pre-fix run completes and goes red on an assertion, not on a latch timeout.
  - Scope every spy to its thread with `if (Thread.currentThread() != threadA) return invocation.callRealMethod();`.
- **Seeding:** like `FixLocationAssignmentDeleteByUserIT`.
- **Holder (critic N3):** `HeldRowLockRace` releases as soon as the subject blocks and exposes neither the subject's pid nor its statement. Where an AC needs either (AC-4c/4d/4e, AC-9), use its `bumpUnderLock` hook, or a small two-latch holder, to (1) read the subject pid via `pg_blocking_pids`, (2) call `confirmedBlockedStatement`, and (3) for AC-4e/AC-9, sleep past `lock-timeout-ms` (3000 ms) before releasing.
- **"Blocked by our holder":** prove it with `BlockedBackendReads.confirmedBlockedStatement(observer, blockedPid, holderPid)`. Assert that the statement contains `fix_location_assignment` and `for no key update`. Never use a bare `wait_event_type` probe; the container DB is shared.
- **Time-box** the "blocked" wait at 2 s (lock timeout is 3 s).
- **Multi-assertion ACs use `SoftAssertions`.** The mutation column names the **first** failing message.

### 8.2 Acceptance criteria

All in the NEW class `FixLocationAssignmentLockRaceIT` unless a row names another class. NEW classes: `FixLocationAssignmentLockRaceIT`, `FixLocationAssignmentControllerIT`, `FixLocationAssignmentMoveIT`, `FixLocationAssignmentLockCallSiteArchTest`.

| AC | Test method | Setup → assertion | Pre-fix red (first failing message) | Mutation → attributable red |
|---|---|---|---|---|
| AC-1 | `userDelete_vsRefillParkedInCreate_leavesNoOrphan` | A runs `refillSingleFixedLocation`, parked on `replenishorderRepository.findByStateLessThanAndItemdataId` (inside C0; post-fix it runs after the lock). B runs `deleteByUser`. Assert B is blocked by A's pid; release A; then 0 open orders whose destination lacks the item's FLA | `B blocked by A's pid: expected true but B completed` (then `orphans expected 0 but was 1`) | Remove the C0 lock → the same first message. Move D1's lock after the projection → `orphans expected 0 but was 1` (B blocks on the FLA lock *after* reading 0 holders) |
| AC-2 | `cronDeleteHoldingFla_refillSkipsWithNull` | B runs `deleteEmptyFixAssignmentWithoutStockToReplenish`, parked on `unitloadRepository.findById` in `checkRemovable` (post-fix it runs after F). A runs the refill. Assert A is blocked by B; release B → the FLA is deleted, A returns null, 0 orders | `A blocked by B's pid: expected true but A completed` (then `orders expected 0 but was 1`) | Remove D2's lock → the same first message |
| AC-3 | `cronDelete_vsRefill_refusesAndKeepsOrder` | As AC-1, with B = the cron delete; the spy is scoped to A. Post-fix: B refuses with `OPEN_REPLENISHMENT_MSG`, the FLA and the order are kept, and there is no `UnexpectedRollbackException` | `B blocked by A's pid: expected true but B completed` (then `FLA expected present`) | Restore the caller's `findById` pre-read → `LockReadRail` violation naming `FixLocationAssignment`. Add `rollbackFor = BusinessException.class` to `delete(Long)` → `UnexpectedRollbackException` |
| AC-4 | `recalcForItem_vsUserDelete_doesNotAlignToDeletedFla` | Null-destination PROCESSABLE order + F. A runs `recalculateForItem`, parked on `fixLocationAssignmentRepository.findByItemdataIdIn` (in `buildRecalcContext`, before the outer lock). B runs `deleteByUser` and commits; release A → the destination stays null | `destination expected null but was <L>` | `alignDestination` reads ctx again → the same message |
| AC-4b | `perOrderRecalc_vsMove_alignsToNewLocation` | The same, via `recalculateOpenOrders` (per-order tx) vs `move` L→L′ → destination = L′ | `expected <L′> but was <L>` | ctx read → the same message |
| AC-4c | `recalcForItem_blockedByHeldFla` | `HeldRowLockRace` holds F. Run `recalculateForItem` with a destination-set order → blocked at `for no key update` on `fix_location_assignment` | `expected blocked but recalculateForItem completed` | Delete the outer `lockIdByItemdataId` → the same message |
| AC-4d | `perOrderRecalc_nullDest_blockedByHeldFla` | Held F; drive `recalculateOpenOrders(true)` (`RecalcContext` is private, critic L4) over one null-destination order → blocked at the FLA statement | `expected blocked but recalculateOpenOrders completed` | Delete the hint lock → the same message |
| AC-4e | `r3_blockedByHeldFla_otherOrdersStillAssigned` | Held F on item 1, held past 3 s; item 1's order id is **pinned below** item 2's, so it is visited first. R3 over both: item 1's tx blocks, 55P03 is caught per order, and item 2 is assigned | `expected blocked but R3 completed` | Delete R3's lock → the same message. Remove the per-order catch → `item-2 destination expected <L2> but was null` |
| AC-5 (guard) | `recalcForItem_vsUserDelete_noDeadlock` | Order B (destination L, lower id) + O (null destination, higher id). A is parked after locking B's SU; B runs `deleteByUser` → both finish, no 40P01/55P03 | **Green before the fix** (no F lock exists, so no cycle). Not in step 2 | Move the outer lock into the loop after the first order → `40P01 deadlock detected` |
| AC-6 | `refillParkedBeforeCreate_vsMove_skips` | A runs the refill, parked on `stockunitRepository.findByUnitloadId` in `refillSingleFixedLocation` (before C0). B's `move` L→L′ commits; release A → A returns null, 0 orders to L | `orders to old location expected 0 but was 1` | Lock by item only (drop the location predicate) → the same message |
| AC-7 | `ReplenishOrderJobUnitTest#deleteSubOp_pessimisticLockFailure_continuesRun`, `#deleteSubOp_unexpectedRollback_continuesRun`, `#fixedAssignmentSubOp_pessimisticLockFailure_continuesRun`, `#r3_pessimisticLockFailure_continuesRun` | The sub-op throws → the next sub-op still runs | `wanted but not invoked: <next sub-op>` | Remove each new catch arm → the same message |
| AC-8 (rail) | `FunctionGuardArchTest#fixLocationAssignmentRepository_shouldStillExportItsSiblingSearches`, `#replenishorderRepository_sbdev4031FindersAreUnexported` | The pins list the 4 and the 3 names | Green after step 1; not in step 2 | Drop one `exported = false` → the diff names it |
| AC-8b (rail) | `FixLocationAssignmentLockCallSiteArchTest#flaLockFinders_onlyFromAllowedMethods`, `#mobileReplenishService_fulfillMultipleUnitLoads_isNotTransactional` | ArchUnit `accessTargetWhere` (covers method references), **method-level** allowlist (architect N3): the 4 FLA lock finders are reached only from the methods Fixes B–F edit (`deleteByUser`, `delete`, `move`, `calculateOrder`, `recalculateOrder`, `recalculateForItem`, `assignFixedDestination`). So `createFixedLocationAssignment` / `createOrderFromTemplate`, which confirm reaches inside `fulfillMultipleUnitLoadsTx`, stay fenced. `fulfillMultipleUnitLoads` has no `@Transactional`, and `MobileReplenishService` has none at class level (critic L3). Positive control: after step 5, each allowed method has at least one call (critic N1) | Green after step 1 (no calls yet); not in step 2 | Add `lockIdByItemdataId` (or a method reference) in `assignDestinationForMultiUnitLoads` or `createFixedLocationAssignment` → a violation naming it. Annotate `fulfillMultipleUnitLoads` or the class → red |
| AC-9 | `FixLocationAssignmentControllerIT#delete_whileFlaHeld_blocksAtFlaLockAndReturns409` | Holder (§8.1) holds F for more than 3 s. Seed the FLA's UL in Nirvana (the UL FK is NOT NULL, critic L5), which gives `Removal(null, null)`, and no orders. DELETE `/v3/fixedAssignment/delete/{id}` → `confirmedBlockedStatement` contains `for no key update`, then 409 "Resource Locked" with `retryable: true` | `blocked statement expected to contain "for no key update" but was "delete from fix_location_assignment …"` | Revert D1 to `findById` → the same message |
| AC-10 | `FixLocationAssignmentMoveIT#move_repointsProcessableOrdersToNewLocation` | PROCESSABLE order to L, reservation R on SU S → `move(L→L′)` → destination L′, `stockunitId` S and reserved R unchanged; a follow-up `fulfillMultipleUnitLoads` scanning L′ succeeds | `destination expected <L′> but was <L>` | Delete step 7 → the same message |
| AC-10b | `FixLocationAssignmentMoveIT#move_refusesWhenAnOrderAlreadyTargetsDestination` | Open orders for the item to **both** L and L′ → BusinessException "already targets the destination"; nothing written | `expected BusinessException ("already targets the destination") but nothing was thrown` | Remove the guard → `DataIntegrityViolationException` on `idx_replenishorder_active_item_dest` |
| AC-10c (guard) | `FixLocationAssignmentMoveIT#move_vsTransferOfSourcePallet_noDeadlock` | One pick order with lines on the flowbin SU and on O's source pallet S. A runs `move`, parked on `unitloadRepository.findByStoragelocationId` **matched on the old location id** (critic N4; exists pre- and post-fix; post-fix it runs after F/P/L′/O). Step 2 obtains the unit load via `getReferenceById` (Fix F), so it does not hit this spy. B runs a `CODE_TRANSFER` of S to a non-replenishable location; release → both finish, no 40P01 | **Green before the fix** (today's move locks no order). Not in step 2 | Move step 2 after step 5 (r1's F → O → P) → `40P01 deadlock detected` |
| AC-11 | `moveHoldingFla_vsRefill_createsNothingAtOldLocation` | A runs `move`, parked on `unitloadRepository.findByStoragelocationId` (destination check; post-fix it runs after F/P/L′). B runs a refill for (item, L) → assert B is blocked; release → B returns null, 0 orders to L | `B blocked by A's pid: expected true but B completed` (then `orders to old location expected 0 but was 1`) | Lock by item only in C0 → `orders to old location expected 0 but was 1` |

### 8.3 Regression: tests that change, and how

**Rule:** the new finders return Mockito's default `Optional.empty()`, so existing unit tests must **re-stub them** (e.g. `when(fixLocationAssignmentRepository.findByIdForUpdate(1L)).thenReturn(Optional.of(fla))`), replacing the old `findById` / `getActive` stubs. **Never weaken, delete or loosen an assertion to get green.** A test that cannot keep its assertion is a finding for review.

| Test | Change |
|---|---|
| `FixLocationAssignmentServiceUnitTest` | Only the ≤35 `fixLocationAssignmentRepository.findById` stubs on delete/move paths → `findByIdForUpdate` (critic L1; other repositories' `findById` stubs are untouched). ~15 `getActive` stubs on move → the new projections. ~9 `delete(1L)` cases re-stubbed. Add `lockOwningPickingorders` / `lockById` / `getReferenceById` verifies on move |
| `FixLocationAssignmentUserDeleteContractUnitTest` | `findById` → `findByIdForUpdate` |
| `ReplenishGeneratorServiceUnitTest` | 13–15 automatic/refill tests stub `lockIdByItemdataIdAndLocation` → `Optional.of(id)`. Plus a new `calculateOrder_automatic_flaGone_returnsNullAndInsertsNothing` |
| `ReplenishmentOrderMaintenanceServiceUnitTest` | 6 ctx-based alignment stubs → `findItemdataIdByIdAndDestinationIdIsNull` + `findActiveLocationIdByItemdataId`. Plus a new `alignDestination_flaGoneUnderLock_nullsAssignment` |
| `ReplenishorderServiceUnitTest` (R3 nested) | Rewritten to the id loop through `self` |
| `ReplenishOrderJobServiceUnitTest` | No pre-read; R3 wrapper not transactional |
| `FixLocationAssignmentServiceIT` | **Run it first, after Fix B/F; reseed only if it goes red.** `LockReadRail`'s javadoc says rows seeded through the shared context sit at WRITE and are not reported, so the 4 same-tx call sites (`move` ×3, `delete` ×1) may stay green as they are. If it goes red: reseed through a committed `TransactionTemplate(tenantTransactionManager)` with the test at `Propagation.NOT_SUPPORTED` (the `adjust_flipsFlagOnRealPg` / AdjustCommitted pattern), and, because `delete(Long)` is MANDATORY, run the `delete` call itself inside a **second** committed `TransactionTemplate` (architect N4) |
| `ManualCutCooldownEndToEndIT`, `DeleteContainerWithStockIT` | Seed a real FLA for any automatic create with a destination, or the C0 skip makes them assert on nothing |
| Kept green, unchanged | `FixLocationAssignmentDeleteByUserIT`, `ReplenishDupConcurrencySliceIT`, `LockReadRailIT`, `ReplenishmentMaintenanceCallSiteArchTest` |

### 8.4 Manual test plan (DEV, `dev_wh01_om1`, wms-dev-probe)

| Scenario | Environment | Precondition query → dev count | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| User delete cancels the bound order | dev | `SELECT count(*) FROM replenishorder r JOIN fix_location_assignment f ON f.itemdata_id=r.itemdata_id AND f.assignedlocation_id=r.destination_id WHERE r.state<=300;` → **469** (2026-11-06) | DELETE `/v3/fixedAssignment/delete/{id}` as a System user with MANAGE_REPLENISHMENT_ORDER | Order at ~~700~~ **800** (CANCELED; markCancelled), FLA gone, SU reservation released | ✅ 2026-11-07, seeded (see §12) |
| Move re-points | dev | Same query → **469**, plus an empty flowbin: `SELECT count(*) FROM location l JOIN location_type t ON t.id=l.type_id WHERE lower(t.sltname)='flowbin' AND NOT EXISTS (SELECT 1 FROM fix_location_assignment f WHERE f.assignedlocation_id=l.id) AND NOT EXISTS (SELECT 1 FROM unitload u WHERE u.storagelocation_id=l.id);` → **723** (DEV spells it `flowbin`; `='FLOWBIN'` returned a false 0; positive control: 1344 flowbins hold an FLA) | Move FLA L→L′ | Order destination = L′, same `stockunit_id`/reserved | ✅ 2026-11-07, real FLA, moved and moved back |
| No new orphans after a cron tick | dev DB | `SELECT count(*) FROM replenishorder r WHERE r.state<700 AND r.destination_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fix_location_assignment f WHERE f.itemdata_id=r.itemdata_id AND f.assignedlocation_id=r.destination_id);` → **2** (2026-11-06; matches the analysis) | Wait one cron minute after the two scenarios | Count unchanged | ✅ 2 → 2 (cron on; no DB trace of a tick) |

If a count is 0, seed with out-of-band ids and prove the restore with `snapshot.sh`.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| **User-visible, move:** (a) the new refusal *"ReplenishmentOrder=X already targets the destination!"* comes back on the existing HTTP 200 + `errors[0].message` path; (b) in-flight PROCESSABLE orders now follow the FLA to L′ (an operator who loaded the order earlier sees the new destination on reload); (c) up to 3 s wait, or 409 | (a) and (b) are intended and stated in the release note. (c): see the next row |
| **UI shows a 409 as a generic error.** `wms2-web-ui` `store/masterData/fixedLocation.js` sends any non-2xx response from delete or move to its catch, which shows "Error deleting <loc>" / "Error moving from X to Y", not "locked, retry". Business refusals use the 200 + `errors[0].message` path | Accepted for this ticket: the 409 needs F held for more than 3 s, and the creator and recalc hold it for milliseconds. Follow-up T1 proposal **P71**: map `retryable: true` to a "busy, retry" toast in `fixedLocation.js` |
| `move` blocks pickers on the flowbin even when it refuses (P and L′ are taken before the checks) | Same duration as today's transfer phase; required for ABBA-10b (§4.2) |
| A later reader mistakes the pre-lock hint for a SBDEV-3244 regression | Comment at the site; the hint is scalar; `LockReadRail` still guards entities |
| R3 stops assigning inactive FLAs and drops the location existence check | Matches `alignDestination`; the FK guarantees existence |
| Archunit freeze store drift | Refreshed in the same commit (precedent 1c94c64) |
| `MANDATORY` surprises a future non-tx caller | It fails fast with `IllegalTransactionStateException`, which is the intent |

---

## 7. Horizontal scalability

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | No | Row locks only |
| 2 | Pool math | No / improves | C0's lock lives in the inserting REQUIRES_NEW. R3 drops its outer REQUIRES_NEW, so the suspended transaction never holds a second connection |
| 3 | Scheduled jobs | No new job | The cron stays serialized per tenant by `advisoryLockService.tryLock(REPLENISH_ORDER, tenantId)`; row locks cover cron × interactive across replicas |
| 4 | Long transactions | Slightly longer worst case | ≤ 3 s wait behind F (`lock-timeout-ms`). R3 gets shorter: one order per tx |
| 5 | Request affinity | N/A | Stateless |
| 6 | Retry / idempotency | Yes, satisfied | The C0 skip is a null return and the next tick recomputes; a 409 is retryable; R3 is idempotent per order |
| 7 | Tenant context | No | No async boundary added; the R3 self-proxy runs on the cron thread |
| 8 | Distributed lock correctness | **Yes, the point of the change** | DB row locks inside `tenantTransactionManager` transactions; `delete(Long)` is MANDATORY |
| 9 | Cache invalidation | No | FLA and Replenishorder are not cached on these paths |
| 10 | External notifications | No | None added |

### v2-only constraint checklist (wms-bugfix-plan rows 1–8)

| # | Constraint | Verdict | Citation |
|---|---|---|---|
| 1 | OSIV disabled | Yes, handled | Every lock and every write runs inside a tenant transaction. R3's id list (`findIdsByStateLessThanEqualAndDestinationIdIsNullOrderById`) runs outside one, by design (Fix E), but it is a scalar projection with no lazy association (critic L6) |
| 2 | Transaction manager | Yes | New: `delete(Long)` `tenantTransactionManager` MANDATORY (no `rollbackFor`, a deliberate deviation, Fix B); `assignFixedDestination` `tenantTransactionManager` REQUIRES_NEW with `rollbackFor = {BusinessException, FacadeException}` (Fix E) |
| 3 | `readOnly = true` | No | No new read-only service method; the new reads are repository finders inside write transactions |
| 4 | Caffeine cache invalidation | No | `FixLocationAssignment` and `Replenishorder` are not `@Cacheable` on these paths (`wms2-caching-strategy.md`) |
| 5 | Jakarta namespace | Yes | New `@Lock` imports `jakarta.persistence.LockModeType`, as `LocationRepository.lockById` does |
| 6 | H2-compatible test SQL | Yes | All new finders are JPQL, and the dialect renders the lock clause (`FOR UPDATE` on H2). Lock assertions live only in Testcontainers ITs (§8.2) |
| 7 | Controller test | Yes | No endpoint changes, but the 409 contract is asserted in NEW `FixLocationAssignmentControllerIT` (AC-9) |
| 8 | Micrometer metrics | No | Replenishment is a hot path, but the new outcomes are rare skips; INFO `SBDEV-4031:` tokens only. The metric-grade detector is P70 |

### Completeness checklist (wms-bugfix-plan rows 0–10)

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1 (PRD orphan=1/bound=561/open=584, REPL062709); `db_verified: true`; DEV preconditions in §8.4 |
| 1 | All call sites enumerated | ✓ §0 by the named greps; every row has a Fix or an OUT rationale |
| 2 | Adjacent bugs | ✓ R3 (same write), F1 move staleness (folded in), C5/C6 → P69, F3 → P70, `changeActive` → P52 |
| 3 | Backward compatibility | ✓ §9: new move refusal on the existing 200 path; re-pointing; 409 is the existing `RestExceptionHandler` mapping; no schema or payload change |
| 4 | Concurrency | ✓ §4.1 matrix, §4.2 verdicts incl. 10b, AC-1…AC-11 |
| 5 | Multi-tenant | ✓ Row locks run on the tenant datasource; the advisory per-tenant cron is unchanged (§7 row 3) |
| 6 | Error handling | ✓ D3 catches (incl. the final `Exception` at the delete sub-op), the R3 per-order catch, the 409 mapping, the C0 null contract |
| 7 | Observability | ✓ INFO `SBDEV-4031:` tokens for skip and re-point; P70 for the detector |
| 8 | Rollback / migration | ✓ No Flyway or sysprop; reverting the code is safe (§6.1) |
| 9 | Test coverage | ✓ §8.2 named methods with pre-fix and mutation reds; §8.3 regression list; §8.4 manual |
| 10 | Cross-version (v1↔v2) | no: v1 is reference-only with no client since 2026-10-02; v2 is the only target |

**Verify script: NONE.** Every invariant is behavioural (the two-thread ITs) or structural and pinned in ArchUnit (AC-8, AC-8b).

---

## 10. Decisions

**Resolved (Nam, 2026-11-06):** T3 confirmed · **Q1** `move()` folded in (F → P → L′ → O, re-point; Fix F) · **Q2** operator creates (C5/C6) OUT → **P69** · **Q3** R3 lock-fix and keep, now one tx per order (Fix E) · **Q4** PRD REPL062709 left as-is · **F3** detector OUT → **P70** · **P52** `delete(Long)` half closed here (MANDATORY, no `rollbackFor`); the `changeActive` half stays in P52.

**Planner decisions (r2):** widen the delete sub-op catch with a final `catch (Exception e)` (architect F9: yes) · R3 gets per-order REQUIRES_NEW through a self-proxy **and** the defence-in-depth job catch · the outer `recalculateForItem` lock sits after `buildRecalcContext` · AC-5 and AC-10c are regression guards, proven by mutation only.

**Open:** **P71** (proposed, not filed): `wms2-web-ui` `fixedLocation.js` maps a `retryable: true` 409 to a "busy, retry" toast. T1, UI only; rank it after P69.

### ADR
- **Decision:** the FixLocationAssignment row is the lock object for "where does this item's replenishment go". Every **automatic** create and every align, re-point and delete against it locks it first (operator creates C5/C6 are not covered: P69): the entity lock where it is the first touch, the scalar lock where the tx may already hold the entity. Order: F → P (move) → location → orders ascending → SU. Confirm never locks F.
- **Drivers:** (1) kill the write skew behind PRD REPL062709; (2) add no deadlock edge (confirm, BLOCK_REALIGN transfers); (3) the smallest change at the choke points.
- **Alternatives:** the §5 *Rejected alternatives* table, including the split option.
- **Why chosen:** the FLA row has no existing lock edges and is unique per item and per location; under READ COMMITTED a waiting lock sees a moved or deleted row as empty, so callers get "gone" for free.
- **Consequences:** user delete/move can wait ≤ 3 s or get a 409, which the UI shows as a generic error (P71) · move refuses one new case and re-points in-flight orders · a move refused by an L′-dependent check briefly blocks pickers on the flowbin (lock-free refusals run first since fd1a5378) · a stale recalc hint skips alignment for one pass (§10.z) · recalc does one extra scalar PK lookup per order · R3 runs one tx per order, skips inactive FLAs and drops its location check.
- **Follow-ups:** P69 (operator creates) · P70 (stale-destination detector) · P71 (UI 409 toast) · P52 (`changeActive` half) · F2 and F5 done on this ticket (§6.2 step 6).

---

### 10.x Amendment A1 — SBDEV-4044 merged under this plan (2026-11-06, executor preflight)

`origin/develop` moved d6424491 → 8507785d (PR #633, SBDEV-4044). `deleteByUser` now **detaches** one order (`order.setDestinationId(null)`) instead of cancelling it when open picks wait and no no-destination order exists. That **breaks §4.2's monotonicity premise** ("a destination only goes null → non-null").

What changes:
- **Lock order:** no new edge. `detach` runs inside `deleteByUser` after the FLA lock and the order lock (F → O), so it is already ordered. ~~Nothing deadlocks against it: recalc holding a null-destination order is not among the orders `deleteByUser` locks (ABBA-1 still holds).~~ (Wrong for a late O → F lock; see §10.z.)
- **The `recalculateOrder` pre-lock hint can now be stale** (non-null before the lock, null under it).
- ~~**Rule, in place of the premise:**~~ **SUPERSEDED by §10.z (no late F lock; skip align).** `alignDestination` runs only with the item's FLA locked. If the hint skipped the pre-lock and the order's destination is null under the order lock, take `lockIdByItemdataId` *before* aligning. This lock comes after the order lock, which is ABBA-1's order→F direction for a null-destination order, proven cycle-free. The hint stays as an optimisation only.
- **Tests:** ~~add a unit test for the stale-hint branch (lock taken after the order lock when the hint was non-null)~~ superseded by §10.z: the stale-hint tests assert `never()` late lock. AC-1's "no orphan" outcome set gains the case "detached (picks waiting)". The gate seeds no waiting picks, so AC-1 is unchanged.
- **Rebase:** the gate commit was rebased onto 8507785d (now 68d3b7f2).

### 10.y Implementation deltas (2026-11-06, conformance PASS at 85daa64b)
- **AC-10c / AC-10c-bis.** AC-10c parks after every lock `move` takes, so its stated mutation (r1's F → O → P order) **survives** it (I14). AC-10c-bis (`move_parkedOnOrderLock_vsTransferOfSourcePallet_noDeadlock`) parks right after the order lock and kills that mutation with 40P01 (I14b). Both are kept: AC-10c guards the full order, AC-10c-bis kills the r1 mutant.
- **AC-10 clause 4.** A multi-UL confirm at L′ after a move is post-fix evidence only. Mobile confirm overwrites the destination with the scanned location, so it does not guard the re-point. AC-10 and two unit tests do.
- **Fix F step 2.** `UnitloadRepository` has no `getReferenceById`, so `move` uses `unitloadRepository.findById(...).orElse(null)`. `collectStockUnitIdsForUnitloadTree(null)` returns empty, so nothing throws before the refusals. The base code already read the same unit load in plain mode, so there is no new upgrade.
- **A1 placement.** ~~The A1 lock and the post-lock location read live in `recalculateOrder`~~ — superseded by §10.z: there is no late lock; the hint lock and the post-lock location read (`alignDestination`, only when the hint locked F) stay in `recalculateOrder` because AC-8b's allowlist is method-level.
- **F2 dropped from this ticket.** The stale `FixLocationAssignmentRepository` javadoc is fixed. Deleting `refillFixedLocations` would remove the only assertion of `MobileReplenishServiceUnitTest.fulfillMultipleUnitLoads_shouldNotRunWarehouseWideRefill_afterCommit`. It is unrelated to the race; T0 follow-up.
- **Retired R3 entity finder.** This removes the exported SDR search `findByStateLessThanEqualAndDestinationIdIsNull`. A grep found 0 callers in wms2-web-ui, wms2-mobile-ui, oms-laravel-api and siteboss-frontend; the positive control `replenishorder` hit. Blind spot: external or dynamic clients.

### 10.z Amendment A1 revised: code review M1 (Nam, 2026-11-06)
This replaces A1's "take `lockIdByItemdataId` after the order lock".

When the pre-lock hint did not fire (`findItemdataIdByIdAndDestinationIdIsNull` returned empty, so F is not held) and the order's destination is null under the order lock, `recalculateOrder` **does not lock F and does not align**. It treats the assignment as null for this pass. R3 (`assignFixedDestination`, F → O) or the next `recalculateForItem` (F → O) aligns the order later.

Why: an O → F edge conflicts with R3 and `recalculateForItem`, which take F → O on null-destination orders. A1's original justification ("deleteByUser never locks a null-destination order") was wrong. It was safe only because `detach` commits together with the FLA delete.

Consequence: in the stale-hint case alignment is delayed by up to one cron tick. That case only follows a `detach`, which deletes the FLA in the same commit, so it is rare and normally a no-op.

The pre-lock hint is load-bearing, not an optimisation. Removing it would put every null-destination per-order recalc on O → F.

## 11. Round-1 disposition

| Finding | Disposition |
|---|---|
| Critic F1 (High) | Fixed: AC-2/6/11 park on `unitloadRepository.findById` / `stockunitRepository.findByUnitloadId` / `unitloadRepository.findByStoragelocationId`; every row has a pre-fix red message |
| Critic F2, F3, F4 | Fixed: AC-5 is a guard (and AC-10c, by the same reasoning); AC-9 asserts `for no key update` via `confirmedBlockedStatement`, and NEW classes are marked; AC-3 spy is thread-scoped (§8.1); AC-1/11 mutation column = first failing message |
| Critic F5 / Architect F4 | Fixed: §8.3 table + re-stub rule; `FixLocationAssignmentServiceIT` reseed; archunit `delete(Long)` entry |
| Critic F6 / Architect F2 | Fixed: Fix E per-order REQUIRES_NEW + job catch |
| Critic F7, F8, F9, F10, F11 | Fixed: skill rows with verdicts and citations, plus §8.4 columns; exactly 3 order finders, pinned (AC-8); `accessTargetWhere` + `fulfillMultipleUnitLoads` non-tx pin (AC-8b); AC-10b seeds both L and L′; SDR blind spot in §4.2 |
| Critic F12 / Architect F5 | Fixed: advisory-lock rejection restated |
| Critic F13, F14, F15 | Fixed: F2/F5 in §6.2 step 6 and P52 `changeActive` noted; user-visible move changes in §9 and the ADR; base d6424491 and 3 callers by grep |
| Critic ambiguities, cuts, open Qs | Fixed: outer-lock position pinned; R3 drops the location check; all cuts applied; 409 UI → §9 + P71; `resolveUpperBound` → Fix D null assignment; PRD null-destination 21 → frontmatter |
| Architect F1 (High) | Fixed: F → P → L′ → O, AC-10c guard, tension recorded |
| Architect F3, F6, F7, F8, F9, F10 | Fixed: AC-4c/4d/4e; "narrows, not closes"; `FOR NO KEY UPDATE` + Flyway V2.2.00; `alignDestination` null assignment; final catch at the delete sub-op; `ReplenishmentMaintenanceCallSiteArchTest` as the transitive fence |
| Architect steelman (split) | **Declined:** Q1 folded move in, and Race 2 shares the defect. Recorded in the §5 alternatives |

### Round-2 disposition (critic APPROVE; architect: round 1 closed)

| Finding | Disposition |
|---|---|
| Critic N1 | Fixed: AC-8/8b relabelled as rails (green after step 1), dropped from step 2; AC-8b positive control |
| Critic N2 | Fixed: AC-10b pre-fix red = "nothing was thrown"; the DataIntegrityViolation message moved to the mutation column |
| Critic N3 | Fixed: §8.1 holder rule (`bumpUnderLock` or two-latch, pid via `pg_blocking_pids`, sleep > 3000 ms); AC-4e pins item 1's id below item 2's |
| Critic N4 / Architect N2 | Fixed, per the coordinator's split: Fix F step 2 uses `getReferenceById` (architect); AC-10c parks on `findByStoragelocationId` matched on the old location id (critic) |
| Critic L1–L6 | Fixed: ≤35 FLA-repo stubs only; explicit R3 `@Query` and the old entity finder retired; class-level `@Transactional` pin; AC-4d through `recalculateOpenOrders(true)`; AC-9 seeds the UL in Nirvana; ADR scoped to automatic creates, v2 row 1 reworded |
| Critic open Q (LockReadRail) | Fixed: §8.3, run `FixLocationAssignmentServiceIT` after Fix B/F first and reseed only if it goes red |
| Architect N1 | Fixed: Pickingorder pre-walk TOCTOU recorded as a 40P01-resolved residual in §4.2; flowbin SU deliberately not locked early |
| Architect N3 | Fixed: AC-8b allowlist is method-level |
| Architect N4 | Fixed: the second committed `TransactionTemplate` for the MANDATORY `delete` is the reseed instruction in §8.3 |
| Architect N5 | Fixed: Fix E skips (item, location) pairs another open order already targets, at INFO |
| Architect note (log `e` in the :754 catch) | Fixed: Fix B D3 |



## 12. Implementation Status (2026-11-06)

- **Status:** implemented, PR open, **not merged**. PR: https://github.com/SiteBossInc/wms2-api/pull/637 (base `develop`, head `9b3eb0e4`, branch `bugfix/SBDEV-4031-fla-lock`). It has inline reviewer-guide comments.
- **Commits** (base `8507785d`):
  - `68d3b7f2`: TDD gate
  - `bf26670b`: fix
  - `2de75c58`, `c78fe436`, `46a943a3`, `2f45b4dd`: test hardening
  - `33643d5c`, `590352a3`, `063ed2a4`: review r1
  - `be84758e`: review r2
  - `9b3eb0e4`: review r3
- **Tests at `9b3eb0e4`** (`mvn -o clean verify`, `TESTCONTAINERS_REUSE_ENABLE=false`): surefire 9769/0/0/1, failsafe 1221/0/0/23. The develop baseline was 9740/0/0/1.
- **Reviews** (evidence dir):
  - code: `review-code-r1.md`, `-r2.md`, `-r3.md`
  - security: `review-security.md`
  - conformance: `conformance-verifier.md`, `-r2.md`
  - All findings fixed, including Lows. A round-4 lane on `9b3eb0e4` and the doc fixes was in flight at push time.
- **Docs** (`docs-drift.md`): three docs updated with `✓ merged(SBDEV-4031: #637 65444c6b, 2026-11-07)`, namely `wms2-replenishment-design.md`, `wms2-transaction-osiv-boundary-map.md` (§8.5) and `wms2-scheduled-jobs-catalog.md`. The pre-existing lock_timeout default was also corrected to 3000 ms.
- **Merge:** the branch was 51 behind develop at push. The trial merge is clean, and none of those commits touch the 8 changed files.
- **Follow-ups (proposed):** P69, P70, P71, F2 (T0), and P52's `changeActive` half.

### Merge (2026-11-07)
- Preflight: develop moved after the PR check, and develop also changed `NeverMatcherNullBlindnessArchTest` and `TestClassTransactionManagerArchTest`. The PR was re-graded on the current base.
- Merged `origin/develop` (5ed6f000) into the branch as `b931bf89`. There were no conflicts: develop's edits to both arch tests were separate additive SBDEV-4007 entries, and git merged them with no hand resolution.
- Full `mvn -o clean verify` on `b931bf89` (`TESTCONTAINERS_REUSE_ENABLE=false`): surefire 9843/0/0/1, failsafe 1247/0/0/23. The PR check (run 42249117345, `test`) passed on `b931bf89`.
- Merged with `merge-one.sh`, pinned to `b931bf89`. Merge commit **`65444c6b`**.
- `post-merge-verify.sh`: ALL PROVEN. The develop run 42252160655 passed (test and build), and DEV serves `develop-65444c6b`.
- Doc markers were flipped to `✓ merged(SBDEV-4031: #637 65444c6b, 2026-11-07)` in 5 files, plus 1 near-miss by hand.
- Next: ~~the manual DEV scenarios~~ done (below), then `archive-plan`.

### Manual DEV test (2026-11-07, wms-dev-probe, DEV `develop-65444c6b`)
- **Move re-points ✅** (real data): FLA 11431315 (item 6176803) moved 26-B06 → 26-B01 (64557). Order REPL048880 (20296144, state 300) re-pointed to 64557, with the same source SU 750311452 and requested/reserved 12/12. Moved back to 26-B06: the order re-pointed back. `snapshot.sh diff t4031-move` → **restored** (FLA, UL 11431505 incl. label, both SUs, order, destination).
- **User delete cancels the bound order ✅** (seeded): reservation 0→3 on SU 987376485 (item 8878753, 24-YE04), plus FLA 9900004031 (inactive, on 26-B03, pointing at Nirvana UL 988306630 so that nothing moves) and order 9900004031 `REPL-T4031-A` (state 300, destination 64559). `DELETE /v3/fixedAssignment/delete/9900004031` → DELETED. Order at **800** (the plan's "700" was wrong: `markCancelled` sets CANCELED), FLA gone, reserved 3→0. Seed order removed. `snapshot.sh diff t4031-del`: every business field restored. Only the SU `version` changed (1→2), from the product's own reservation release.
- **No new orphans ✅**: 2 → 2 at 23:52:48Z; bound open 469 → 469. Caveat: `NEW_CRON_JOB_ACTIVATED=true`, but dev has created no replenishment order since 2026-10-22, so no DB row proves a tick reached these items.
- Side effects left on dev: stockrecord 31611107 (MOVE_FIX_ASSIGNMENT 26-B06→26-B01), the move-back's MOVE_FIX_ASSIGNMENT row, 31611108 (REPLENISHMENT_CANCELLED REPL-T4031-A, −3 reserved); version/modified bumps on the touched rows. No `message` rows (nothing sent to OMS).
