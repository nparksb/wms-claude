---
title: "Replenishment-Order Source Not Synced on Unit-Load Move — Replen Picks Directed to Stale Source Location"
ticket: "SBDEV-2492"
ticket_url: "https://app.clickup.com/t/9006034209/SBDEV-2492"
pr: "https://github.com/SiteBossInc/wms-api/pull/183"
type: bug
priority: high
status: archived
project:
  - wms-api-v1
version: v1
requester: Internal
created: 2026-06-25
updated: "2026-07-15"
db_verified: true
related:
  - SBDEV-2481
  - 260624-stock-unit-history-on-unitload-relocation
tags:
  - plan
  - replenishment
  - move-stock
  - move-unitload
---

# Replenishment-Order Source Not Synced on Unit-Load Move — Replen Picks Directed to Stale Source Location

**Ticket:** [SBDEV-2492](https://app.clickup.com/t/9006034209/SBDEV-2492)
**Project:** v1/wms-api | **Version:** v1 | **Type:** Bug (long-standing design gap masked by the maintenance cron's heal-on-next-pass)
**Priority:** High (replenishment picks directed to a location that no longer holds the stock; intermittent, masked by cron)
**Status:** DRAFT (consensus loop — Architect / Critic review pending)
**Date:** 2026-06-25
**db_verified:** true (open-order source-field coupling confirmed against `wms1-wineco-dev`; current 0-mismatch attributable to the maintenance cron's heal-on-next-pass — see §1)

> **Sibling plan (directly analogous):** `SBDEV-2481-stale-pick-line-realignment-on-stock-move.md`. SBDEV-2481 repairs the *picking-order-position* string copies on a move; this plan repairs the *replenishment-order* source triple on the **same** choke point (`processTransfer`). The fix hooks **beside** SBDEV-2481's Hook A loop and reuses its classifier and its already-acquired owning-Pickingorder locks.

> **Repository package note:** v1 JPA repositories live under `net/aim_ai/wms/repo/jpa/`. The `Replenishorder` JPA entity lives under `net/aim_ai/wms/model/`. State constants live in `net/aim_ai/wms/service/WmsConstants.java` (`WmsConstants.State`).

---

## 0. Affected Sites

Every UL→location move (and recursively every child UL on a pallet tree) funnels through **one choke point** — `UnitloadBusinessService.processTransfer:230 setStoragelocationId`. That write rewrites the unit-load's physical location but **never touches the bound `Replenishorder`**, whose source is a triple of *string/id copies* of the old location. The fix attaches a per-stock-unit replenishment-source sync **inside SBDEV-2481's existing `BLOCK_REALIGN` block** (at `processTransfer:243`), replaces the destructive cancel-on-move in `MobileMoveUnitloadService.checkReservedStock`, and fixes one adjacent latent bug in `ReplenishorderService.redirectSource`.

| # | File:line | Construct | Same root cause? | In scope? | Rationale / disposition |
|---|-----------|-----------|------------------|-----------|-------------------------|
| 1 | `UnitloadBusinessService.processTransfer:230 setStoragelocationId` (recurses `:249-257`) | **CHOKE POINT** — every UL→location move incl. child ULs writes a new `storagelocation_id`; never touches `Replenishorder` | **YES — primary** | **IN** | Moved UL + recursively its children get a new location with no replen sync. Hook beside SBDEV-2481's Hook A loop at `:237-245`; new call inside the existing `BLOCK_REALIGN` if-block at `:243`. **Fix A.** |
| 2 | `MobileMoveUnitloadService.checkReservedStock:166-181` (cancels reserved replen via `cancelReplenishmentOrder:175`) | Move-UL **CANCELS** the reserved replen instead of re-pointing it | **YES — behavioral root** | **IN** | Replace cancel with sync-at-choke-point (decision 1). **Fix B.** |
| 3 | `ReplenishorderService.existsForStockUnit:272-280` → `ReplenishorderRepository.findByStateLessThanAndStockunitId:108` | Active-replen-by-source-SU lookup (`state < 700`), returns `Optional<Replenishorder>` (≤1 row) | mechanism | **IN (reuse)** | The sync calls this finder per moved/child SU. |
| 4 | `ReplenishmentOrderMaintenanceService.redirectSource:250-297` (sets `requestedlocationId`+`requestedrackId`+`sourcelocationname` at `:285-288`) | Canonical re-point pattern (re-points to a **different** SU, with reserve/unreserve) | mechanism | **IN (pattern reuse only)** | `private` — copy the field-set triple shape; the new sync is **same-SU, location-only** (no reserve/unreserve). |
| 5 | `ReplenishorderService.redirectSource:151-184` — a **different-SU** re-point (`changeReservedAmount` unreserve `:160` / reserve `:180`, `setStockunitId:175`, `setRequestedlocationId:176`, `setRequestedrackId:177`, `save:178`), **MISSING `setSourcelocationname`** | Admin re-point latent bug | partial | **IN (decision 3)** | Purely-additive: insert `setSourcelocationname(location.getName())` between `:177` and the `:178` save; leave the reserve/unreserve/stockunit logic untouched. **Fix C.** |
| 6 | `StockunitService.transferStock:188` whole-UL branch (`CODE_MANUAL_TRANSFER`) → `transferUnitLoadToLocation` | Routes through choke point #1 | **YES (same as #1)** | **IN (auto-covered)** | No separate edit — covered by Fix A's hook. |
| 7 | `MobileMoveStockService.selectDestination` split (`CODE_MANUAL_SPLIT`) → `transferStockToUnitLoad:140` | Reserved source `available=0` throws before the move; split spawns a NEW sibling SU | **NO** | **OUT** | PASS_THROUGH (SBDEV-2481 taxonomy). The bound SU never relocates. |
| 8 | `StockunitBusinessService.transferStockToUnitLoad:239` full-move reattach (`setUnitloadId`) | SU moves to a different UL | possible secondary | **OUT / flagged** | Blocked at `:140` for a reserved source; only the unreserved-source edge remains. Open question **G8**. |
| 9 | `UnitloadBusinessService.transferUnitLoadToCarrier:219` (`setCarrierunitloadId`) | Carrier nesting; child `storagelocation_id` inherited, not rewritten | **NO** | **OUT** | Does not rewrite the moved UL's `storagelocation_id` row. |
| 10 | `UnitloadBusinessService.transferPalletTreesToLocation:392` (BOL bulk close, `CODE_SHIPPING`/`CODE_TRUCK_LOADING`) | Bulk pallet-tree move | **NO** | **OUT** | Outbound / post-pick; no active replen against shipped stock. |

**Every IN row is visited by §5** (Fix A → #1, #6; Fix B → #2; reuse → #3, #4; Fix C → #5). Every OUT row is excluded with rationale above.

**Existing infrastructure reused (no new copies):**

| Asset | Location | Use |
|-------|----------|-----|
| SBDEV-2481 classifier | `PickLineActivityCodeClassifier.classify(activityCode, suId)` | The new sync runs inside the **same** `BLOCK_REALIGN` if-block — no second classify call |
| SBDEV-2481 entry-method locks | `UnitloadBusinessService:96-97` & `:165-166` (`lockOwningPickingorders` over the UL tree) | Already serialize move vs pick-start before any write; the sync inherits them |
| Active-replen finder | `ReplenishorderRepository.findByStateLessThanAndStockunitId(state, suId):108` → `Optional<Replenishorder>` | Per-SU lookup in the sync |
| Re-point field triple (pattern) | `ReplenishmentOrderMaintenanceService.redirectSource:285-288` | Shape for the `requestedlocationId`/`requestedrackId`/`sourcelocationname` set |
| Optimistic lock | `Replenishorder.version` (`@Version Integer`, `:53-54`) | `@Version` detects a concurrent write → `StaleObjectStateException` (decision 4) |
| Optimistic-retry wrapper | `OptimisticLockRetryTemplate.executeWithRetry(...)` (`service/util/`; used at `TransfersController:108/134/162/193/257`, `ClubLineController`, `BillOfLadingController`) | Wraps the **move entry controllers** so a `StaleObjectStateException` restarts the whole tx with a fresh persistence context (decisions 4 + 5) |

**No scheduled job is added or modified.** The existing `ReplenishmentOrderMaintenanceService.recalculateOpenOrders` cron stays as the compensating backstop.

---

## 1. Problem Statement

### User-Visible Symptom

A `Replenishorder` records its **source** as three coupled fields — `stockunitId` (an FK, stays valid), `requestedlocationId` (rots), `sourcelocationname` (rots), plus `requestedrackId` (rots). When the underlying unit load moves to a new location, `processTransfer` updates `unitload.storagelocation_id` (and recurses into child ULs) but **never touches the bound `Replenishorder`**. After a parent-pallet move, the child UL's physical location is correct, but the replen still points at the **old** location.

The mobile UI computes the source from the **live** UL location (new); the replen source-check compares against the **stale** `requestedlocation`/`sourcelocationname` (old). The operator sees a directive to a location that no longer holds the stock — e.g. *"no unit load at 53-734"* — and only the original `TC-OS` source still works.

### Reproduction

1. Place stock on a child UL nested on a parent pallet (`carrierunitload_id` non-null), fully reserved (`reservedamount == requestedamount`), backing a PROCESSABLE (`300`) replenishment order.
2. Move the **parent pallet** from location A → B (mobile move-unit-load or web manual move). `processTransfer` recurses to the child and rewrites the child UL's `storagelocation_id` to B.
3. **Immediately** (before the next maintenance pass) query the replen against the UL location:

```sql
-- Stale-source detector: open replen whose bound SU's UL now sits at a
-- different location than the replen's recorded requestedlocation.
SELECT ro.id            AS replen_id,
       ro.state,
       ro.stockunit_id,
       ro.requestedlocation_id,
       ro.sourcelocationname,
       ro.requestedrack_id,
       ul.storagelocation_id AS ul_actual_location
FROM   replenishorder ro
JOIN   stockunit su ON su.id = ro.stockunit_id
JOIN   unitload  ul ON ul.id = su.unitload_id
WHERE  ro.state < 700                         -- open orders
  AND  ro.requestedlocation_id <> ul.storagelocation_id;   -- source rotted
-- > 0 rows in the window between the move and the next maintenance pass.
```

### DB-verification block

```
db_verified: true   (MCP wms1-wineco-dev)
- replenishorder columns confirmed: stockunit_id, requestedlocation_id,
  sourcelocationname, requestedrack_id, state.
- Open orders (state < 700): total = 603.
- Current stale-source mismatch count = 0  ← NOT because the bug is absent;
  ReplenishmentOrderMaintenanceService.recalculateOpenOrders (:69-86, state=300 only)
  heals stale rows via isSourceUsable:232 -> redirectSource:250 on its sysprop-gated
  cadence. Staleness is a TRANSIENT WINDOW between the move and the next pass.
- Every sampled open replen source sits on a CHILD UL nested on a parent pallet
  (unitload.carrierunitload_id non-null) and is FULLY reserved
  (reservedamount == requestedamount) -> the reporter's exact shape, AND why a
  move-UL CANCELS the replen today (load-bearing for decision 1; see §2 Bug 2).
- Manual repro: move a parent pallet holding a child UL backing a PROCESSABLE
  replen, then query requestedlocation_id vs unitload.storagelocation_id ->
  mismatch until the cron heals.
```

The intermittency (heal-on-next-pass) is exactly why this is a hard-to-catch, recurring report rather than a steady-state defect.

---

## 2. Root Cause Analysis

> CLAUDE.md (v1/wms-api): "No JPA association annotations — manual FK relationships only. Entity comparison by ID, not `.equals()`."

### Bug 1 — RC1: the replenishment source is a coupled triple, but the move only updates the unit load (DESIGN GAP)

`Replenishorder` binds its source through four fields (`net/aim_ai/wms/model/Replenishorder.java`):
- `stockunitId` (`setStockunitId:216`) — the stock-unit FK; **stays valid** across a location move (the stock keeps its identity).
- `requestedlocationId` (`setRequestedlocationId:200`) — **rots** on a move.
- `sourcelocationname` (`setSourcelocationname:152`) — **rots** on a move.
- `requestedrackId` (`setRequestedrackId:208`) — **rots** on a move.

The single write that relocates a unit load is `UnitloadBusinessService.processTransfer:230`:

```java
230:        unitload.setStoragelocationId(destinationLocation.getId());
231:        unitload = unitloadRepository.save(unitload);
```

It recurses into child ULs at `:249-257`, so a whole pallet tree is relocated. **Nowhere in this path is any `Replenishorder` field touched.** The FK (`stockunitId`) still resolves, but the recorded location triple now contradicts the unit load's live `storagelocation_id`. This is the same class of defect SBDEV-2481 fixed for `PickingorderPosition` string copies — only the entity differs. Because only `stockunitId` survives, the sync **must preserve `stockunitId` and the reservation** and rewrite only the location triple (invariant **I-1**, §5.0).

### Bug 2 — RC2: move-unit-load CANCELS the reserved replen instead of re-pointing it (BEHAVIORAL ROOT)

`MobileMoveUnitloadService.checkReservedStock:166-181`:

```java
166:    private void checkReservedStock(Unitload unitLoad) throws BusinessException, FacadeException {
167:        for (Unitload ul : unitloadRepository.findByCarrierunitloadId(unitLoad.getId())) {
168:            checkReservedStock(ul);
169:        }
170:        List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(unitLoad.getId());
171:        for (Stockunit stockUnit : stockUnitList) {
172:            if (BigDecimal.ZERO.compareTo(stockUnit.getReservedamount()) != 0) {
173:                Replenishorder replenishOrder = replenishorderService.existsForStockUnit(stockUnit);
174:                if (replenishOrder != null) {
175:                    replenishorderService.cancelReplenishmentOrder(replenishOrder);   // <-- DESTRUCTIVE
176:                    continue;
177:                }
178:                throw new BusinessException("Reserved stock! can not move unit load " + unitLoad.getLabelid());
179:            }
180:        }
181:    }
```

For a moved UL whose stock is reserved by an active replen, the current behavior **cancels** that replen (`:175`) rather than re-pointing it. Combined with Bug 1 (no sync at the choke point), the system either silently drops the replen (mobile path) or leaves it pointing at a stale location (other paths). Since every DB-sampled open replen source is fully reserved, **this cancel branch fires on exactly the reporter's shape** — confirming the cancel-vs-sync decision is load-bearing.

Why it fails: cancelling a valid, in-flight replenishment because its source pallet physically moved is a data-loss behavior; the correct response is to re-point the replen to where the stock now lives (decision 1). The `throw` at `:178` (reserved stock with **no** backing replen) remains a legitimate guard and is kept.

### Bug 3 (adjacent) — RC3: `ReplenishorderService.redirectSource` re-points to a DIFFERENT SU without updating `sourcelocationname` (LATENT)

`ReplenishorderService.redirectSource:151-184` re-points an admin-driven replen to a **different** stock unit. It is a full re-point with reservation hand-off — it unreserves the old source (`changeReservedAmount` at `:160`), reserves the new source (`:180`), and rewrites the binding:

```java
160:        stockunitBusinessService.changeReservedAmount(source_old, replenishOrder.getRequestedamount().negate(), true, ...);  // unreserve OLD su
...
175:        replenishOrder.setStockunitId(stockUnit.getId());          // bind to the NEW su
176:        replenishOrder.setRequestedlocationId(location.getId());
177:        replenishOrder.setRequestedrackId(rack.getId());
178:        replenishorderRepository.save(replenishOrder);
180:        stockunitBusinessService.changeReservedAmount(stockUnit, replenishOrder.getRequestedamount(), false, ...);            // reserve NEW su
```

It sets `requestedlocationId` and `requestedrackId` but **never `sourcelocationname`** — so the display/source name string is left pointing at the old location even on a deliberate admin re-point. The canonical maintenance re-point sets all three (`ReplenishmentOrderMaintenanceService.redirectSource:288`); the admin path drifted. **Fix C is purely additive** — it inserts a single `setSourcelocationname(location.getName())` before the `:178` save and leaves the reserve/unreserve and `setStockunitId` logic **completely untouched**. (Unlike the new `syncForMovedStockUnit`, which is same-SU/location-only, this admin path legitimately moves the reservation to a different SU — do not conflate the two.) Closes the latent inconsistency in the same commit (decision 3).

---

## 3. Regression Chain (NOT a regression)

This is **not** a regression — there is no commit that broke a previously-working sync. It is a **long-standing design gap** (Bug 1) plus a **destructive default** (Bug 2), both masked by `ReplenishmentOrderMaintenanceService.recalculateOpenOrders` healing stale `state=300` rows on its sysprop-gated cadence (`isSourceUsable:232` → `redirectSource:250`). The symptom is the **transient window** between a move and the next maintenance pass — which is why it surfaces as an intermittent, hard-to-reproduce report rather than a deterministic break. No `git bisect` target exists; do not search for an introducing commit.

---

## 4. Architecture Overview

### Move-UL → processTransfer recursion → (NEW) replen sync

```
MOVE ENTRY CONTROLLERS (NEW: wrap in OptimisticLockRetryTemplate.executeWithRetry — decision 5)
  MoveUnitloadController.selectStock:74 (-> scanDestination)   [mobile UL->location move]
  StockUnitController.transferStock:60  (-> stockunitService.transferStock:92)  [web move]
        │  on StaleObjectStateException -> restart whole tx with a FRESH persistence context
        ▼
ENTRY METHODS (SBDEV-2481 already locks owning Pickingorders here)        CHOKE POINT
──────────────────────────────────────────────────────────────────────────────────────────
MobileMoveUnitload.move ───┐ CODE_TRANSFER
StockunitService.transfer ─┤ CODE_MANUAL_TRANSFER ──► transferUnitLoadToLocation / ...Carrier
(whole-UL branch)          ┘   (lock @ :96-97 / :165-166: lockOwningPickingorders over tree)
                                                          │
                                                          └► processTransfer(unitload, ...)
                                                               :230  setStoragelocationId(dest)   [relocates UL]
                                                               :231  unitloadRepository.save(ul)
                                                               :237  for su in findByUnitloadId(ul):
                                                               :238    if classify(activityCode,su)==BLOCK_REALIGN:
                                                               :243      pickLineRealignmentService.realignForMovedStockUnit(...)   [SBDEV-2481]
                                          NEW (Fix A)  ──►     :244      replenishOrderSourceSyncService.syncForMovedStockUnit(su, dest)
                                                               :249  for child in findByCarrierunitloadId(ul):
                                                               :257    processTransfer(child, ...)   ── RECURSION (parent + all children) ──┐
                                                                                                                                            │
                       ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
                       └─ per-SU across the WHOLE tree, the new sync runs inside the SAME BLOCK_REALIGN guard:
                              Replenishorder ro = findByStateLessThanAndStockunitId(FINISHED, su.id)
                              ro == null              -> return (AC7: no replen, no write)
                              ro.state >= STARTED(500)-> throw BusinessException (AC9: block in-progress, decision 2; INCLUDES 530)
                              else (300/400)          -> set requestedlocationId/requestedrackId/sourcelocationname = dest
                                                         save(ro)   [reservation + stockunitId UNTOUCHED]
                              StaleObjectStateException -> PROPAGATE (no internal retry); controller wrapper restarts the tx

Fix B: MobileMoveUnitloadService.checkReservedStock :175  stop calling cancelReplenishmentOrder; let the move proceed
       (sync now happens at the choke point). KEEP the :178 throw for reserved-but-no-replen.
Fix C: ReplenishorderService.redirectSource  insert setSourcelocationname(location.getName()) between :177 and the :178 save
       (purely additive; reserve/unreserve + setStockunitId untouched).
```

### Key Files

| File | Lines | Role |
|------|-------|------|
| `ReplenishmentOrderSourceSyncService.java` (**NEW**) | — | Shared per-SU replen-source sync — **repositories only** (acyclic; structurally mirrors `PickLineRealignmentService`). Lets `StaleObjectStateException` propagate (no internal retry) |
| `UnitloadBusinessService.java` | 96-97, 165-166, 230-257 | Entry-method locks (SBDEV-2481) + choke point; new sync call at `:244` |
| `MoveUnitloadController.java` (`controller/mobile`) | 66-74 (`selectStock` → `scanDestination`) | **NEW edit:** wrap the move call in `OptimisticLockRetryTemplate.executeWithRetry` (decision 5) |
| `StockUnitController.java` (`controller`) | 59-92 (`transferStock` → `stockunitService.transferStock:92`) | **NEW edit:** wrap the move call in `OptimisticLockRetryTemplate.executeWithRetry` (decision 5) |
| `OptimisticLockRetryTemplate.java` (`service/util`) | 63-72 | Existing static retry wrapper; used at `TransfersController:108/134/162/193/257` (the mirror pattern) |
| `MobileMoveUnitloadService.java` (mobile pkg) | 166-181 | `checkReservedStock` — replace cancel with no-op/guard (Fix B) |
| `ReplenishorderService.java` | 151-184, 272-280 | `redirectSource` (Fix C, purely additive name-set); `existsForStockUnit` (finder reuse) |
| `ReplenishmentOrderMaintenanceService.java` | 250-297 | Canonical re-point field triple (pattern reference, `private`) |
| `ReplenishorderRepository.java` (`repo/jpa`) | 108 | `findByStateLessThanAndStockunitId` → `Optional<Replenishorder>` |
| `Replenishorder.java` (`model`) | 53-54, 152, 200, 208, 216 | `@Version Integer`; the source-triple setters |
| `Location.java` (`model`) | 152, 176 | `getName()`, `getRackId()` |
| `WmsConstants.java` (`service`) | 44, 54, 79, 104 | `State.PROCESSABLE=300`, `STARTED=500`, `ORDER_BATCH_CLUB_RUN_FINISHED=530`, `FINISHED=700` |

---

## 5. Fix Design

### 5.0 Invariants

- **I-1 (FK + reservation preserved):** The sync rewrites `requestedlocationId` + `requestedrackId` + `sourcelocationname` ONLY. It NEVER changes `stockunitId`, `reservedamount`, or `requestedamount`. A plain location move does not change *which* stock backs the replen or *how much* is reserved — only *where it lives*. Do not call `changeReservedAmount` (that is the maintenance/admin re-point's concern and would re-form a Spring cycle — see §5.4).
- **I-2 (atomic per move tree):** The sync runs inside the outer move transaction. A later `BusinessException` in the same move (e.g. `scanDestination`) rolls back ALL `setStoragelocationId` writes, all SBDEV-2481 realigns, AND all replen syncs — no partial state (AC8).

### 5.1 Scope by owning replen state (decisions 2 + 6)

The block predicate is exactly `ro.getState() >= WmsConstants.State.STARTED` (decision 6).

| `replenishorder.state` | Meaning | Sync action |
|---|---|---|
| `300` PROCESSABLE | not yet started | **SYNC** (re-point location triple) |
| `400` RESERVED | reserved, not started | **SYNC** |
| `>= 500` STARTED | replenishment in progress | **BLOCK the move** (`BusinessException`) |
| `530` ORDER_BATCH_CLUB_RUN_FINISHED | club-run finished (a sub-state ≥ STARTED) | **BLOCK the move** — intentionally included by the `>= STARTED` predicate (decision 6) |
| `>= 700` FINISHED/CANCELED | terminal | not returned by the finder (`state < FINISHED`); no action |

Refusing the move when an in-progress (`>= STARTED`) replen backs the source: do not silently re-point work an operator is actively executing. **Decision 6 (one-line rationale):** `530` (`ORDER_BATCH_CLUB_RUN_FINISHED`, `WmsConstants.java:79`) sits between `STARTED(500)` and `FINISHED(700)`; because the predicate is `>= STARTED` (not `== STARTED`), `530` is intentionally covered — a club-run that has progressed past STARTED is still active work, so its source must not be silently moved. This is the chosen authority model (it does **not** mirror SBDEV-2481's *mechanism* — see §5.4 — only the choke-point/classifier reuse is shared with SBDEV-2481).

### 5.2 Fix B — replace cancel-on-move with let-it-proceed (decision 1)

**Site:** `MobileMoveUnitloadService.checkReservedStock:173-178`.

**Before:**
```java
173:                Replenishorder replenishOrder = replenishorderService.existsForStockUnit(stockUnit);
174:                if (replenishOrder != null) {
175:                    replenishorderService.cancelReplenishmentOrder(replenishOrder);   // DESTRUCTIVE
176:                    continue;
177:                }
178:                throw new BusinessException("Reserved stock! can not move unit load " + unitLoad.getLabelid());
```

**After:**
```java
173:                Replenishorder replenishOrder = replenishorderService.existsForStockUnit(stockUnit);
174:                if (replenishOrder != null) {
175:                    // SBDEV-2492: a valid active replen against this reserved stock is no longer
176:                    // cancelled on move. The source triple is re-pointed at the choke point
177:                    // (ReplenishmentOrderSourceSyncService inside processTransfer); let the move proceed.
178:                    continue;
179:                }
180:                throw new BusinessException("Reserved stock! can not move unit load " + unitLoad.getLabelid());
```

The reserved-but-no-backing-replen guard (`throw`) is unchanged — that path still has no legitimate destination for the reserved quantity. (Line numbers shift by the comment lines added; the verify script greps for the *absence* of `cancelReplenishmentOrder` in this file, not a fixed line.)

### 5.3 Fix C — `ReplenishorderService.redirectSource` sets `sourcelocationname` (decision 3)

**Site:** `ReplenishorderService.redirectSource:176-177`. The local `Location location` is already in scope (resolved at `:174`).

**Before:**
```java
176:        replenishOrder.setRequestedlocationId(location.getId());
177:        replenishOrder.setRequestedrackId(rack.getId());
```

**After:**
```java
176:        replenishOrder.setRequestedlocationId(location.getId());
177:        replenishOrder.setRequestedrackId(rack.getId());
178:        replenishOrder.setSourcelocationname(location.getName());   // SBDEV-2492: keep the source NAME in sync too
```

Minimal one-line addition; mirrors `ReplenishmentOrderMaintenanceService.redirectSource:288` which already sets all three.

### 5.4 Fix A — new `ReplenishmentOrderSourceSyncService` + hook in the `processTransfer` loop (decisions 1, 2, 4, 5)

**New service — repositories only, acyclic by construction** (structurally mirrors `PickLineRealignmentService`). It injects ONLY the repositories it needs; it must NOT inject `ReplenishorderService`, `*BusinessService`, or anything that calls `changeReservedAmount` (which would re-form a Spring cycle — the same class of hard startup failure SBDEV-2481 §5.3 documented; no `@Lazy`/allow-circular exists in `src/main`).

**The sync does NOT retry internally.** It lets `StaleObjectStateException` propagate; the retry boundary is the move-entry controller wrapper (§5.5, decision 5). `spring-retry` is **not** on the classpath (no dependency in `pom.xml`, no `@EnableRetry`/`@Retryable` anywhere in `src/main` — confirmed), so any `@Retryable` annotation would be inert dead code.

```java
@Service
@Transactional(rollbackFor = Exception.class)
public class ReplenishmentOrderSourceSyncService {

    // injects ONLY:
    //   ReplenishorderRepository, LocationRackRepository
    // MUST NOT inject ReplenishorderService / *BusinessService (cycle guard).
    private final ReplenishorderRepository replenishorderRepository;
    private final LocationRackRepository  locationRackRepository;

    /** Re-point the source triple of any active (state < FINISHED) replen bound to the moved SU
     *  onto the destination location. Same-SU, location-only: reservation + stockunitId untouched (I-1).
     *  Blocks (throws) if the replen is already STARTED (decisions 2 + 6; >= STARTED includes 530).
     *  Lets StaleObjectStateException PROPAGATE — the move-entry controller wrapper retries (§5.5). */
    public void syncForMovedStockUnit(Stockunit su, Location destinationLocation)
            throws BusinessException {
        Replenishorder ro = replenishorderRepository
            .findByStateLessThanAndStockunitId(WmsConstants.State.FINISHED, su.getId())
            .orElse(null);
        if (ro == null) {
            return;                                               // AC7: no active replen -> no write
        }
        if (ro.getState() >= WmsConstants.State.STARTED) {        // decisions 2 + 6: block in-progress (incl. 530)
            throw new BusinessException(
                "Replenishment in progress for this stock; complete or cancel it before moving. "
                + "replenOrderNumber=" + ro.getNumber());
        }
        LocationRack rack = destinationLocation.getRackId() == null ? null
            : locationRackRepository.findById(destinationLocation.getRackId()).orElse(null);

        ro.setRequestedlocationId(destinationLocation.getId());
        ro.setRequestedrackId(rack != null ? rack.getId() : destinationLocation.getRackId());
        ro.setSourcelocationname(destinationLocation.getName());
        // ro.stockunitId / reservedamount / requestedamount UNCHANGED (I-1)
        // No internal try/catch on StaleObjectStateException — let it propagate (decision 5).
        replenishorderRepository.save(ro);
    }
}
```

> **Signature notes (verified against the live tree while drafting):**
> - `ReplenishorderRepository.findByStateLessThanAndStockunitId(Integer state, Long stockunitId)` returns `Optional<Replenishorder>` (`repo/jpa/ReplenishorderRepository.java:108`) — so `.orElse(null)` is correct. `ReplenishorderService.existsForStockUnit` wraps this same finder but returns a nullable `Replenishorder`; the new service calls the repo directly to stay repos-only (acyclic).
> - `Replenishorder.setRequestedlocationId(Long)` `:200`, `setRequestedrackId(Long)` `:208`, `setSourcelocationname(String)` `:152`, `getState():156`, `getStockunitId()`, `@Version Integer version` `:53-54` — all confirmed present.
> - `Location.getName():152`, `Location.getRackId():176` confirmed. `LocationRackRepository.findById(...)` is already used in `ReplenishorderService` (`:172`/`:332`).
> - `WmsConstants.State.STARTED = 500` `:54`, `ORDER_BATCH_CLUB_RUN_FINISHED = 530` `:79`, `FINISHED = 700` `:104`, `PROCESSABLE = 300` `:44`, `RESERVED = 400` `:49` (in `net/aim_ai/wms/service/WmsConstants.java`) — confirmed.
> - **Correction vs. brief draft:** when `destinationLocation.getRackId()` is non-null but the rack row is missing, falling back to the raw `getRackId()` is safer than `null` (a valid location always has a rack id; mirrors how `ReplenishmentOrderMaintenanceService` tolerates a missing rack). If reviewers prefer strict `null`, that is a one-line change — recorded as **G3**.
> - **Retry mechanism (decisions 4 + 5, settled):** `spring-retry` is absent; the optimistic-`@Version` retry is realized by wrapping the move-entry controllers in `OptimisticLockRetryTemplate.executeWithRetry(...)` (§5.5), **not** by an annotation. `OptimisticLockRetryTemplate` is the existing static util at `net/aim_ai/wms/service/util/OptimisticLockRetryTemplate.java:63-72`, already used at `TransfersController:108/134/162/193/257`.

**Hook into `processTransfer`** — the new call goes INSIDE SBDEV-2481's existing `BLOCK_REALIGN` if-block, immediately after `realignForMovedStockUnit` (`:243`):

**Before (current, SBDEV-2481):**
```java
237:        for (Stockunit su : stockunitRepository.findByUnitloadId(unitload.getId())) {
238:            if (PickLineActivityCodeClassifier.classify(activityCode, su.getId())
239:                    == PickLineActivityCodeClassifier.Bucket.BLOCK_REALIGN) {
240:                // realignForMovedStockUnit already throws ACTIVE_PICK_MESSAGE on an active pick line
243:                pickLineRealignmentService.realignForMovedStockUnit(su, unitload, destinationLocation);
244:            }
245:        }
```

**After (SBDEV-2492 adds one line at `:244`):**
```java
237:        for (Stockunit su : stockunitRepository.findByUnitloadId(unitload.getId())) {
238:            if (PickLineActivityCodeClassifier.classify(activityCode, su.getId())
239:                    == PickLineActivityCodeClassifier.Bucket.BLOCK_REALIGN) {
240:                // realignForMovedStockUnit already throws ACTIVE_PICK_MESSAGE on an active pick line
243:                pickLineRealignmentService.realignForMovedStockUnit(su, unitload, destinationLocation);
244:                replenishOrderSourceSyncService.syncForMovedStockUnit(su, destinationLocation);   // SBDEV-2492
245:            }
246:        }
```

Why this exact placement (do not add a parallel choke point):
- It reuses **SBDEV-2481's classifier** (`BLOCK_REALIGN` = move/transfer codes; outbound + `CODE_MANUAL_SPLIT` are PASS_THROUGH) — so the sync inherits the correct scope for free: it runs on `CODE_TRANSFER`/`CODE_MANUAL_TRANSFER` moves and is skipped on shipping/truck-loading/split (AC5, AC6).
- It reuses the **owning-Pickingorder locks already acquired** at the entry methods (`:96-97`, `:165-166`) — no new lock, no new deadlock surface.
- `processTransfer` is **recursive** (`:249-257`), so the sync runs per-SU across the whole tree (parent + every child) automatically (AC1, AC2, AC3).
- **DO NOT** add `stockrecordService` / `recordRelocation` to `processTransfer` — `260624`'s verify script asserts `recordRelocation` lives in `StockrecordService`/`FixLocationAssignmentService`, not here. The new field on `UnitloadBusinessService` is `replenishOrderSourceSyncService` only; the negative check in §9 guards against accidentally pulling `stockrecordService` into this method.

Inject the new collaborator into `UnitloadBusinessService` beside the existing `pickLineRealignmentService` field (`:61`).

### 5.5 Optimistic-lock retry at the move-entry controllers (decisions 4 + 5)

The new sync write competes with the maintenance cron and concurrent moves on the same `Replenishorder`. The `@Version Integer` (`Replenishorder.java:53-54`) makes a losing write throw `StaleObjectStateException`. The faithful realization of "optimistic `@Version` retry" (decision 4) — given `spring-retry` is absent — is to **wrap the move-entry controller call in `OptimisticLockRetryTemplate.executeWithRetry(...)`**, exactly as `TransfersController:108/134/162/193/257` already does (decision 5). On a stale-version failure the wrapper restarts the whole transaction with a **fresh persistence context**, re-reading the now-current `Replenishorder` (and the now-current UL); a per-method internal retry cannot do this because the stale entity is already attached to the failed session.

> **Mechanism note (corrected framing):** this retry mechanism does **NOT** mirror SBDEV-2481. SBDEV-2481 serialized with a **pessimistic** `findByIdForUpdate` + lock-before-write at the entry methods. SBDEV-2492 reuses SBDEV-2481's **choke-point selection, classifier, and entry-method Pickingorder locks**, but its `Replenishorder` concurrency control is **optimistic** (`@Version` + controller-boundary retry). Do not conflate the two.

**Entry-point exceptions must propagate the stale failure** so the wrapper can see it: the entry `@Transactional` methods (`UnitloadBusinessService.transferUnitLoadToLocation:79`, `MobileMoveUnitloadService.scanDestination:184`) must NOT catch-and-swallow `StaleObjectStateException` (they don't today; preserve that). `syncForMovedStockUnit` and `processTransfer` also let it propagate (§5.4).

**Wrap-point selection rule:** wrap **every controller entry whose transaction reaches `processTransfer` with a `BLOCK_REALIGN` activity code** — not merely "the move endpoints." Because the new sync fires inside `processTransfer`'s `if (classify == BLOCK_REALIGN)` block, *any* entry carrying one of those codes can throw `StaleObjectStateException` on a move-vs-cron `@Version` conflict and therefore needs the retry wrapper. `BLOCK_REALIGN_CODES` (`PickLineActivityCodeClassifier`) has **four** members — `{CODE_MOVE_FIX_ASSIGNMENT, CODE_MANUAL_TRANSFER, CODE_TRANSFER, CODE_ON_HOLD}` — which map to **four controller entry methods** (five call sites incl. the bulk on-hold sibling), all of which must be wrapped:

| Controller : method | Endpoint | `activityCode` | Wrapped call |
|---|---|---|---|
| `MoveUnitloadController.selectStock:74` (`controller/mobile`) | `POST /selectDestination` (mobile UL→location move) | `CODE_TRANSFER` | wrap `mobileMoveUnitloadService.scanDestination(inDto)` at `:74` |
| `StockUnitController.transferStock:60` (`controller`) | `POST /transferStock` (web move-stock; whole-UL branch) | `CODE_MANUAL_TRANSFER` | wrap `stockunitService.transferStock(...)` at `:92` |
| `FixLocationAssignmentController.moveFixedAssignment:88` (`controller`) | `POST /move` (fixed-assignment move) | `CODE_MOVE_FIX_ASSIGNMENT` | wrap `fixLocationAssignmentService.move(id, destinationId, true)` at `:96` (→ `FixLocationAssignmentService.transferUnitLoadToLocation:164`) |
| `StockUnitController.setLockOnHold:334` **and** `bulkSetLockOnHold:363` (`controller`) | `POST /setLockOnHold`, `POST /bulkSetLockOnHold` (lock-on-hold relocates the UL to the on-hold location) | `CODE_ON_HOLD` | wrap `stockunitService.setLockOnHold(...)` at `:346` **and** at `:379` (→ `StockunitService.transferUnitLoadToLocation:319`) |

> **Out (no wrap needed):** `TransferOrderController:116` → `MobileTransferOrderService.transferStock` calls `transferUnitLoadToLocation` with a **null** `activityCode` → the classifier returns `PASS_THROUGH` → the sync does **not** run (and `reservedamount==0` there anyway). Any null/PASS_THROUGH path never reaches the new write, so it needs no wrapper.

**Before (`MoveUnitloadController.selectStock`, illustrative):**
```java
74:                mobileMoveUnitloadService.scanDestination(inDto);
```

**After:**
```java
74:                OptimisticLockRetryTemplate.executeWithRetry(() -> {
75:                    mobileMoveUnitloadService.scanDestination(inDto);
76:                }, "moveUnitload.selectDestination(" + inDto.getUnitLoadLabel() + ")");
```

Mirror the same wrap shape (`executeWithRetry(() -> { ... }, "<label>")`) at each of the other entries: `StockUnitController.transferStock:92`, `FixLocationAssignmentController.moveFixedAssignment:96`, and `StockUnitController.setLockOnHold:346` + `bulkSetLockOnHold:379` (wrap the per-iteration `setLockOnHold` call, or the loop body, so each unit-load relocation retries independently). Add the `import net.aim_ai.wms.service.util.OptimisticLockRetryTemplate;` to each controller (as `TransfersController:18` does). Keep the existing `try/catch (BusinessException ...)` error mapping around the wrapper — `executeWithRetry` re-throws a non-retryable `BusinessException` (e.g. the `>= STARTED` block) on the first occurrence, so the 422 contract is preserved.

> **Wrap-set invariant (R-3):** the wrap-point set must stay in sync with `BLOCK_REALIGN_CODES`. If a **5th** `BLOCK_REALIGN` code (and its controller entry) is ever added, that new entry must also be wrapped — otherwise it would reach the new sync write unprotected and surface a raw 500 on a `@Version` conflict. The verify script's four-entry assertion guards this (it FAILs if any of the four known entries loses its wrapper, prompting a review when the set changes).

> **Bulk-endpoint note:** `StockUnitController.bulkTransferStock:113` (loops `transferStock` at `:151`) is the bulk sibling of the `transferStock` move path; wrap it too if it is a real move path used in production (low-risk additive). Tracked under decision 5's scope; if reviewers want it out, it is a no-op to omit.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `ReplenishmentOrderSourceSyncService.java` (`service`) | **New** | **Repositories ONLY** (`ReplenishorderRepository`, `LocationRackRepository`). `syncForMovedStockUnit(su, dest)`: finder → null-return / `>= STARTED`-block (incl. 530) / re-point triple `save`. Acyclic by construction. **No internal retry** — lets `StaleObjectStateException` propagate (decision 5). No `@Retryable`/spring-retry. |
| `UnitloadBusinessService.java` | Modify | Inject `replenishOrderSourceSyncService`; add one call at `processTransfer:244` inside SBDEV-2481's `BLOCK_REALIGN` if-block. No new choke point, no `stockrecordService`. |
| `MoveUnitloadController.java` (`controller/mobile`) | **Modify** | Wrap `mobileMoveUnitloadService.scanDestination` (`selectStock:74`, `CODE_TRANSFER`) in `OptimisticLockRetryTemplate.executeWithRetry`; add the import (decision 5, §5.5). |
| `StockUnitController.java` (`controller`) | **Modify** | Wrap **three** call sites in `OptimisticLockRetryTemplate.executeWithRetry`: `transferStock:92` (`CODE_MANUAL_TRANSFER`), `setLockOnHold:346` and `bulkSetLockOnHold:379` (both `CODE_ON_HOLD`); add the import. (Optionally `bulkTransferStock:151`.) (decision 5, §5.5) |
| `FixLocationAssignmentController.java` (`controller`) | **Modify** | Wrap `fixLocationAssignmentService.move(id, destinationId, true)` (`moveFixedAssignment:96`, `CODE_MOVE_FIX_ASSIGNMENT`) in `OptimisticLockRetryTemplate.executeWithRetry`; add the import (decision 5, §5.5). |
| `MobileMoveUnitloadService.java` (`service/mobile`) | Modify | `checkReservedStock:175` — remove the `cancelReplenishmentOrder` call (let the move proceed; sync happens at choke point). Keep the `:178` reserved-no-replen `throw` (Fix B). Must NOT swallow `StaleObjectStateException` in `scanDestination:184` (§5.5). |
| `ReplenishorderService.java` | Modify | `redirectSource` — insert `setSourcelocationname(location.getName())` between `:177` and the `:178` save (Fix C, purely additive). |
| `ReplenishmentOrderSourceSyncServiceTest.java` | **New** | Null-return, `>= STARTED`-block (incl. 530), 300/400 re-point, I-1 (FK + reservation preserved). **No vacuous internal-retry test.** |
| `UnitloadBusinessServiceReplenSyncTest.java` (or extend `UnitloadBusinessServiceUnitTest`) | New / Modify | `processTransfer` calls `syncForMovedStockUnit` per SU inside `BLOCK_REALIGN`; PASS_THROUGH codes skip it. |
| `ReplenishmentOrderSourceSyncIT.java` | **New** | Testcontainers: AC1–AC10 (tree sync, block incl. 530, atomicity, redirectSource name, context-load). |
| `MoveStockMoveUnitloadConcurrencyIT.java` (or extend an existing IT) | **New** | Real `@Version` conflict driven **through** the controller wrapper (`executeWithRetry`); asserts the move ultimately succeeds after a retry (decisions 4 + 5). |
| `MobileMoveUnitloadServiceUnitTest.java` | Modify | Asserts move no longer cancels a valid active replen (AC4). |
| `ReplenishorderServiceUnitTest.java` | Modify | `redirectSource` now sets `sourcelocationname`; reserve/unreserve + `setStockunitId` unchanged (AC10). |

**No schema change.** `wms-mobile-ui`: surfaces the new STARTED-block `BusinessException` (SBDEV-2116 422 contract — already deployed).

---

## 7. Implementation Steps

Sequence: **new service → hook (Fix A) → Fix B → Fix C → tests → verify.**

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|--------------|------------------------|-------|
| 1 | **Database state** | No schema change; `replenishorder` columns (`stockunit_id`, `requestedlocation_id`, `sourcelocationname`, `requestedrack_id`, `state`, `version`) all exist. The `ro_id` migration (`V1.26.30__replenishment_monitor_view_add_ro_id.sql`) is **already on `develop`** (landed with SBDEV-2481) — required only for ITs to boot. | `db_verified: true` |
| 2 | **Feature flags / sysprops** | **N/A** — always-on. A flag would leave the destructive cancel-on-move reachable. | |
| 3 | **Config / env** | **N/A** — no new dependency. The optimistic retry uses the existing `OptimisticLockRetryTemplate` static util (`service/util`); `spring-retry` is NOT used (and is absent — confirmed). | |
| 4 | **Deploy-order dependencies** | SBDEV-2481 (PR #176) must be on the target branch first — this plan hooks **inside** its `BLOCK_REALIGN` block and reuses its classifier + entry locks. SBDEV-2116 `BusinessException`→422 handler already deployed (for the STARTED-block UX). | Hard dependency on SBDEV-2481. |
| 5 | **Data migration / backfill** | **N/A.** The existing `ReplenishmentOrderMaintenanceService.recalculateOpenOrders` cron already heals stale `state=300` rows on its cadence, and the DB currently shows 0 mismatch. No one-off backfill is required; once Fix A ships, no *new* stale rows are produced, and any in-flight stale row is healed by the next maintenance pass. **Stated explicitly per the §7.1 requirement.** | DBA: none |
| 6 | **External systems** | **N/A** | |
| 7 | **Access / permissions** | **N/A** | |
| 8 | **Monitoring** | Schedule the §1 stale-source detector query; **alert on count > 0 sustained across more than one maintenance interval** (a brief non-zero window is normal between a move and the cron pass; a *sustained* non-zero would mean the choke-point sync regressed). | Reuses the §1 SQL |

### 7.2 Implementation Checklist

- [ ] **Step 1 — new service.** Create `ReplenishmentOrderSourceSyncService` (repositories only; verify acyclic via `mvn clean compile` + context-load). Implement `syncForMovedStockUnit`: finder → null-return (AC7) / `>= STARTED`-block incl. 530 (AC9, decisions 2 + 6) / 300|400 re-point triple `save` (AC1, decision 1) preserving `stockunitId`+reservation (I-1). **No internal retry** — let `StaleObjectStateException` propagate (decision 5). No `@Retryable`/spring-retry.
- [ ] **Step 2 — Fix A hook.** Inject `replenishOrderSourceSyncService` into `UnitloadBusinessService`; add the call at `processTransfer:244` inside the existing `BLOCK_REALIGN` if-block. Confirm it runs per-SU across the recursive tree. Do NOT add a parallel choke point; do NOT add `stockrecordService`.
- [ ] **Step 3 — Fix B.** `MobileMoveUnitloadService.checkReservedStock:175` — remove `cancelReplenishmentOrder`; keep the `:178` throw. Confirm `scanDestination:184` does not swallow `StaleObjectStateException`. Update `MobileMoveUnitloadServiceUnitTest` (AC4).
- [ ] **Step 4 — Fix C.** `ReplenishorderService.redirectSource` — insert `setSourcelocationname(location.getName())` between `:177` and the `:178` save (purely additive). Update `ReplenishorderServiceUnitTest` (AC10).
- [ ] **Step 5 — controller retry wrap (decisions 4 + 5).** Wrap **all four** controller entries that reach `processTransfer` with a `BLOCK_REALIGN` code in `OptimisticLockRetryTemplate.executeWithRetry(() -> { ... }, "<label>")` (mirror `TransfersController:18/108`); add the import to each: (a) `MoveUnitloadController.selectStock:74` (`CODE_TRANSFER`); (b) `StockUnitController.transferStock:92` (`CODE_MANUAL_TRANSFER`); (c) `FixLocationAssignmentController.moveFixedAssignment:96` (`CODE_MOVE_FIX_ASSIGNMENT`); (d) `StockUnitController.setLockOnHold:346` **and** `bulkSetLockOnHold:379` (`CODE_ON_HOLD`). Keep the existing `BusinessException` error-mapping `try/catch` around each wrapper. Confirm the wrapped set matches `BLOCK_REALIGN_CODES` (wrap-set invariant, §5.5/R-3).
- [ ] **Step 6 — tests.** Unit + IT per §8, named to the ACs, **including** the controller-driven `@Version` conflict concurrency IT (replaces the dropped vacuous internal-retry unit test).
- [ ] **Step 7 — gates.** `mvn clean compile` + context-load test green (cycle gate, AC11); `mvn verify` green; verify script 0 FAIL.

---

## 8. Testing Plan

> **Mandatory gate:** unit test per change; Testcontainers IT for the lock/sync/atomicity behavior. **Mockito 3.3.3 — NO `mockStatic`** (set `SecurityContextHolder` directly). Testcontainers ITs need `@MockBean OAuth2RestTemplate` (dodge the startup Keycloak call), `-DargLine="-Dapi.version=1.41"` (daemon needs API ≥ 1.40), and the `ro_id` migration (already on `develop`). `mvn clean compile` + context-load = hard gate. Verify script 0 FAIL.

### Unit tests (Mockito 3.3.3, no `mockStatic`)

`ReplenishmentOrderSourceSyncServiceTest`:

| Test | Asserts | AC |
|------|---------|----|
| `sync_noActiveReplen_noWrite` | finder returns empty → no `save`, no exception | AC7 |
| `sync_processable_repointsTriple` | state 300 → `requestedlocationId`==dest.id, `requestedrackId`==dest rack, `sourcelocationname`==dest.name; `save` called | AC1 |
| `sync_reserved_repointsTriple` | state 400 → re-pointed (RESERVED still syncs) | AC1 |
| `sync_keepsStockUnitIdAndReservation` | `setStockunitId` / reservation setters NEVER called | I-1 |
| `sync_started_throwsBusinessException` | state 500 → `BusinessException`, no `save` | AC9, decision 2 |
| `sync_clubRunFinished530_throwsBusinessException` | state 530 (`ORDER_BATCH_CLUB_RUN_FINISHED`) → blocked by `>= STARTED` | AC9, decision 6 |
| `sync_propagatesStaleObjectState` | `save` throws `StaleObjectStateException` → the method does NOT catch it (no internal retry); exception propagates to the caller | decision 5 |

> **Dropped:** the previously-planned `sync_staleObjectState_retries` unit test is removed — with retry moved to the controller boundary, an in-service retry assertion would pass vacuously (there is no internal retry to exercise). The real retry behavior is proven by the controller-driven concurrency IT below.

`UnitloadBusinessServiceReplenSyncTest` (or extend `UnitloadBusinessServiceUnitTest`):

| Test | Asserts | AC |
|------|---------|----|
| `processTransfer_blockRealign_callsReplenSyncPerSu` | `syncForMovedStockUnit` invoked once per SU inside `BLOCK_REALIGN` | AC1 |
| `processTransfer_passThroughCode_skipsReplenSync` | shipping/truck-load/split code → `syncForMovedStockUnit` NEVER called | AC5, AC6 |
| `processTransfer_childTree_syncsDeepest` | recursion reaches a nested child UL's SU | AC3 |

`MobileMoveUnitloadServiceUnitTest` (modify):

| Test | Asserts | AC |
|------|---------|----|
| `checkReservedStock_activeReplen_doesNotCancel` | `cancelReplenishmentOrder` NEVER called for a found valid replen; move proceeds | AC4 |
| `checkReservedStock_reservedNoReplen_throws` | reserved with no replen → still throws (guard kept) | — |

`ReplenishorderServiceUnitTest` (modify):

| Test | Asserts | AC |
|------|---------|----|
| `redirectSource_setsSourcelocationname` | `setSourcelocationname(location.getName())` invoked | AC10 |

### Integration tests (Testcontainers PostgreSQL — `@MockBean OAuth2RestTemplate`)

`ReplenishmentOrderSourceSyncIT`:

| Test | Scenario | Expected | AC |
|------|----------|----------|----|
| `parentPalletMove_childReplen_synced` | move parent A→B; child UL SU backs PROCESSABLE replen | `requestedlocationId`==B.id, `sourcelocationname`==B.name, `requestedrackId`==B rack, `stockunitId` unchanged | AC1 |
| `movedUlDirectlyBacksReplen_synced` | moved UL itself backs the replen | synced | AC2 |
| `multiLevelNesting_deepestChildSynced` | 2+ levels of nesting | sync reaches deepest child | AC3 |
| `reservedReplen_notCancelled_synced` | reserved stock backing an active replen moved | replen `state` stays `< 700`; source re-pointed (NOT cancelled) | AC4 |
| `manualSplit_noReplenChange` | `CODE_MANUAL_SPLIT` | no replen mutation | AC5 |
| `shipping_truckLoad_finishedPick_noReplenTouch` | whole-UL outbound move | no replen mutation | AC6 |
| `noActiveReplen_movesCleanly` | SU with no active replen | no exception, no spurious write | AC7 |
| `laterScanThrow_rollsBackSync` | sync commits a re-point, then `scanDestination` throws later in the **same** tx | **whole-tree rollback**: the replen re-point(s) for parent AND every child SU are rolled back, the UL `storagelocation_id` writes are rolled back, and the SBDEV-2481 realigns are rolled back — DB shows the pre-move source for every affected replen | AC8 |
| `startedReplen_blocksMove` | STARTED(500) replen backs source | move blocked (`BusinessException`); UL not moved | AC9 |
| `clubRun530Replen_blocksMove` | `530` (`ORDER_BATCH_CLUB_RUN_FINISHED`) replen backs source | move blocked by `>= STARTED` (decision 6) | AC9 |
| `redirectSource_setsName_e2e` | admin `redirectSource` (different-SU re-point) | `sourcelocationname` updated in DB; `stockunitId`/reservation hand-off still correct | AC10 |
| `context_loads_noCycle` | Spring context with the new service | no DI cycle; bean wiring valid | AC11 |

`MoveStockMoveUnitloadConcurrencyIT` (controller-boundary retry — replaces the dropped vacuous unit test). **All four `BLOCK_REALIGN` entry paths get the retry wrapper; the IT must exercise the `CODE_TRANSFER`/`CODE_MANUAL_TRANSFER` path AND at least one of the `CODE_ON_HOLD` / `CODE_MOVE_FIX_ASSIGNMENT` paths to prove the wrap covers the full BLOCK_REALIGN set, not just the obvious "move" endpoints:**

| Test | Scenario | Expected | AC |
|------|----------|----------|----|
| `concurrentMove_versionConflict_retriesThroughController` | two writers race on the same `Replenishorder` (`@Version`); the move goes **through** `OptimisticLockRetryTemplate.executeWithRetry` at `StockUnitController.transferStock` (`CODE_MANUAL_TRANSFER`) | first attempt throws `StaleObjectStateException`, the wrapper restarts the tx with a fresh persistence context, and the move ultimately succeeds with the correct re-pointed source | decisions 4 + 5 |
| `concurrentOnHold_versionConflict_retriesThroughController` | same `@Version` race driven through `StockUnitController.setLockOnHold` (`CODE_ON_HOLD`) — a non-"move" entry that still reaches the sync | retries through the wrapper and succeeds; proves the wrap-set covers the full `BLOCK_REALIGN_CODES`, not just TRANSFER (closes the round-2 gap) | decisions 4 + 5 |
| `concurrentMove_businessException_notRetried` | the move hits the `>= STARTED` block `BusinessException` under the wrapper | wrapper re-throws on first occurrence (no retry storm); 422 contract preserved | decision 5 |

### Manual test plan

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|----------|-----|-------|----------|-----------|
| 1 | Parent-pallet move, child backs PROCESSABLE replen | staging mobile | move parent A→B | replen source now B; old `TC-OS` and new both resolve to B; no "no unit load at …" |  |
| 2 | Moved UL directly backs replen | staging | web manual move | replen re-pointed |  |
| 3 | Reserved stock, active replen | staging mobile | move UL backing a reserved `300` replen | move succeeds; replen NOT cancelled; re-pointed |  |
| 4 | STARTED replen | staging mobile | move UL backing a `500` replen | blocked (422); old location intact |  |
| 5 | Manual split | staging mobile | split a stockunit (`CODE_MANUAL_SPLIT`) backing a replen | split succeeds; replen untouched |  |
| 6 | Outbound move | staging | ship / truck-load a UL | not blocked, not re-pointed |  |
| 7 | No active replen | staging | move a UL whose stock backs no replen | moves cleanly; no error |  |
| 8 | Admin redirectSource | staging | re-point a replen via admin | `sourcelocationname` updated (not just id) |  |
| 9 | DB sanity | staging DB | run §1 detector after a move | brief non-zero window, then 0 after the sync commits (no sustained mismatch) |  |

### Test execution (fill in after running)

| Command | Result | Pass/Fail/Skipped |
|---------|--------|-------------------|
| `mvn clean compile` (cycle gate) | _to fill_ | |
| context-load test | _to fill_ | |
| `mvn test -Dtest=ReplenishmentOrderSourceSyncServiceTest` | _to fill_ | |
| `mvn test -Dtest=UnitloadBusinessServiceReplenSyncTest` | _to fill_ | |
| `mvn test -Dtest=MobileMoveUnitloadServiceUnitTest` | _to fill_ | |
| `mvn test -Dtest=ReplenishorderServiceUnitTest` | _to fill_ | |
| `mvn verify -Dit.test=ReplenishmentOrderSourceSyncIT -DargLine="-Dapi.version=1.41"` | _to fill_ | |
| `mvn verify -Dit.test=MoveStockMoveUnitloadConcurrencyIT -DargLine="-Dapi.version=1.41"` | _to fill_ | |
| `mvn verify` (full) | _to fill_ | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2492-replen-order-source-sync-on-unitload-move.sh` | _to fill_ | 0 FAIL |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| One-off backfill SQL | N/A — the maintenance cron already heals stale rows; no new stale rows after Fix A (§7.1 #5). |

---

## 9. Risks & Mitigations

| ID | Risk | Impact | Mitigation |
|----|------|--------|-----------|
| R-1 | Sync **halts shipping / truck-load / split** | Critical | Runs only inside SBDEV-2481's `BLOCK_REALIGN` if-block; outbound + `CODE_MANUAL_SPLIT` are PASS_THROUGH and never reach the sync. Unit `processTransfer_passThroughCode_skipsReplenSync` + IT AC5/AC6 prove it. |
| R-2 | **Spring context cycle (HARD startup failure)** | Startup fails | `ReplenishmentOrderSourceSyncService` injects **repositories only** (`ReplenishorderRepository`, `LocationRackRepository`); never `ReplenishorderService`/`*BusinessService`/`changeReservedAmount`. Acyclic by construction; `mvn clean compile` + context-load test (AC11) catch any regression. |
| R-3 | **`StaleObjectStateException`** from concurrent move + cron both touching the replen | 500 | `@Version` optimistic lock; the sync **lets it propagate** and the controller wrapper (`OptimisticLockRetryTemplate.executeWithRetry`, §5.5, decisions 4 + 5) restarts the whole tx with a fresh persistence context. **The wrapper must cover ALL FOUR `BLOCK_REALIGN` entry paths** (the sync fires for every `BLOCK_REALIGN` code, not just TRANSFER): `MoveUnitloadController.selectStock`, `StockUnitController.transferStock`, `StockUnitController.setLockOnHold`/`bulkSetLockOnHold`, `FixLocationAssignmentController.moveFixedAssignment`. **Wrap-set invariant:** if a 5th `BLOCK_REALIGN` code/entry is ever added, its controller must also be wrapped (verify-script's 4-entry assertion guards this). No pessimistic `findByIdForUpdate` (avoids a new lock-order surface). Proven by `concurrentMove_versionConflict_retriesThroughController` + `concurrentOnHold_versionConflict_retriesThroughController` ITs (not a vacuous in-service unit test). |
| R-4 | Wider block radius — a STARTED/530 replen now refuses the move | Medium | Intended (decisions 2 + 6; `>= STARTED` includes `530`). Operator completes/cancels the replen, then moves; surfaced via SBDEV-2116 422. **Whole-tree granularity (operationally material):** because the block throws mid-recursion inside the move's single transaction, **one** STARTED(`>=500`) child replen anywhere in the pallet tree fails the **entire** move — all sibling/child re-points and UL relocations roll back (I-2/AC8). This is the intended atomic behavior (no partial move), but it means a single in-progress replen on one child can block a large pallet move; call it out in operator docs. |
| R-5 | Removing cancel-on-move (Fix B) strands reserved stock that genuinely should not move | Low | The reserved-but-no-replen `throw` is kept; only the *valid-replen* branch changes from cancel→proceed, and the choke-point sync re-points it. AC4 IT proves the replen survives and is re-pointed. |
| R-6 | Per-SU finder on every UL move (perf) | Latency | `findByStateLessThanAndStockunitId` is indexed and returns ≤1 row; runs only on `BLOCK_REALIGN` codes (no per-node lookup on outbound/split). |
| R-7 | `redirectSource` name-set (Fix C) changes admin behavior | Low | Pure additive correctness — sets a field that was being left stale; matches the maintenance re-point. AC10. |

### Acceptance

The machine-checkable acceptance script lives at:

```
sbdocs/9-System/scripts/verify-SBDEV-2492-replen-order-source-sync-on-unitload-move.sh
```

It encodes each rollout item as a grep/test assertion:
- **POSITIVE:** sync call present at `processTransfer:~244`; new service exists and sets `requestedlocationId` + `requestedrackId` + `sourcelocationname`; `>= STARTED` block present; `redirectSource` sets `sourcelocationname`; **all four `BLOCK_REALIGN` controller entries wrap the move call in `OptimisticLockRetryTemplate.executeWithRetry`** — `MoveUnitloadController` (`CODE_TRANSFER`), `StockUnitController.transferStock` (`CODE_MANUAL_TRANSFER`) + `setLockOnHold`/`bulkSetLockOnHold` (`CODE_ON_HOLD`), `FixLocationAssignmentController.moveFixedAssignment` (`CODE_MOVE_FIX_ASSIGNMENT`) (decision 5).
- **NEGATIVE:** `checkReservedStock` no longer calls `cancelReplenishmentOrder`; `processTransfer` does not reference `stockrecordService`; **`ReplenishmentOrderSourceSyncService` does NOT contain `@Retryable`** (guard against the dead-annotation path).

A "DONE" claim with any FAIL line is not accepted. Run it after every implementation pass and paste the `Result: N pass, 0 fail` line into the end-of-task report.

---

## 10. Open Questions / Resolved Decisions

### Resolved product decisions (verbatim)

| # | Decision | Resolution |
|---|----------|-----------|
| 1 | SYNC not cancel | Replace the destructive cancel-on-move in `MobileMoveUnitloadService.checkReservedStock` with re-pointing the active replen order (update `requestedlocation_id` + `requestedrack_id` + `sourcelocationname`; keep reservation + stockunit binding unchanged). |
| 2 | BLOCK STARTED(500) | Sync only PROCESSABLE(300)/RESERVED(400); if the moved source backs a STARTED replen, refuse the move (consistent with SBDEV-2481 `>=500` block). |
| 3 | INCLUDE adjacent fix | `ReplenishorderService.redirectSource` sets `requestedlocationId`/`requestedrackId` but NOT `sourcelocationname` — add `setSourcelocationname`. |
| 4 | CONCURRENCY | Rely on `Replenishorder` `@Version` optimistic lock; retry the sync on `StaleObjectStateException`. No pessimistic `findByIdForUpdate`. |
| 5 | RETRY BOUNDARY | Wrap the move entry controllers in `OptimisticLockRetryTemplate.executeWithRetry` (mirror `TransfersController:108`). This is the faithful realization of decision 4 (optimistic `@Version` retry). `syncForMovedStockUnit` must LET `StaleObjectStateException` PROPAGATE (no internal retry, no `@Retryable`). Add the controller wrap as real edit sites. |
| 6 | BLOCK PREDICATE | Block when replen state `>= STARTED (500)` — this intentionally includes `ORDER_BATCH_CLUB_RUN_FINISHED (530)`. Keep `ro.getState() >= WmsConstants.State.STARTED`. Document that 530 is covered and that's intended. |

### Remaining open questions

| # | Item | Why it matters |
|---|------|----------------|
| G3 | Missing-rack fallback in `syncForMovedStockUnit`: fall back to the raw `destinationLocation.getRackId()` (chosen) vs. strict `null` when the `LocationRack` row is absent. | A valid location always has a rack id; the fallback avoids nulling a previously-valid `requestedrack_id`. Confirm with the replen team whether a null `requestedrack_id` is ever expected. |
| ~~G5~~ | **RESOLVED.** `@Retryable` vs. manual retry loop. | `spring-retry` is confirmed **absent** (no `pom.xml` dependency, no `@EnableRetry`/`@Retryable` in `src/main`). The optimistic-`@Version` retry (decision 4) is realized via `OptimisticLockRetryTemplate.executeWithRetry` at the move-entry controller boundary (decision 5, §5.5), **not** an annotation and **not** an in-service loop. No further action. |
| G8 | Site #8 — `StockunitBusinessService.transferStockToUnitLoad:239` full-move SU-reattach (unreserved-source edge). | The reserved-source path is blocked at `:140`, so this is out of scope here; but an unreserved SU that *still backs an open replen* and is reattached to a different UL would not pass through `processTransfer` and would not be synced. Confirm whether that edge can occur (likely not — an open replen implies a reservation), else add a Hook-B-style sync in a follow-up. |

Open items (G3, G8) persisted to `.omc/plans/open-questions.md`; G5 marked resolved there.

---

## 11. Recommended OMC Composition (for implementation)

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 1 new service + 1 one-line hook + 2 small edits, single subsystem (replenishment + the shared move choke point). |
| **Pre-draft step** | analyst+planner (done) → ralplan consensus (Architect/Critic) | High-blast-radius choke point shared with SBDEV-2481. |
| **Plan-review step** | critic | Standard+. Verify the hook placement and the cycle guard. |
| **Implementation shape** | executor → `wms-tdd-gate` (write the named failing tests first) | Small, well-scoped; a single executor with a TDD gate suffices. |
| **Verification step** | verify-script + verifier | Mandatory. `mvn clean compile` + context-load are hard gates (cycle). |
| **Code-review step** | code-reviewer | Confirm Fix B does not strand reserved stock and the sync preserves the reservation (I-1). |
| **Commit step** | git directly (single logical commit) | One coherent change; depends on SBDEV-2481 already on the branch. |

> **Verify script:** `sbdocs/9-System/scripts/verify-SBDEV-2492-replen-order-source-sync-on-unitload-move.sh`
> - POSITIVE: `processTransfer` `BLOCK_REALIGN` block references `replenishOrderSourceSyncService.syncForMovedStockUnit`; `ReplenishmentOrderSourceSyncService.java` exists and sets `requestedlocationId` + `requestedrackId` + `sourcelocationname`; `>= STARTED` block present; `ReplenishorderService.redirectSource` now sets `sourcelocationname`; **all four `BLOCK_REALIGN` controller entries** (`MoveUnitloadController`, `StockUnitController.transferStock` + `setLockOnHold`/`bulkSetLockOnHold`, `FixLocationAssignmentController.moveFixedAssignment`) wrap the move call in `OptimisticLockRetryTemplate.executeWithRetry`.
> - NEGATIVE: `MobileMoveUnitloadService.checkReservedStock` no longer calls `cancelReplenishmentOrder`; `processTransfer` does NOT reference `stockrecordService` (don't regress 260624); `ReplenishmentOrderSourceSyncService` does NOT contain `@Retryable` (dead-annotation guard).
> - BEHAVIOR: `mvn clean compile` + context-load (cycle gate) + targeted `mvn test`/`mvn verify`.

---

## 12. Completeness Checklist

| Item | Status |
|------|--------|
| §0 every IN site visited by §5; every OUT site has rationale | ✅ (Fix A→#1/#6, Fix B→#2, reuse→#3/#4, Fix C→#5; OUT #7–#10 justified) |
| §1 symptom + repro + exact stale-state SQL + DB-verification block + `db_verified: true` | ✅ |
| §2 Bug 1 (design gap) + Bug 2 (cancel-on-move) + Bug 3 (adjacent) with file:line, broken/missing code, CLAUDE.md citation | ✅ |
| §3 regression chain — explicitly NOT a regression (cron-masked design gap) | ✅ |
| §4 ASCII flow (move-UL → processTransfer recursion → NEW sync) + Key Files table | ✅ |
| §5 Fix A (new service + hook), Fix B (cancel→proceed), Fix C (additive name-set), §5.5 controller retry wrap, with before/after, minimal diff | ✅ |
| Retry boundary at controllers (decision 5); sync propagates `StaleObjectStateException`; no `@Retryable`/spring-retry anywhere | ✅ |
| Retry wrap covers ALL FOUR `BLOCK_REALIGN` entries (TRANSFER, MANUAL_TRANSFER, MOVE_FIX_ASSIGNMENT, ON_HOLD), not just the two move endpoints; wrap-set invariant documented; verify-script asserts all four (round-2 gap closed) | ✅ (§5.5, §6, §7.2, §8, R-3) |
| Block predicate `>= STARTED` documented to include 530 (decision 6) | ✅ (§5.1, tests, R-4) |
| §6 File Change Summary table (incl. both controller edit rows) | ✅ |
| §7 ordered atomic steps + §7.1 Prerequisites (backfill N/A stated explicitly) + controller-wrap step | ✅ |
| §8 Unit / Integration / Regression + Manual test table; Mockito 3.3.3, `@MockBean OAuth2RestTemplate`, `api.version=1.41`; concrete test classes mapped to ACs; vacuous internal-retry unit test dropped; controller-driven concurrency IT added; AC8 whole-tree rollback asserted | ✅ |
| §9 Risks table (R-3 retry-via-controller, R-4 whole-tree block granularity) + Acceptance subsection referencing the verify-script path | ✅ |
| §10 resolved decisions 1–6 verbatim; G5 closed; G3/G8 open | ✅ |
| Signatures verified against live tree; corrections noted | ✅ (Optional return type; redirectSource is a different-SU re-point with changeReservedAmount `:160`/`:180` + `setStockunitId:175`; rack fallback; spring-retry confirmed absent; `OptimisticLockRetryTemplate` confirmed present) |
| v2 Horizontal Scalability + v2-only checklists | ⏭️ Skipped (v1 plan) |
| Verify script written + `chmod +x` | ✅ (companion file) |

---

## 13. Implementation Status

**Status:** implemented on branch `fix/SBDEV-2492-replen-source-sync-on-unitload-move` (v1/wms-api). Date: 2026-06-25. Commit `e0ff548`. PR: [SiteBossInc/wms-api#183](https://github.com/SiteBossInc/wms-api/pull/183) → `develop`.

### Changes landed
| File | Change |
|------|--------|
| `service/ReplenishmentOrderSourceSyncService.java` (NEW) | Repos-only (`ReplenishorderRepository` + `LocationRackRepository`), acyclic. `syncForMovedStockUnit`: finder → null-returns; `state >= STARTED` (covers 530) throws `BusinessException`; re-points `requestedlocationId`/`requestedrackId`/`sourcelocationname`; saves; never touches `stockunitId`/reservation (I-1); lets `StaleObjectStateException` propagate (no `@Retryable`). `@Transactional(rollbackFor=Exception.class)` (REQUIRED propagation → joins the move's tx; AC8 atomic rollback verified). |
| `service/UnitloadBusinessService.java` | Field-injected the new service; added `syncForMovedStockUnit(su, destinationLocation)` inside the existing SBDEV-2481 `BLOCK_REALIGN` if-block in `processTransfer`, after `realignForMovedStockUnit`. No `stockrecordService` added (260624 invariant kept). |
| `service/mobile/MobileMoveUnitloadService.java` | Fix B: removed `cancelReplenishmentOrder` from the valid-replen branch (now `continue`); reserved-but-no-replen `throw` guard kept. |
| `service/ReplenishorderService.java` | Fix C: added `setSourcelocationname(location.getName())` in `redirectSource`; `changeReservedAmount`/`setStockunitId` untouched. |
| `controller/mobile/MoveUnitloadController.java`, `controller/StockUnitController.java` (×3: `transferStock`/`setLockOnHold`/`bulkSetLockOnHold`), `controller/FixLocationAssignmentController.java` | §5.5: wrapped all four `BLOCK_REALIGN` entry points in `OptimisticLockRetryTemplate.executeWithRetry` (decision 5). `TransferOrderController` left unwrapped (PASS_THROUGH). `catch (Exception)` added after the existing `BusinessException`/`FacadeException` handlers (mirrors `TransfersController`; 422 contract preserved — verified). |

### Tests
- **Unit (GREEN):** `ReplenishmentOrderSourceSyncServiceTest` (AC1/AC7/AC9/I-1/dec5/dec6), `UnitloadBusinessServiceReplenSyncTest` (AC1/AC3/AC5/AC6), `MobileMoveUnitloadServiceUnitTest` (AC4 + kept-guard), `ReplenishorderServiceUnitTest` (AC10). Independently re-run by a separate review pass.
- **Integration (`@Disabled`):** `ReplenishmentOrderSourceSyncIT` (AC1–AC11) and `MoveStockMoveUnitloadConcurrencyIT` (decisions 4+5). ⚠️ **These are SCAFFOLDING, not executable coverage** — their bodies are `fail("TODO…")`-stubbed and the classes are `@Disabled("SBDEV-2384")` because the v1 `@SpringBootTest` IT lane cannot boot (`ro_id` view drift). They compile and capture the §8 contract; **AC2, AC8 (whole-tree atomic rollback), and the concurrency-retry behavior have NO executable test today** — they rest on the unit tests + static review (AC8 propagation verified by review: REQUIRED, not REQUIRES_NEW). **Follow-up: flesh out the IT bodies when SBDEV-2384 restores the IT lane.**

### Verification (Java 8 — `8.0.412-tem`; SDKMAN default is 21, must override)
| Command | Result |
|---------|--------|
| `mvn clean compile` | BUILD SUCCESS (cycle/compile gate, R-2) |
| `mvn test -Dtest=ReplenishmentOrderSourceSyncServiceTest,MobileMoveUnitloadServiceUnitTest,ReplenishorderServiceUnitTest,UnitloadBusinessServiceReplenSyncTest,UnitloadBusinessServiceUnitTest` | `Tests run: 101, Failures: 0, Errors: 0, Skipped: 0` |
| `bash sbdocs/9-System/scripts/verify-…-2492-….sh` | `Result: 31 pass, 0 fail, 0 skip` |
| `mvn verify` (full Testcontainers suite) | NOT run (v1 IT lane blocked by SBDEV-2384) |

> ⚠️ The verify-script's `T-IT`/`T-CIT` PASS lines pass only because `mvn verify` skips the `@Disabled` IT classes — they do **not** prove IT-level behavior.

### Review
Independent `code-reviewer` pass (separate context) re-ran all three gates green and returned **APPROVE**: 0 CRITICAL/HIGH, AC8 atomicity holds (REQUIRED propagation), controller HTTP contract preserved, unit tests genuine/non-vacuous. Conditions: record IT-stub status honestly (done above) + file follow-up for the IT bodies.
