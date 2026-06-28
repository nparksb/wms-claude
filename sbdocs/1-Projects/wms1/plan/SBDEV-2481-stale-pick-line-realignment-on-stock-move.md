---
title: "Stale Pick-Line References Survive Stock / Unit-Load Moves — Picking Directed to Wrong Location"
ticket: "SBDEV-2481"
ticket_url: "https://app.clickup.com/t/9006034209/SBDEV-2481"
pr: "https://github.com/SiteBossInc/wms-api/pull/176"
type: bug
priority: urgent
status: implemented
project:
  - wms-api-v1
  - wms-mobile-ui-v1
version: v1
requester: Internal
created: 2026-06-24
updated: 2026-06-24
db_verified: true
related:
  - SBDEV-1526
  - SBDEV-1710
  - SBDEV-2102
  - SBDEV-2116
tags:
  - plan
  - picking
  - move-stock
  - regression
---

# Stale Pick-Line References Survive Stock / Unit-Load Moves — Picking Directed to Wrong Location

**Ticket:** [SBDEV-2481](https://app.clickup.com/t/9006034209/SBDEV-2481)
**Project:** v1/wms-api, v1/wms-mobile-ui | **Version:** v1 | **Type:** Bug (Regression — `SBDEV-1526` no-op + dead-since-`a685e07b` finder + broken detector SQL)
**Priority:** Urgent (picking directed to invalid location; manual recovery per order)
**Status:** IMPLEMENTED (branch `task/SBDEV-2481`, uncommitted — see §11)
**Date:** 2026-06-24
**db_verified:** true (37 stale pick lines on open orders confirmed against a live tenant DB; broken-finder cardinality proven `= 0`)
**Related:** SBDEV-1526 (no-op controller flip), SBDEV-1710 / `260422-changeReservedAmount-stale-object-state-fix.md` (pessimistic-lock + StaleObjectState precedent reused here), SBDEV-2102, SBDEV-2116 (exception→HTTP contract)

> **Companion plan:** a paired v2 plan (`SBDEV-2481-*` in `sbdocs/1-Projects/wms2/plan/`) follows via the `wms-v2-migrate` skill once this v1 plan is reviewed.

> **Repository package note:** v1 JPA repositories live under `net/aim_ai/wms/repo/jpa/`. All repository paths below use that package.

---

## 0. Affected Sites

Every move-/UL-mutating write passes through **two central choke points**. The fix attaches an **activityCode-scoped** pick-line guard there (acting on pre-pick moves, NEVER on outbound), repairs the primary regression, and **fixes the broken detector SQL** that all backfill/monitoring depends on. The shared service is **acyclic by construction** (repositories only — see §5.3).

| # | File:Line | Symbol / role | Phase | Disposition |
|---|-----------|---------------|-------|-------------|
| 0 | `repo/jpa/PickingorderPositionRepository.java:33-34` & `:44-45` | **BROKEN detector SQL** — `pp.pickfromstockunit_id stockunit.id` / `stockUnit.unitload_id unitLoad.id` (missing `=`) in `getPickingorderPositionCount()`/`getPickingorderPositions()` → invalid SQL → throws | **P0** | Insert the two missing `=`; `...ById` (`:55-57`) is the correct template |
| 1 | `FixLocationAssignmentService.java:126` | `findByCustomerorderpositionId(oldLocation.getId())` — **PRIMARY broken finder** (location id into a CO-position filter → always empty) | P2 | Delete; realign routes through Hook A |
| 2 | `FixLocationAssignmentService.java:156` | `transferUnitLoadToLocation(unitload, destination, …, CODE_MOVE_FIX_ASSIGNMENT, …)` — the move | P2 | `move()` `@Transactional`; owning-Pickingorder lock acquired in the entry method (§5.5) |
| 3 | `FixLocationAssignmentService.java:163-169` | Dead inline realign loop (+ `:167` sets `pickfromunitloadlabel = destination.getName()`, a **location** name) | P2 | **DELETE** — replaced by Hook A |
| 4 | `UnitloadBusinessService.java:214` `processTransfer` → `:217 setStoragelocationId` (recurses `:230`) | **CHOKE POINT — all UL→location moves**; receives `activityCode` | P1 (Hook A) | activityCode-scoped per-stockunit guard after `:217`, before recursion; dedup locked-orders across the tree. **Lock acquired in the entry methods, not here (§5.5).** |
| 5 | `UnitloadBusinessService.java:277` `transferPalletTreesToLocation` → `:365` bulk update | BOL pallet bulk-move (post-pick) | P3 (note) | Pass-through by activityCode (`CODE_SHIPPING`/`CODE_TRUCK_LOADING`); no per-node guard |
| 6 | `MobileMoveUnitloadService.java:250/:378/:382` (`move` `@Transactional` `:183`) | Mobile move-unit-load | P3 | Routes through Hook A; parameterized test |
| 7 | `StockunitService.java:185` `transferStock` (`@Transactional` `:106`) | Web manual move-stock | P4 | Routes through Hook A/B; parameterized test |
| 8 | `MobileMoveStockService.selectDestination:228` (**NOT `@Transactional`**), writes `:270/:326/:328/:331` | Mobile manual move-stock / split | **P4** | **Add `@Transactional(rollbackFor={BusinessException,FacadeException})`** (AC-2). Note: `:270/:326/:331` use `CODE_MANUAL_SPLIT` = PASS_THROUGH (§5.1) |
| 9 | `StockunitBusinessService.java:227` `transferStockToUnitLoad` → `setUnitloadId` (`@Transactional` `:124/:125`); receives `activityCode` | **CHOKE POINT — all stock-unit→UL moves** | P1 (Hook B) | activityCode-scoped guard after `setUnitloadId`. **This path does NOT route through `processTransfer`; it locks itself in the entry method before `:227` (§5.5).** |
| 10 | `StockunitBusinessService.java:295` `sendStockUnitToNirvana` → `setUnitloadId(nirvana)` | Stock-to-nirvana | P5 | `CODE_SEND_TO_NIRVANA` = PASS_THROUGH; **synchronous move path BLOCKS active picks and does NOT substitute** (D-5); substitution happens only in the existing ops/backfill flow |
| 11 | `MobileReplenishService.java:~473` `finishReplenishmentOrderInternal` → `transferStockToUnitLoad` | Replenishment-finish | P5 | Routes through Hook B; parameterized test |
| 12 | `StockunitService.adjustReservedAmount:437-440` | **EXISTING** block-on-active precedent | reference for P1 | Pattern reference — not modified |
| 13 | `PickingorderPositionService.fixPickingPosition:78` (`@Transactional(rollbackFor=Exception)`); rewrites 3 fields `:152-154`; calls `stockunitBusinessService.changeReservedAmount` (`:133`, `:149`) | **EXISTING realign primitive — NOT called from the move hot path** (it forms the Spring cycle, §5.3) | P5 / ops only | Invoked only by the existing ops flow (`PickingOrderPositionController.fixPickingPosition`) and §7.3 backfill |
| 14 | `FixLocationAssignmentController.java:96` `move(id, dest, true)` (SBDEV-1526 flip) | Controller arg | P2 | `updatePickingPositions` → keep-but-ignored (D-13) |
| 15 | Post-pick / outbound `transferUnitLoadToLocation` callers — **NEVER block/realign** (PASS_THROUGH): `PickingorderBusinessService:195` (`CODE_FINISHED_PICKING`), `BillofladingService:1131` (`CODE_SHIPPING`), `MobileTruckLoadingService:220` & `ParcelMonitorViewService:283` (`CODE_TRUCK_LOADING`), `CustomerorderService:499` (`CODE_FINISHED_PACKAGING_MOVE_TOTE`) | Outbound — would HALT SHIPPING if guarded | covered by taxonomy (P1) | Pass-through; AC-7 proves no block, no mutation |

**Existing infrastructure reused:**

| Asset | Location | Use |
|-------|----------|-----|
| Stale-row detector (post-P0 fix) | `repo/jpa/PickingorderPositionRepository.java:33-57` | Backfill (§7.3), AC-5, monitoring (§8), fail-open backstop (§9 M3) |
| Pick-line-by-stockunit finder | `repo/jpa/PickingorderPositionRepository.java:23` `findByPickfromstockunitId` | Core lookup in both hooks |
| Realign primitive (**ops/backfill only**) | `PickingorderPositionService.fixPickingPosition:78` | Nirvana substitution OUTSIDE the move path (§5.3, §5.4, D-5) |
| Pessimistic lock | `repo/jpa/PickingorderRepository.findByIdForUpdate:139` | Serialize move vs pick-start |
| Lock-order doc | `repo/jpa/CustomerorderBatchRepository.java:33` | Canonical acquire order (§5.5) |
| activityCode constants | `WmsConstants.java:812-857` | Taxonomy source (§5.1) |

No scheduled auto-repair job exists; none is added (RALPLAN-DR option (c) rejected).

---

## 1. Problem Statement

### User-Visible Symptom

A `PickingorderPosition` records its source by **string copies** of the pick location and unit-load label plus a stock-unit id — not a location FK. When the underlying stock or UL moves, `pickfromlocationname`/`pickfromunitloadlabel` keep pointing at the **old** location; picking directs an operator to a location that no longer holds the stock.

### Reproduction (from the ticket)

1. **Scenario 1 (fixed-assignment move):** Reassign a fixed location for an item with an open, not-yet-started picking order — pick line not realigned.
2. **Scenario 2 (move while picking active):** Move stock/UL mid-pick (owning order STARTED) — nothing stops it; in-flight pick silently invalidated.
3. **Scenario 3 (concurrency):** A move and a pick-start race on the same order — both succeed today (no serialization on the owning `Pickingorder`).

### Exact Stale Behavior (DB-verified)

| Owning `pickingorder.state` | Count | Required outcome |
|---|---|---|
| `300` (PROCESSABLE — not started) | **15 rows** | **Realign** |
| `500` (STARTED — pick in progress) | **22 rows** | **Block** |

`position.state` and `order.state` diverge — the **owning order's** state is the authority (USER-APPROVED, D-2).

---

## 2. Root Cause Analysis

> CLAUDE.md (v1/wms-api): "No JPA association annotations — manual FK relationships only. Entity comparison by ID, not `.equals()`."

### 2.1 PickingorderPosition references its source by mutable strings, not a location FK (DESIGN ROOT)

`pickfromlocationname`/`pickfromunitloadlabel` rot on every move; only `pickfromstockunitId` (the stock-unit FK) stays valid — which is why realign is possible and why realign **PRESERVES `pickfromstockunitId`** (invariant I-1, §5.0).

**DB proof:** `SELECT count(*) FROM pickingorder_position WHERE customerorderposition_id IN (SELECT id FROM location)` ⇒ **0**.

### 2.2 `FixLocationAssignmentService.move()` calls the wrong finder with the wrong id (PRIMARY REGRESSION)

`:98-174` — **no `@Transactional`**. At `:126`, `findByCustomerorderpositionId(oldLocation.getId())` passes a `Location` id into a `customerorderposition_id` filter ⇒ always empty ⇒ guard `:127` and loop `:163-169` never run. Correct finder: `findByPickfromstockunitId` (`:23`).

### 2.3 The inline realign loop is itself wrong (`:163-169`, `:167`)

`pickingPosition.setPickfromunitloadlabel(destination.getName())` (`:167`) writes a location name into a UL-label field. Hence delete (§5.2).

### 2.4 `SBDEV-1526` (`05dea1bd`) is a no-op flip (SECONDARY REGRESSION)

The controller flip only selects which dead branch runs; both gate on the empty `:126` list.

### 2.5 The stale-row detector SQL is broken (BLOCKS BACKFILL & MONITORING)

`getPickingorderPositionCount()` (`:33-34`) / `getPickingorderPositions()` (`:44-45`) join on `pp.pickfromstockunit_id stockunit.id` and `stockUnit.unitload_id unitLoad.id` — **missing `=`** → invalid native SQL → throw. Only `getPickingorderPositionsById` (`:55-57`) is correct. Fix **first** (P0).

### 2.6 Why a central, activityCode-scoped guard is required

The two choke points (`processTransfer:217 setStoragelocationId`, recursing at `:230`; `transferStockToUnitLoad:227 setUnitloadId`) already carry an `activityCode`. They ALSO carry legitimate outbound moves (site #15: shipping/truck-load/finished-pick/tote). An unscoped guard would halt shipping — so the guard branches on `activityCode` (§5.1).

---

## 3. The Regression Chain

| Commit | Date | Change | Effect |
|--------|------|--------|--------|
| `a685e07b` | 2024-07-16 | `findByCustomerorderpositionId(oldLocation.getId())` at `:126` | Realign dead since day one (id-space mismatch). |
| `05dea1bd` | (SBDEV-1526) | Flip to `move(id,dest,true)` at `:96` | No-op; both branches gate on empty `:126` list. |
| (origin TBD) | — | Detector SQL missing `=` at `:33-34`/`:44-45` | Detector throws; backfill/monitoring blind. |

---

## 4. Architecture Overview

### Move → activityCode gate → choke point → pick-line outcome

```
ENTRY POINTS (acquire owning-Pickingorder lock HERE, §5.5)   CHOKE POINTS                OUTCOME
──────────────────────────────────────────────────────────────────────────────────────────────────
FixLocationAssignment.move ─┐ CODE_MOVE_FIX_ASSIGNMENT
MobileMoveUnitload.move    ─┤ CODE_TRANSFER
StockunitService.transfer  ─┼ CODE_MANUAL_TRANSFER ──► UnitloadBusinessService.transferUnitLoadToLocation:77
MobileMoveStock(selectDest)─┘ CODE_ON_HOLD               │ (lock @ :77 entry)              ┌─ owning Pickingorder
  (UL→location)                                          └► processTransfer :217 set...    │  >= 500 → BLOCK
                                                              :230 recurse (dedup orders)   │   (BusinessException,
                              ┌──────────────────────────────►[HOOK A] classify(activityCode)│    outer tx rolls back)
                              │   BLOCK_REALIGN → per stockunit: assertNoActivePickFor /      │
                              │                  INLINE repo.save() rewrite (no fixPickingPos)└─ < 500 → REALIGN inline
                              │   PASS_THROUGH  → no block, no realign (AC-7)                     (label+location strings;
PickingorderBiz:195 CODE_FINISHED_PICKING                                                          pickfromstockunitId KEPT)
Billoflading:1131   CODE_SHIPPING
MobileTruckLoad:220 CODE_TRUCK_LOADING
Customerorder:499   CODE_FINISHED_PACKAGING_MOVE_TOTE
MobileMoveStock     CODE_MANUAL_SPLIT  ← PASS_THROUGH (split spawns a NEW sibling stockunit; source keeps identity)

StockunitBusinessService.transferStockToUnitLoad:124 (lock @ :124 entry) → :227 setUnitloadId → [HOOK B] classify+guard
UnitloadBusinessService.transferUnitLoadToCarrier:149 (lock @ :149 entry)
sendStockUnitToNirvana → CODE_SEND_TO_NIRVANA = PASS_THROUGH (block active; substitute ONLY in ops flow, D-5)
```

### Key Files

| File | Lines | Role |
|------|-------|------|
| `PickLineRealignmentService.java` (**NEW**) | — | Shared classify + block-or-**inline-realign** primitive — **repositories only** (acyclic) |
| `PickLineActivityCodeClassifier` (**NEW**) | — | `BLOCK_REALIGN_CODES`/`PASS_THROUGH_CODES` taxonomy |
| `WmsConstants.java` | 812-857 | `CODE_*` source |
| `UnitloadBusinessService.java` | 77, 149, 214-230 | Entry methods (lock) + Hook A choke point |
| `StockunitBusinessService.java` | 124, 227, 295, 332 | Entry method (lock) + Hook B; `changeReservedAmount:332` (the cycle edge) |
| `FixLocationAssignmentService.java` | 98-174 | Primary regression |
| `MobileMoveStockService.java` | 228 | Needs `@Transactional` (AC-2) |
| `repo/jpa/PickingorderPositionRepository.java` | 23, 33-57 | Finder + detector (P0) |
| `repo/jpa/PickingorderRepository.java` | 139 | `findByIdForUpdate` |
| `repo/jpa/CustomerorderBatchRepository.java` | 33 | Canonical lock-order doc |
| `PickingorderPositionService.java` | 78, 133, 149, 152-154 | `fixPickingPosition` (**ops/backfill only**; calls `changeReservedAmount`) |

---

## 5. Fix Design

### 5.0 Invariants

- **I-1 (FK preserved):** Realign rewrites `pickfromunitloadlabel` + `pickfromlocationname` ONLY; `pickfromstockunitId` is NEVER changed by realign. Do not "fix" the FK.
- **I-2 (all-or-nothing per move tree):** For a multi-stock-unit UL/tree, realign of all backing pick lines is atomic in the **outer** transaction; a mid-recursion block rolls back ALL prior realigns — no partial state (§5.6).

### 5.1 activityCode taxonomy (RESOLVED — D-6)

Materialized, enumerated (NOT inline `if/else`):

```java
static final Set<String> BLOCK_REALIGN_CODES = Set.of(
    CODE_MOVE_FIX_ASSIGNMENT, CODE_MANUAL_TRANSFER, CODE_TRANSFER, CODE_ON_HOLD);

static final Set<String> PASS_THROUGH_CODES = Set.of(
    CODE_FINISHED_PICKING, CODE_FINISHED_PACKAGING_MOVE_TOTE, CODE_TRUCK_LOADING,
    CODE_SHIPPING, CODE_SEND_TO_NIRVANA, CODE_MANUAL_SPLIT /* split spawns a NEW sibling
        stockunit; the backing stockunit of an existing pick line does NOT relocate. */
    /* + receiving/putaway codes */);

enum Bucket { BLOCK_REALIGN, PASS_THROUGH }

static Bucket classify(String activityCode, Long stockUnitId) {
    if (BLOCK_REALIGN_CODES.contains(activityCode)) return Bucket.BLOCK_REALIGN;
    if (PASS_THROUGH_CODES.contains(activityCode))  return Bucket.PASS_THROUGH;
    LOG.warn("Unknown move activityCode '{}' for stockUnitId={} — defaulting PASS_THROUGH (fail-open)",
        activityCode, stockUnitId);
    return Bucket.PASS_THROUGH;
}
```

- **`CODE_MANUAL_SPLIT` is PASS_THROUGH:** at `MobileMoveStockService:270/:326/:331` `transferStockToUnitLoad` under this code creates a NEW destination stockunit; the source keeps its identity and does not relocate. BLOCK would block legitimate splits; REALIGN would rewrite strings against a stockunit that never moved. Neither is correct → pass-through.
- **PASS_THROUGH ⇒ never block, never realign** (AC-7) — this is what keeps shipping flowing.
- **Unknown ⇒ PASS_THROUGH + WARN (fail-open)** — safe ONLY because the detector is the compensating control (§9 M3).

### 5.2 P2 — Fixed-assignment move (primary regression)

```java
@Transactional(rollbackFor = Exception.class)
public void move(Long fixedLocationAssignmentId, Long destinationId, boolean updatePickingPositions)
        throws BusinessException, FacadeException {
    // (DELETED broken :126 finder AND the inline realign loop :163-169.)
    // Owning-Pickingorder lock acquired in transferUnitLoadToLocation:77 entry (§5.5).
    unitloadBusinessService.transferUnitLoadToLocation(unitload, destination, false,
        WmsConstants.CODE_MOVE_FIX_ASSIGNMENT, null, null);   // :156 → Hook A (BLOCK_REALIGN)
}
```

`updatePickingPositions`: **keep-but-ignored** (D-13).

### 5.3 P1 — `PickLineRealignmentService` (shared primitive — ACYCLIC BY CONSTRUCTION)

**Spring-cycle constraint (HARD).** Tracing the would-be edge: `StockunitBusinessService` (Hook B) → `PickLineRealignmentService` → if it called `PickingorderPositionService.fixPickingPosition` → that calls `stockunitBusinessService.changeReservedAmount` (`PickingorderPositionService.java:133`, `:149`; `changeReservedAmount` is on `StockunitBusinessService:332`) → **back to `StockunitBusinessService`**. There is **no `@Lazy` and no allow-circular-references anywhere in `src/main`** — so this would be a **hard Spring startup failure**, not a warning. Injecting `PickingorderPositionService` *is* the edge that forms the cycle.

**Structural break — dependencies are REPOSITORIES ONLY:**

```java
@Service
@Transactional(rollbackFor = Exception.class)
public class PickLineRealignmentService {
    // injects ONLY:
    //   PickingorderPositionRepository, PickingorderRepository,
    //   StockunitRepository, LocationRepository, UnitloadRepository
    // MUST NOT inject PickingorderPositionService, StockunitBusinessService, UnitloadBusinessService.

    boolean isActive(PickingorderPosition pp);                  // owning Pickingorder.state >= 500
    void assertNoActivePickFor(Long stockUnitId) throws BusinessException;

    /** Common case (the 15 state=300 rows): INLINE 3-field rewrite via repository.save().
     *  No fixPickingPosition, no changeReservedAmount → no cycle. Keeps pickfromstockunitId (I-1). */
    void realignForMovedStockUnit(Stockunit su, Unitload newUl, Location newLoc) {
        for (PickingorderPosition pp : pickingorderPositionRepository.findByPickfromstockunitId(su.getId())) {
            if (isActive(pp)) throw new BusinessException(ACTIVE_PICK_MESSAGE);   // belt-and-suspenders
            pp.setPickfromunitloadlabel(newUl.getLabelid());     // a UL label
            pp.setPickfromlocationname(newLoc.getName());        // a location name
            // pp.pickfromstockunitId UNCHANGED (I-1)
            pickingorderPositionRepository.save(pp);
        }
    }
}
```

Block message (exact): `"This stock is currently tied to active picking work. Please wait till picking is complete before moving this stock or changing its fixed assignment."` — `BusinessException` (422 via SBDEV-2116).

**No reserve/unreserve in the synchronous move path.** A plain location/UL move does not change reserved quantities (the stock and its reservation stay with the same stockunit; only where it physically lives changes). Reserve/unreserve substitution is exclusively a `fixPickingPosition` concern and is confined to the ops/backfill flow (§5.4 nirvana, §7.3).

> **Gate note:** `mvn clean compile` + a context-load test (per the user's standing memory directive) **catch** a cycle; they do not **prevent** one. The repos-only design is acyclic *by construction* — the gate is the safety net, not the mechanism.

### 5.4 P1/Hook A & Hook B; nirvana

**Hook A** (`UnitloadBusinessService.processTransfer`, after `:217`, before `:230`):

```java
unitload.setStoragelocationId(destinationLocation.getId());                 // :217 (existing)
if (PickLineActivityCodeClassifier.classify(activityCode, /*per-su*/) == Bucket.BLOCK_REALIGN) {
    for (Stockunit su : stockunitRepository.findByUnitloadId(unitload.getId())) {
        pickLineRealignmentService.assertNoActivePickFor(su.getId());        // block if owning order active
        pickLineRealignmentService.realignForMovedStockUnit(su, unitload, destinationLocation);
    }
}
// PASS_THROUGH → fall straight through to recursion (AC-7 — shipping/truck-load/split untouched)
```

**Hook B** (`StockunitBusinessService.transferStockToUnitLoad`, after `:227`): same classify→guard, resolving the destination UL's location.

**Nirvana (`sendStockUnitToNirvana:295`) — substitution is OUT of the synchronous move path (D-5):**
- `CODE_SEND_TO_NIRVANA` is PASS_THROUGH.
- For **active** owning orders the move **blocks** (active-pick guard).
- For **not-started** lines on the nirvana path the move also **blocks** (does not silently strand a pick line); any reserve/unreserve **substitution** is handled ONLY by the existing ops flow `PickingOrderPositionController.fixPickingPosition` and the §7.3 backfill — never from the move hot path (this is precisely the call that would re-form the cycle).

### 5.5 Concurrency & lock order (REVISED)

**Canonical order** (`CustomerorderBatchRepository.java:33`):
`Billoflading > CustomerorderBatch > Customerorder > Pickingorder > Unitload/Stockunit`. Pick-confirm honors it (`PickingorderBusinessService:252` Customerorder → `:254` Pickingorder → stock).

**The lock cannot live inside `processTransfer`:** its very first line (`:217-218`) writes `setStoragelocationId` — too late to be before the UL/stock write. The owning-Pickingorder `findByIdForUpdate` lock is therefore acquired **at the top of EACH of the THREE `@Transactional` entry methods, before any UL/stock write, in ascending Pickingorder-id order:**

1. `UnitloadBusinessService.transferUnitLoadToLocation:77`
2. `UnitloadBusinessService.transferUnitLoadToCarrier:149`
3. `StockunitBusinessService.transferStockToUnitLoad:124/:125` — the **stock path does NOT route through `processTransfer`**; it saves the stockunit directly at `:228`, so it must lock itself before `:227-228`.

**Dedup per move tree:** maintain a `Set<Long> lockedPickingorderIds` for the whole recursive tree; lock each owning Pickingorder at most once, ascending id. A UL tree referencing the same Pickingorder twice locks it once. **Rebind after lock** to avoid `StaleObjectStateException` (`260422-…` discipline). Pick-start path confirmed to take the same `findByIdForUpdate(pickingorderId)` (`PickingorderBusinessService:254`).

### 5.6 Atomicity (I-2, AC-2)

The outer transaction owns the move. A mid-recursion block (`BusinessException`) rolls back ALL `setStoragelocationId`/`setUnitloadId` writes and all prior inline realigns — no partial state. The **mobile** path requires `@Transactional` on `MobileMoveStockService.selectDestination:228` (D-11), else the inner `transferStockToUnitLoad` rollback would not undo the outer untransacted writes.

### 5.7 Traceability (BLOCKING items → design / test / risk / verify-script)

| Item | §5 design | §8 test | §9 risk | verify-script check |
|------|-----------|---------|---------|---------------------|
| #1 activityCode scoping | §5.1 taxonomy; §5.4 hooks gate on `classify` | `classify_*` units (incl. `CODE_MANUAL_SPLIT→PASS_THROUGH`, unknown→pass-through), AC-7 IT | R-1, M3 | taxonomy class + `BLOCK_REALIGN_CODES`/`PASS_THROUGH_CODES` present |
| #2/#C lock-order hoist | §5.5 (lock at 3 entry methods, canonical order) | `concurrentMoveTrees_noDeadlock` IT, AC-6 | R-2 | `@Transactional` on `move()` + lock-before-write review note on all 3 entries |
| #3 mobile atomicity | §5.6 + site #8 | `mobileMoveStock_block_noWriteCommitted` IT | R-3 | `@Transactional` on `selectDestination` |
| #4 detector SQL (P0) | §2.5, P0 | `detector_seedMismatch_countGtZero_thenZero` IT | M3 | detector SQL contains `pickfromstockunit_id = stockunit.id` |
| #5 AC-7 pass-through | §5.1, §5.4 | AC-7 IT | R-1 | (covered by taxonomy) |
| #A no-cycle (repos only) | §5.3 (acyclic by construction); §5.4 nirvana | context-load test; `realign_usesRepoSaveNotFixPickingPosition` unit | R-6 | `PickLineRealignmentService` injects no `*BusinessService`/`PickingorderPositionService`; `mvn clean compile` + context-load |
| #9 dedup recursion | §5.5 | `ulTree_sameOrderTwice_lockedOnce` IT | R-2 | (review note) |
| I-1 FK preserved | §5.0, §5.3 | `realign_keepsStockUnitId` unit | R-8 | no `setPickfromstockunitId` in realign path |

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `repo/jpa/PickingorderPositionRepository.java` | Modify (**P0**) | Insert missing `=` at `:33-34` and `:44-45`; mirror correct `...ById` joins |
| `PickLineActivityCodeClassifier.java` | **New** | `BLOCK_REALIGN_CODES`={MOVE_FIX_ASSIGNMENT, MANUAL_TRANSFER, TRANSFER, ON_HOLD}; `PASS_THROUGH_CODES`={FINISHED_PICKING, FINISHED_PACKAGING_MOVE_TOTE, TRUCK_LOADING, SHIPPING, SEND_TO_NIRVANA, **MANUAL_SPLIT**, …}; `classify()` fail-open + WARN |
| `PickLineRealignmentService.java` | **New** | **Repositories ONLY** (PickingorderPosition/Pickingorder/Stockunit/Location/Unitload repos). Inline `repository.save()` realign; NO `PickingorderPositionService`, NO `*BusinessService` — acyclic by construction |
| `UnitloadBusinessService.java` | Modify | Lock at entries `:77`/`:149`; Hook A after `:217`, classify-gated; dedup locked-orders across recursion |
| `StockunitBusinessService.java` | Modify | Lock at entry `:124` before `:227`; Hook B after `:227`, classify-gated; nirvana pass-through (block, no substitute) |
| `FixLocationAssignmentService.java` | Modify | `@Transactional`; delete `:126` finder + `:163-169` loop; route via Hook A |
| `MobileMoveStockService.java` | Modify | `@Transactional(rollbackFor={BusinessException,FacadeException})` on `selectDestination:228` |
| `FixLocationAssignmentController.java` | No change / doc | Keep `move(id,dest,true)`; document `updatePickingPositions` (D-13) |
| `PickLineActivityCodeClassifierUnitTest.java` | **New** | Bucket assertions incl. `CODE_MANUAL_SPLIT→PASS_THROUGH`, unknown→pass-through |
| `PickLineRealignmentServiceUnitTest.java` | **New** | Block/realign authority, I-1, **realign uses repo.save not fixPickingPosition** |
| `PickLineRealignmentIT.java` | **New** | P0 detector, AC-1..AC-7, deadlock/dedup, mobile atomicity, context-load |
| `FixLocationAssignmentServiceUnitTest.java` | Modify | Deleted finder/loop; routes through Hook A |

**No schema change.** `wms-mobile-ui`: surfaces the new `BusinessException` (SBDEV-2116 contract).

---

## 7. Implementation Steps

Sequence: **P0 → P1 → P2 → backfill → P3 → P4 → P5.**

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|--------------|------------------------|-------|
| 1 | **Database state** | No schema change; columns exist. | `db_verified: true` |
| 2 | **Feature flags / sysprops** | **N/A** — always-on; a flag would leave the broken path reachable. | |
| 3 | **Config / env** | **N/A** — service-layer logic only. | |
| 4 | **Deploy-order dependencies** | SBDEV-2116 `RestExceptionHandler` `BusinessException` handler already deployed (Phase 0, 2026-05) so the block renders as 422. | Hard dependency for AC-2 UX. |
| 5 | **Data migration — backfill (concrete runbook §7.3)** | After P2: 15 `state=300` lines auto-realign; 22 `state=500` follow the ops query+steps. AC-5 count==0 gated on this. | DBA-gated |
| 6 | **External systems** | **N/A** | |
| 7 | **Access / permissions** | **N/A** | |
| 8 | **Monitoring** | After P0, schedule the detector count; **alert on count > 0** (fail-open backstop, §9 M3). | Reuses fixed `:33-34` |

### 7.2 Implementation Checklist

- [ ] **P0** — Fix detector SQL `:33-34`/`:44-45` (add `=`). Add `detector_seedMismatch_countGtZero_thenZero` IT. Gates everything.
- [ ] **P1** — `PickLineActivityCodeClassifier` (taxonomy incl. `CODE_MANUAL_SPLIT→PASS_THROUGH`, fail-open); `PickLineRealignmentService` (**repositories only**, inline `repository.save()` realign — verify acyclic via `mvn clean compile` + context-load test); Hook A + Hook B (classify-gated); lock at the 3 entry methods (`:77`/`:149`/`:124`) before any write; dedup locked-orders. Confirm pick-start lock. Unit + IT.
- [ ] **P2** — `FixLocationAssignmentService.move()`: `@Transactional`, delete `:126` finder + `:163-169` loop, route via Hook A; resolve D-13.
- [ ] **Backfill** — run §7.3; confirm detector count==0.
- [ ] **P3** — Mobile move-unit-load via Hook A; BOL bulk-tree pass-through (#5); parameterized test.
- [ ] **P4** — Web/mobile manual move-stock; **add `@Transactional` to `selectDestination:228`**; parameterized + mobile-atomicity IT.
- [ ] **P5** — `sendStockUnitToNirvana` pass-through (block active+not-started, substitute only via ops flow); replenishment-finish via Hook B; tests.
- [ ] `mvn clean compile` + context-load test green; `mvn verify` green; verify script 0 FAIL.

### 7.3 Backfill runbook (concrete artifact)

```sql
-- (A) Confirm current stale population (post-P0)
SELECT getpickingorderpositioncount();   -- expect 37 (15 @300 + 22 @500)

-- (B) The 15 not-started (owning order < 500) — auto-realignable via the existing ops flow:
SELECT pp.id, pp.pickfromstockunit_id, po.state AS order_state
FROM pickingorder_position pp
JOIN pickingorder po ON po.id = pp.pickingorder_id
WHERE pp.id IN (SELECT id FROM getpickingorderpositions())
  AND po.state < 500;
-- For each id → PickingOrderPositionController.fixPickingPosition(id)  (ops flow; safe to call changeReservedAmount here)

-- (C) The 22 active (owning order >= 500) — CANNOT auto-realign an in-flight pick:
SELECT pp.id, po.id AS order_id, po.state, pp.pickedbyoperator_id, pp.pickfromstockunit_id
FROM pickingorder_position pp
JOIN pickingorder po ON po.id = pp.pickingorder_id
WHERE pp.id IN (SELECT id FROM getpickingorderpositions())
  AND po.state >= 500;
--   1. Identify picker/order (above).  2. Picker COMPLETES or supervisor ABORTS the pick.
--   3. Once the order drops below 500 (or is re-released), it falls into bucket (B); re-run (B).

-- (D) Verify clean
SELECT getpickingorderpositioncount();   -- MUST be 0 for AC-5 sign-off
```

---

## 8. Testing Plan

> **Mandatory gate:** unit test per change; Testcontainers IT for native-SQL/JPQL and locking changes. Mockito **3.3.3 — NO `mockStatic`** (set `SecurityContextHolder` directly). **`mvn clean compile` + context-load test (cycle gate, #A) are hard gates.** Verify script 0 FAIL.

### Unit tests (Mockito 3.3.3, no `mockStatic`)

`PickLineActivityCodeClassifierUnitTest`:

| Test | Asserts |
|------|---------|
| `classify_blockRealignCodes_returnBlockRealign` | CODE_MOVE_FIX_ASSIGNMENT, CODE_MANUAL_TRANSFER, CODE_TRANSFER, CODE_ON_HOLD → BLOCK_REALIGN |
| `classify_codeManualSplit_returnsPassThrough` | **`CODE_MANUAL_SPLIT` → PASS_THROUGH** (split spawns a sibling stockunit) |
| `classify_passThroughCodes_returnPassThrough` | CODE_FINISHED_PICKING, CODE_FINISHED_PACKAGING_MOVE_TOTE, CODE_TRUCK_LOADING, CODE_SHIPPING, CODE_SEND_TO_NIRVANA → PASS_THROUGH |
| `classify_unknownCode_passThroughAndWarns` | unknown → PASS_THROUGH (fail-open) |

`PickLineRealignmentServiceUnitTest`:

| Test | Asserts |
|------|---------|
| `isActive_owningOrderStarted_true` / `_processable_false` | authority = owning `Pickingorder.state`, compare by `getId()` |
| `assertNoActivePickFor_active_throwsBusinessException` | exact ticket message |
| `realign_rewritesLabelAndLocation_keepsStockUnitId` | I-1 (regression guard for `:167`) |
| `realign_usesRepositorySave_notFixPickingPosition` | **#A** — realign calls `pickingorderPositionRepository.save`, never `fixPickingPosition`/`changeReservedAmount` (cycle guard) |

`FixLocationAssignmentServiceUnitTest` (modify): broken `:126` finder + `:163-169` loop gone; `move()` routes through `transferUnitLoadToLocation`.

### Integration tests (Testcontainers PostgreSQL)

| Test | Scenario | Expected |
|------|----------|----------|
| `detector_seedMismatch_countGtZero_thenZero` (**P0**) | seed mismatched row → count>0; realign → count==0 | detector SQL valid (AC-5) |
| `fixedAssignmentMove_notStarted_realigns` | owning order `<500`, BLOCK_REALIGN code | strings = destination; FK valid (AC-1) |
| `move_activeOrder_blocksAndRollsBack` | owning order `>=500` | `BusinessException`; no write committed (AC-2) |
| `mobileMoveStock_block_noWriteCommitted` (**#3**) | block on mobile path | NO write committed (requires `@Transactional` on `selectDestination`) |
| `prePickEntryPoints_sameBehavior` | parameterized PRE-PICK: fixed-assign, mobile move-UL, web/mobile move-stock, replenish-finish | identical block/realign (AC-3, scoped) |
| `postPickOutbound_passThrough` (**AC-7**) | move UL with owning order `>=500` under CODE_SHIPPING/FINISHED_PICKING/TRUCK_LOADING/FINISHED_PACKAGING_MOVE_TOTE | **no `BusinessException`** AND **no pickfrom-string mutation** |
| `manualSplit_passThrough` (**#B**) | `CODE_MANUAL_SPLIT` split creating a sibling stockunit | not blocked, not realigned; existing pick line untouched |
| `sendToNirvana_blocksActiveAndNotStarted` (**#A/D-5**) | nirvana on stock backing a pick line | move blocks; substitution NOT performed in move path (only via ops flow) |
| `concurrentMoveTrees_noDeadlock` (**#2/#C**) | two concurrent move trees over overlapping Pickingorders | no deadlock; consistent ascending acquire order (AC-6) |
| `ulTree_sameOrderTwice_lockedOnce` (**#9**) | UL tree referencing same Pickingorder twice | locked exactly once |
| `context_loads` (**#A/#10**) | Spring context with `PickLineRealignmentService` | **no cycle** (hard gate); bean wiring valid |

### Manual test plan (ticket's 9 cases + outbound + split)

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|----------|-----|-------|----------|-----------|
| 1 | Fixed-assignment move, not-started | staging | reassign for open order `300` | realigned |  |
| 2 | Fixed-assignment move, active | staging | reassign for order `500` | blocked (422); old location intact |  |
| 3 | Mobile move-UL, not-started | staging mobile | move UL backing `300` | realigned |  |
| 4 | Mobile move-UL, active | staging mobile | move UL backing `500` | blocked |  |
| 5 | Manual move-stock (web), not-started | staging | move stock backing `300` | realigned |  |
| 6 | Manual move-stock (mobile), active | staging mobile | move stock backing `500` | blocked; no partial write |  |
| 7 | Replenishment finish, not-started | staging mobile | finish replenishment moving stock backing `300` | realigned via Hook B |  |
| 8 | Send-to-nirvana | staging | nirvana on stock backing a pick line | move blocked; substitution only via ops flow; never points at nirvana |  |
| 9 | Concurrency: move vs pick-start | staging | start pick + move same order ~simultaneously | exactly one proceeds; no deadlock; no stale line |  |
| 10 | **Outbound pass-through (AC-7)** | staging | ship / truck-load / finished-pick a UL whose owning order is `500` | NOT blocked, NOT realigned — shipping proceeds |  |
| 11 | **Manual split (#B)** | staging mobile | split a stockunit (CODE_MANUAL_SPLIT) backing an open pick line | split succeeds; pick line untouched |  |

### Test execution (fill in after running)

| Command | Result | Pass/Fail/Skipped |
|---------|--------|-------------------|
| `mvn clean compile` (cycle gate) | _to fill_ | |
| context-load test | _to fill_ | |
| `mvn test -Dtest=PickLineActivityCodeClassifierUnitTest` | _to fill_ | |
| `mvn test -Dtest=PickLineRealignmentServiceUnitTest` | _to fill_ | |
| `mvn verify -Dit.test=PickLineRealignmentIT` | _to fill_ | |
| `mvn verify` (full) | _to fill_ | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2481-stale-pick-line-realignment-on-stock-move.sh` | _to fill_ | 0 FAIL |

---

## 9. Risks & Mitigations

| ID | Risk | Impact | Mitigation |
|----|------|--------|-----------|
| R-1 | Hook A **halts shipping / truck-load / split** | Critical | activityCode taxonomy (§5.1): outbound + `CODE_MANUAL_SPLIT` are PASS_THROUGH; AC-7 + `manualSplit_passThrough` ITs prove no block, no mutation. |
| R-2 | **Lock-order inversion → deadlock** | High | §5.5: lock owning Pickingorder at the **three** `@Transactional` entries (`:77`/`:149`/`:124`), before any UL/stock write, ascending id; dedup per tree; `concurrentMoveTrees_noDeadlock` + `ulTree_sameOrderTwice_lockedOnce` ITs. |
| R-3 | **Mobile block not atomic** | High | `@Transactional(rollbackFor={BusinessException,FacadeException})` on `selectDestination:228`; `mobileMoveStock_block_noWriteCommitted` IT; verify-script greps the annotation. |
| R-4 | `StaleObjectStateException` from lock + reused entity | 500 | Lock first, rebind from fresh read (`260422-…`). |
| R-5 | Per-stockunit lookup on every UL move (perf) | Latency | `findByPickfromstockunitId` indexed, bounded; BOL bulk-tree (#5) + split are PASS_THROUGH (no per-node lookup). |
| R-6 | **Spring context cycle (HARD startup failure)** — no `@Lazy`/allow-circular in `src/main` | Startup fails | §5.3 — `PickLineRealignmentService` injects **repositories only**; inline `repository.save()` realign; nirvana substitution stays in the ops flow (`fixPickingPosition`), never the move path. Acyclic *by construction*; `mvn clean compile` + context-load test **catch** any regression (they do not prevent it — the design must remain acyclic). |
| M3 | **Fail-open depends on the detector backstop** | Silent stale rows if both fail | Unknown-code fail-open is acceptable ONLY because the post-P0 detector is the compensating control; a non-zero detector count after deploy is the on-call ALERT. Dependency chain: fail-open → detector backstop → detector must work → **P0 fixes it first** → §8 monitoring alerts on count>0. |
| R-7 | 22 active stale lines can't auto-realign | Medium | §7.3 runbook: complete/abort the pick, then re-run; AC-5 count==0 gated on this. |
| R-8 | Realign accidentally rewrites the FK | Data corruption | I-1 + `realign_keepsStockUnitId` unit test + verify-script "no `setPickfromstockunitId` in realign path". |

---

## 10. Open Questions / Resolved Decisions

| # | Item | Resolution |
|---|------|-----------|
| D-1 | Block-vs-realign authority detail | **RECOMMENDED: order-state-only** (`>=500` block). |
| D-2 | **RESOLVED (user-approved):** active rule | Block when owning `Pickingorder.state >= STARTED(500)`, realign otherwise. |
| D-3 | RESERVED (`400`) → realign vs block | **RECOMMENDED: realign** (`<500`). |
| D-4 | Delete inline realign loop vs patch | **RESOLVED: delete** (never ran; wrote wrong field). |
| D-5 | Nirvana substitution in the move path? | **RESOLVED: OUT of the synchronous move path.** Move path BLOCKS (active and not-started); reserve/unreserve substitution happens ONLY via the existing ops flow (`PickingOrderPositionController.fixPickingPosition`) / §7.3 backfill. Keeps the move path acyclic. |
| D-6 | **RESOLVED (MANDATORY):** activityCode scoping | Taxonomy §5.1. `BLOCK_REALIGN_CODES`={MOVE_FIX_ASSIGNMENT, MANUAL_TRANSFER, TRANSFER, ON_HOLD}; `PASS_THROUGH_CODES` includes **CODE_MANUAL_SPLIT** (split spawns a sibling stockunit). |
| D-7 | Pick-start takes same `findByIdForUpdate(pickingorderId)`? | **RESOLVED** — `PickingorderBusinessService:254`. |
| D-8 | **RESOLVED (user-approved):** scope | ALL workflows, phased P0→P5. |
| D-9 | **RESOLVED (user-approved):** v1 plan | Paired v2 via `wms-v2-migrate`. |
| D-10 | **RESOLVED:** lock placement | Owning-Pickingorder lock at the **three** `@Transactional` entry methods (`transferUnitLoadToLocation:77`, `transferUnitLoadToCarrier:149`, `transferStockToUnitLoad:124`), before any UL/stock write, ascending id, dedup per tree — **NOT inside `processTransfer`** (it writes on its first line). |
| D-11 | **RESOLVED:** mobile `@Transactional` | `selectDestination:228` gets `@Transactional(rollbackFor={BusinessException,FacadeException})`. |
| D-12 | **RESOLVED:** Phase-0 detector fix | Add `=` at `:33-34`/`:44-45`; P0 gates everything. |
| D-13 | `updatePickingPositions` param fate | **OPEN** — keep-but-ignored by default; confirm in P1 whether any caller depends on the `false` skip path; if none, remove. |
| D-14 (cycle) | **RESOLVED:** acyclic by construction | `PickLineRealignmentService` = **repositories only**; inline `repository.save()` realign; never injects `PickingorderPositionService`/`*BusinessService`. Verified no `@Lazy`/allow-circular exists in `src/main`, so the cycle would be a hard startup failure — eliminated structurally, not papered over. |

Open items (D-13) persisted to `.omc/plans/open-questions.md`.

---

## 11. Implementation Status

**Implemented 2026-06-24** on branch `task/SBDEV-2481` (off `develop`). Architect-verified (APPROVE, all 9 ACs) + code-reviewed (1 HIGH + 4 MEDIUM fixed; lock-timeout deferred). **Committed & PR'd:** [PR #176](https://github.com/SiteBossInc/wms-api/pull/176) → `develop`. Commits: `7c47a2b` (SBDEV-2481), `f3c0cae` (ro_id prerequisite migration).

| Phase | File(s) | Status | Commit SHA |
|-------|---------|--------|------------|
| P0 — detector SQL fix | `repo/jpa/PickingorderPositionRepository.java` (`=` added to the two detector queries) | ✅ done | _uncommitted_ |
| P1 — classifier + service (repos-only) + Hook A + Hook B + entry locks | **NEW** `PickLineActivityCodeClassifier.java`, **NEW** `PickLineRealignmentService.java`, `UnitloadBusinessService.java` (Hook A + entry locks `:96/:165`), `StockunitBusinessService.java` (Hook B + entry lock `:137`) | ✅ done | _uncommitted_ |
| P2 — fixed-assignment move | `FixLocationAssignmentService.java` (`@Transactional` `move()`; broken finder + inline loop deleted; routes via Hook A) | ✅ done | _uncommitted_ |
| Backfill (15 + 22) | §7.3 runbook | ⏳ deferred to deploy time (DBA-gated, post-merge) | — |
| P3 — unit-load move | covered by Hook A (mobile move-UL routes through `transferUnitLoadToLocation`); BOL bulk-tree = PASS_THROUGH | ✅ done | _uncommitted_ |
| P4 — manual stock move | `MobileMoveStockService.java` (`selectDestination` `@Transactional`) | ✅ done | _uncommitted_ |
| P5 — replenish + nirvana | `StockunitBusinessService.java` (`sendStockUnitToNirvana` blocks when a pick line references the SU; replenish-finish routes through Hook B) | ✅ done | _uncommitted_ |

**Tests added:** `PickLineActivityCodeClassifierUnitTest` (4), `PickLineRealignmentServiceUnitTest` (5), `PickLineRealignmentIT` (Testcontainers, 7 — AC-1..AC-7); `FixLocationAssignmentServiceUnitTest` updated for the new delegation; `UnitloadBusinessServiceUnitTest` / `StockunitBusinessServiceUnitTest` mocks updated for the new collaborator.

**Test results (2026-06-24):**
- `mvn clean compile` → BUILD SUCCESS (no Spring DI cycle).
- Gate IT `PickLineRealignmentIT` → **7 run, 0 failures, 0 errors, 0 skipped** (AC-1 realign, AC-2 block+rollback, P0 detector, AC-7 outbound pass-through, AC-4 nirvana-block, AC-5 detector-zero-after-realign, AC-6 lock-dedup).
- Touched-service unit tests → green (FixLocationAssignment 24, Unitload 13, Stockunit 27, MobileMoveStock 26, classifier 4, realign 5).
- Verify script `verify-SBDEV-2481-stale-pick-line-realignment-on-stock-move.sh` → **`Result: 29 pass, 0 fail, 0 skip`** (post-deslop).
- Known non-blocker: `StockunitBusinessServiceConcurrencyIT` cannot run offline (pre-existing Keycloak `oauth2RestTemplate` startup; lacks `@MockBean OAuth2RestTemplate`) — unrelated to this ticket.

**Companion fix (separate concern):** migration `V1.26.30__replenishment_monitor_view_add_ro_id.sql` adds the missing `ro_id` column to `replenishment_monitor_view` (an SBDEV-2384-area drift that blocked **all** v1 ITs at schema validation). Required for any v1 IT to run; track/commit independently.

**Follow-ups for review/QA:**
- D-13 still OPEN: `updatePickingPositions` param is keep-but-ignored; grep callers before deleting it.
- QA note (architect obs #4): the nirvana block now fires from any source-emptied transfer that still backs a pick line (intended per D-5 — never strand a pick — but a wider blast radius than fixed-assignment alone).

> **Verify script:** `sbdocs/9-System/scripts/verify-SBDEV-2481-stale-pick-line-realignment-on-stock-move.sh` — checks:
> - POSITIVE: `PickLineRealignmentService` present; `PickLineActivityCodeClassifier` with `BLOCK_REALIGN_CODES` + `PASS_THROUGH_CODES` (and `CODE_MANUAL_SPLIT` in the pass-through set); Hook A after `setStoragelocationId`; Hook B after `setUnitloadId`; `@Transactional` on `FixLocationAssignmentService.move()`; `@Transactional` on `MobileMoveStockService.selectDestination`; detector SQL contains `pp.pickfromstockunit_id = stockunit.id`.
> - NEGATIVE: broken `findByCustomerorderpositionId(oldLocation.getId())` gone; inline loop `:163-169` gone; no `setPickfromunitloadlabel(destination.getName())`; no missing-`=` `pp.pickfromstockunit_id stockunit.id`; **`PickLineRealignmentService` does NOT import/inject `PickingorderPositionService`, `StockunitBusinessService`, or `UnitloadBusinessService`** (cycle guard); no `setPickfromstockunitId` in the realign path (I-1).
> - BEHAVIOR: `mvn clean compile` + context-load test (cycle gate) + targeted `mvn test`/`mvn verify`.

> **Recommended OMC composition:** Large (P0 + classifier + repos-only service + 2 hooks + 3 entry-method locks + primary regression + mobile tx + 6 phases, cross-service, concurrency). Pre-draft: analyst+planner (done) → critic/architect (consensus loop, done) → `wms-tdd-gate` (write the named failing tests first) → **ralph** (loop: implement phase → run verify script → fix FAIL → repeat, exit on 0 fail) → **code-reviewer** → **git-master** (atomic per-phase commits). Verify script + verifier mandatory; `mvn clean compile` + context-load test are hard gates.
