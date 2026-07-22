---
title: "SBDEV-2074 (V2): Replenishment Reservations Not Released/Reassigned When Unit Load Moved to a Non-Replenishable Location"
ticket: "SBDEV-2074"
ticket_url: "https://app.clickup.com/t/868j452bd"
type: bug
priority: high
status: archived
project:
  - wms2
version: v2
requester: WineCo (client-reported)
created: 2026-07-19
archived: 2026-07-20
updated: 2026-07-19
db_verified: true
related:
  - "../../../4-Archieves/wms2/plan/SBDEV-2492-replen-order-source-sync-on-unitload-move.md"
  - SBDEV-2481
  - 260626-restore-replenishment-triggers-on-lock-state-changes
  - 260709-multi-unitload-replen-reserve-availability-guard
  - SBDEV-2217
tags:
  - plan
  - replenishment
  - reservation
  - move-unitload
  - transfer-lane
  - sbdev-2074
  - v2
---

# SBDEV-2074 (V2): Replenishment Reservations Not Released/Reassigned When Unit Load Moved to a Non-Replenishable Location

> **Archived 2026-07-20** — implemented and merged via wms2-api PR [#82](https://github.com/SiteBossInc/wms2-api/pull/82) (→ develop).
> Acceptance script retained at `sbdocs/9-System/scripts/verify-SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.sh`.

**Ticket:** [SBDEV-2074](https://app.clickup.com/t/868j452bd)
**Project:** v2/wms2-api (Java 21 / Spring Boot 3.5.9) | **Version:** v2 | **Type:** Bug (design gap + a regression the SBDEV-2492 blind re-point made worse)
**Priority:** High (replenishment reservation stranded on a location that can never source it; masked intermittently by the maintenance cron and by client-side manual fixes)
**Status:** IMPLEMENTED 2026-07-20 (ralplan consensus 2026-07-19 → TDD gate → implemented → code-review APPROVE 0 High/4 Medium all fixed + M5 documented). See §11.
**Date:** 2026-07-19
**Requester:** WineCo (client-reported)

> **Sibling plan:** [`SBDEV-2492 (V2)`](../../../4-Archieves/wms2/plan/SBDEV-2492-replen-order-source-sync-on-unitload-move.md) — added the `ReplenishmentOrderSourceSyncService` blind re-point at the move choke point. That fix is correct for a move **between replenishable** locations; this plan makes the same choke point **replenishability-aware** so a move onto a **non-replenishable** lane no longer re-points a live reservation onto a location that can never satisfy it.
>
> **v2 package note:** JPA repositories under `net/aim_ai/wms/repo/jpa/`. `Replenishorder` extends `AbstractBaseEntity` (`@Version Integer` at `AbstractBaseEntity:34-35` → ID-equality + optimistic lock). State constants in `net/aim_ai/wms/service/WmsConstants.java` (`WmsConstants.State`). Tenant writes carry `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})`; a bare `@Transactional` routes to the `@Primary` **landlord** TM and disables tenant-write rollback.

---

## 0. Affected Sites (enumeration)

Every relocation entry path that can move a `Stockunit`/`Unitload` onto a location whose `area.useforreplenish = false`. "Reaches choke point" = flows through `UnitloadBusinessService.processTransfer` and its `BLOCK_REALIGN` branch (where the SBDEV-2492 sync fires). "In scope" rows are each visited by §5.

| # | Entry path / site | File:line (v2) | Reaches choke point? | Currently replenishability-aware? | In scope | §5 coverage |
|---|-------------------|----------------|----------------------|-----------------------------------|:--------:|-------------|
| 1 | Web manual move → `transferUnitLoadToLocation` → `processTransfer` `BLOCK_REALIGN` | `UnitloadBusinessService.java:290-296` (tx `:113`) | Yes | **No** (blind re-point) | **YES** | Fix A + Fix B |
| 2 | Mobile move-unit-load → `MobileMoveUnitloadService` → `transferUnitLoadToLocation` | `MobileMoveUnitloadService.checkReservedStock:188-203` → `UnitloadBusinessService:113` | Yes | **No** | **YES** | Fix B (inherits) |
| 3 | On-hold relocation → `StockunitService.setLockOnHold` → `transferUnitLoadToLocation` | `StockunitService.setLockOnHold:296-345` (`:337`) | Yes | **No** | **YES** | Fix B (inherits); NEW-1 tx from SBDEV-2492 already on branch |
| 4 | Transfer-order build onto a transfer/staging lane | `MobileTransferOrderService.transferStock:387-410` | n/a | n/a | **NO** | **Verified no stranding** — reserved stock is left at source (`:404` "Bring back reserved stock"); the whole-UL-to-lane branch (`transferUnitLoadToLocation:392`) is `reservedamount==0` guarded (`:388`) → §10 resolved finding |
| 5 | Bare stock move `StockunitService.transferStock` (SBDEV-2033 invariant surface) | `StockunitService.transferStock:150` | n/a | n/a — trigger intentionally removed | **YES (guard)** | §5 invariant I-3 (do NOT re-add `recalculateForItem`) |
| 6 | Palletize / build-pallet (`CODE_*` build) | `MobilePalletizingService` | No (PASS_THROUGH) | n/a | No | — |
| 7 | Manual split (`CODE_MANUAL_SPLIT`) | classifier PASS_THROUGH | No | n/a | No | — |
| 8 | Shipping / truck-load (`CODE_SHIPPING` / `CODE_TRUCK_LOADING`) | classifier PASS_THROUGH | No | n/a | No | — |
| 9 | Carrier nesting | classifier PASS_THROUGH | No | n/a | No | — |
| 10 | Maintenance cron — recalc (`recalculateOrder`→`ensureValidSource`→`redirectSource`/`cancelOrder`) + `ReplenishOrderJob.cancelUnreachableReplenishment` | `ReplenishmentOrderMaintenanceService:91,115,155,252-263`; `ReplenishOrderJob:269-295` | n/a (backstop) | **Partial — only state ≤ 300** (recalc needs `state==300`; cancelUnreachable needs `state<=300`) → **RESERVED 400 falls through both** | No (documented coexistence — Q5) | §2 RC1, §7-HScale row 8, §10 Follow-ups |

**In-scope rows (1-3, 5) all visited by §5:** rows 1-3 are the choke-point paths (Fix A new primitive + Fix B branch); row 5 is the SBDEV-2033 self-exclusion invariant (I-3). **Row 4 (transfer-order build) is out of scope** — verified: the whole-UL-to-lane branch is `reservedamount==0` guarded (`:388`,`:392`) and reserved stock is deliberately left at source (`:404`), so no reservation is stranded there (§10 resolved finding D2b). Rows 6-9 are PASS_THROUGH and never reach a replen write (AC5). Row 10 is the cron backstop — a **partial** one that heals only state ≤ 300, leaving **RESERVED (400) durably stranded** (RC1).

---

## 1. Problem Statement

### User-Visible Symptom (from ticket, WineCo)

An operator moves a unit load (or builds it onto a **transfer/staging lane** via a transfer order) that is backing an **open, reserved** replenishment order. The lane's area is flagged `useforreplenish = false` (transfer lanes, staging, dock — locations that must never be a replenishment *source*). After the move:

- The reservation on the moved stock **stays bound** to the replen, and
- The replen's recorded source is **re-pointed onto the non-replenishable lane** (post-SBDEV-2492 behaviour) — a location the replenishment engine will never pick from.

Result: the reservation is **stranded**. The stock reads as "reserved for replenishment" so it is excluded from other allocation, yet the replenishment run can never source it (its source area is `useforreplenish=false`). The replen sits open and the destination stays short.

### Severity framing (two tiers — see RC1 for the cron mechanics)

The impact depends on the replen's state, because the cron backstop only reaches state ≤ 300:

- **RESERVED (400) — durably stranded (strongest justification).** A replen that has already reserved its stock (`reservedamount` set — the ticket's "reserved qty = 6") is at state 400. The cron **recalc** path requires `state == 300` and the cron **cancelUnreachable** path requires `state <= 300`, so a RESERVED (400) replen whose source moved onto a `useforreplenish=false` lane is healed by **neither** — it stays stranded until a manual DB fix. This is exactly the ticket repro.
- **PROCESSABLE (300) — transient window.** A state-300 replen is eventually reassigned or cancelled by the cron recalc (`ensureValidSource` → `redirectSource`/`cancelOrder`) on the next pass, but in the window between the move and that pass the stale/unreachable source causes the immediate downstream transfer/club-execution errors the ticket also reports. The synchronous fix closes this window.

### Reproduction (v2)

1. Place stock on a UL, fully reserved (`reservedamount == requestedamount`), backing a PROCESSABLE (`300`) or RESERVED (`400`) replenishment order sourced from a replenishable pick face.
2. Move that UL — or its parent pallet — onto a **transfer/staging lane** (area `useforreplenish=false`) via **move-unit-load / manual move** (web or mobile). The SBDEV-2492 choke point **re-points** the source triple onto the lane (RC2). (The transfer-order build path is *not* a repro — it leaves reserved stock at source; see §2.)
3. Run (or wait for) a replenishment cycle: the destination is never replenished from this stock. For a **RESERVED (400)** replen the reservation is **durably stranded** (neither cron path heals state 400); for a **PROCESSABLE (300)** replen the stale source causes downstream errors until the next cron pass.

### DB-Verification (inline)

`db_verified: true`. Verified against **`wms2-wineco-dev`** on 2026-07-19.

**Detector query** (open replen whose recorded source location sits in a non-replenishable area):

```sql
-- Stranded-reservation detector: open replen whose source location's area
-- cannot be used for replenishment (useforreplenish=false).
SELECT ro.id            AS replen_id,
       ro.state,
       ro.stockunit_id,
       ro.requestedlocation_id,
       ro.sourcelocationname,
       a.name           AS area_name,
       a.useforreplenish
FROM   replenishorder ro
JOIN   location l ON l.id = ro.requestedlocation_id
JOIN   area     a ON a.id = l.area_id
WHERE  ro.state < 700                 -- open orders
  AND  a.useforreplenish = false;     -- source area can never replenish
-- Expected: >0 rows in the window between the move and the cron backstop.
```

**Findings on `wms2-wineco-dev`:**

| Check | Result |
|-------|--------|
| Areas with `useforreplenish = false` | **6 of 8** areas |
| Transfer/staging lanes | **all 26** lanes belong to `useforreplenish = false` areas — i.e. every transfer/staging destination is a non-replenishable source |
| `replenishorder` columns | confirmed present: `stockunit_id`, `requestedlocation_id`, `sourcelocationname`, `requestedrack_id`, `state`, `version` |
| Detector rows (open replens scanned) | **0 / 562** open replens matched today on dev |

**Why 0 rows on dev is expected, not a refutation:** the maintenance cron reassigns-or-cancels stale `state == 300` rows on its cadence (and `cancelUnreachableReplenishment` cancels `state <= 300`), and **WineCo prod carries manual DB fixes** for previously-stranded reservations, so dev's steady-state count is near zero. The genuine defect is a **structural gap at state 400 (RESERVED)** — healed by neither cron path (RC1) — plus a **transient window** for state 300 (move → next cron pass). The topology check is the load-bearing evidence: 26/26 transfer lanes + 6/8 areas are `useforreplenish=false`, so the choke point *will* re-point live reservations onto non-replenishable sources. Re-run against client prod/UAT specifically looking for **RESERVED (400)** rows, which the cron never clears.

> **Implementer action:** re-run the detector against the **client production/UAT DB** (not dev) immediately before merge — WineCo prod's manual fixes mask the count on shared dev, and a fresh non-zero count on prod is the true confirmation.

---

## 2. Root Cause Analysis

Three interacting causes. RC1 removed the synchronous trigger; RC2 filled the vacuum with a blind re-point (correct only for replenishable→replenishable moves); RC3 leaves the transfer-order path with no handling at all.

### RC1 — The move triggers no synchronous replenishment reaction, and the cron backstop only reaches state ≤ 300 (RESERVED 400 falls through)

**Site:** `StockunitService.transferStock:150` (no synchronous reaction); the cron heals via two real mechanisms, neither of which reaches state 400.

**What happened.** SBDEV-2033 **removed** the `recalculateForItem(...)` call from `StockunitService.transferStock` (it caused a self-depleting recalculation on move). After that removal, a stock/UL move performs **no** synchronous replenishment reaction. Healing is left entirely to the maintenance cron — which is **not** cancel-only (correcting a common misreading). There are **two** real cron mechanisms:

- **(a) Recalc path (reassigns OR cancels, but only state 300).** `recalculateOpenOrders` (`:91`, `findByState(PROCESSABLE)`) and `recalculateForItem` (`:115`, `findByStateAndItemdataId(PROCESSABLE, …)`) fan into `recalculateOrder` (`:155`), which **bails immediately if `state != PROCESSABLE`**. It then calls `ensureValidSource` (`:252-263`): if `!isSourceUsable` → `redirectSource` (`:258` — **REASSIGNS** to a live candidate) else `cancelOrder` (`:261`). So a **PROCESSABLE (300)** replen whose source moved onto a non-replenishable lane **is** reassigned (or cancelled) by the cron — on the next pass.
- **(b) `ReplenishOrderJob.cancelUnreachableReplenishment` (`:269-295`) — this exists and is real.** It pages `getIdsForUnreachableReplenishOrdersPage(State.PROCESSABLE, …)`, whose query is `WHERE la.useforreplenish=false AND replenishorder.state <= :state` (state = 300), and calls `cancelReplenishmentOrder`. **Cancel-only, and only for `state <= 300`.**

**Why it fails here — the genuine gap.** With the confirmed state ladder (`PROCESSABLE=300`, `RESERVED=400`, `STARTED=500`, `ORDER_BATCH_CLUB_RUN_FINISHED=530`, `FINISHED=700`, `CANCELED=800`), a **RESERVED (400)** replen whose source moved onto a `useforreplenish=false` lane is healed by **neither** cron path: recalc requires `state == 300`, and cancelUnreachable requires `state <= 300`. State 400 falls through both → **durably stranded** (the ticket's "reserved qty = 6" shape). For **PROCESSABLE (300)** there is additionally a **transient window** before the next cron pass, during which the stale/unreachable source causes the immediate downstream transfer/club-execution errors the ticket reports. The synchronous fix (a) durably closes the RESERVED-400 hole and (b) removes the 300 transient window.

> **Invariant I-3 (do NOT re-open the SBDEV-2033 regression):** the fix must **not** re-add `recalculateForItem` to `StockunitService.transferStock`. The moved SU now sits on a `useforreplenish=false` area, so it **self-excludes** from the candidate finder (`StockunitRepository.getAvailableReplenishmentSources(itemDataId)`, called inside `redirectSource`) — reassignment picks a *different* live source without any global recalc. This is stated as AC9 (renumbered).

### RC2 — `syncForMovedStockUnit` blindly re-points the source triple onto the lane

**Site:** `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit(...)` (introduced by SBDEV-2492), called at `UnitloadBusinessService.java:294` inside the `BLOCK_REALIGN` loop.

**Broken behaviour (post-SBDEV-2492).** The sync unconditionally re-points the source triple (`requestedlocationId` + `requestedrackId` + `sourcelocationname`) onto **whatever destination the UL moved to** — including a transfer/staging lane:

```java
// current (SBDEV-2492) — no replenishability check on the destination
ro.setRequestedlocationId(destinationLocation.getId());
ro.setRequestedrackId(rackId);
ro.setSourcelocationname(destinationLocation.getName());
replenishorderRepository.save(ro);   // now points at a useforreplenish=false lane
```

**Why it fails.** Re-pointing a live reservation's source onto a `useforreplenish=false` location produces a replen the engine can never satisfy from — the reservation is stranded and the destination stays short. SBDEV-2492's re-point is correct for a replenishable→replenishable move; it has **no branch** for a non-replenishable destination.

### (Investigated, NOT a cause) — transfer-order build path

An earlier hypothesis held that the transfer-order build path (`MobileTransferOrderService.transferStock`) strands a reservation on the lane because it is PASS_THROUGH. **Verified against the code (`:387-410`), this is NOT a defect:** the whole-UL-to-lane move (`transferUnitLoadToLocation:392`) is guarded by `reservedamount == 0` (`:388`). When stock **is** reserved, the method moves only `availableamount` via `transferStockToUnitLoad` and returns `"Bring back reserved stock"` (`:404`) — the RESERVED portion is deliberately **left at the source** and never moved onto the lane. So no reservation is stranded on this path; there is nothing to fix here. Recorded as resolved finding **D2b** in §10 (the "cover the transfer-lane build path" user decision is rendered moot by this code fact). **Fix C is dropped.**

---

## 3. The Regression / Design Chain

| When | Change / plan | What it did | Effect on this bug |
|------|---------------|-------------|--------------------|
| earlier | **SBDEV-2033** — remove `recalculateForItem` from `transferStock` | Killed the self-depleting synchronous recalc on move | Removed the synchronous replenishment reaction → **RC1** (healing left to the cron, which reaches only state ≤ 300 — RESERVED 400 falls through) |
| earlier | **SBDEV-2481** — stale pick-line realignment on stock move | Added the `BLOCK_REALIGN` classifier + loop in `processTransfer` | Created the choke point Fix A/B hook beside |
| SBDEV-2492 | **`ReplenishmentOrderSourceSyncService`** blind re-point at the choke point | Re-points the source triple onto the move destination | Correct for replenishable→replenishable; **RC2** for replenishable→non-replenishable |
| `260626` | restore replenishment triggers on lock-state changes | Restored some replen triggers on lock changes | Related trigger surface; not the move path |
| `260709` | multi-unitload replen reserve availability guard | Guards duplicate/over-reserve on concurrent generation | Same reservation domain; interacts with the candidate finder `StockunitRepository.getAvailableReplenishmentSources(itemDataId)` reused inside `redirectSource` |

Net: RC1 removed the synchronous trigger and the cron backstop reaches only state ≤ 300 (RESERVED 400 durably stranded); RC2 replaced the trigger with a re-point that is blind to replenishability. (The transfer-order build path was investigated and is **not** a cause — reserved stock stays at source; see §2.)

---

## 4. Architecture Overview

```
 relocation entry points                                                          replen domain
 ─────────────────────                                                            ────────────

 web manual move ┐
 mobile move UL  ├─► UnitloadBusinessService.transferUnitLoadToLocation           ReplenishmentOrderMaintenanceService
 on-hold (:337)  ┘   (@Transactional tenantTransactionManager :113)                (cron owner; private redirectSource:308 /
                         │                                                          cancelOrder:415 / releaseReservation:427;
                         └─► processTransfer ─► classify(activityCode)              candidate finder is StockunitRepository.
                                 │                                                  getAvailableReplenishmentSources INSIDE
                                 │                                                  redirectSource)
                                 ├─ PASS_THROUGH (ship/split/truck) ─► no replen action   ▲
                                 │                                                        │  Fix A: NEW public
                                 └─ BLOCK_REALIGN ─► for SU in tree:                      │  reassignOrCancelForMovedStockUnit
                                       ├─ pickLineRealignmentService.realign… (2481)      │  (reuses redirectSource/cancelOrder)
                                       └─ ReplenishmentOrderSourceSyncService  ◄══ CHOKE ═╝
                                             (Fix B branch on dest replenishability)
                                               ├─ dest.area.useforreplenish=true  ─► re-point (SBDEV-2492, unchanged)
                                               └─ dest.area.useforreplenish=false ─► reassignOrCancelForMovedStockUnit (Fix A)

 (transfer-order build ─► MobileTransferOrderService.transferStock:387-410 — NOT in scope:
   reserved stock left at source :404; whole-UL-to-lane branch is reservedamount==0 guarded :388,:392)
```

### Key Files

| File | Role | Change |
|------|------|--------|
| `service/ReplenishmentOrderMaintenanceService.java` | Cron owner; holds private `redirectSource:308` / `cancelOrder:415` / `releaseReservation:427`; `ensureValidSource:252-263` is the reuse template | **Fix A** — new public `reassignOrCancelForMovedStockUnit` |
| `service/ReplenishmentOrderSourceSyncService.java` | SBDEV-2492 choke-point sync | **Fix B (shape i)** — branch on `dest.area.useforreplenish`; inject the maintenance service via a **`@Lazy` constructor parameter** (cycle-breaker — Correction 4) |
| `service/UnitloadBusinessService.java` | Move choke point (`processTransfer` `BLOCK_REALIGN`) | wiring only (already calls the sync at `:294`) — **no change** |
| `service/StockunitService.java` | `transferStock:150` (SBDEV-2033 surface) | **no change** — I-3 guard (do not re-add `recalculateForItem`) |
| `repo/jpa/ReplenishorderRepository.java` | `findByStateLessThanAndStockunitId:91-92`, `findByIdForUpdate:27-29` | reuse |
| `repo/jpa/StockunitRepository.java` | `getAvailableReplenishmentSources(itemDataId)` — candidate finder, called **inside** `redirectSource` | reuse (no direct call from new code) |
| `service/WmsConstants.java` | `State` constants (300/400/500/530/700/800) + `CODE_REPLENISHMENT_CANCELLED` | reuse |

---

## 5. Fix Design

### Invariants

- **I-1 (reservation semantics preserved):** re-point (replenishable dest) never touches `stockunitId`/`reservedamount`. Reassign/cancel (non-replenishable dest) **does** move/release the reservation, by design — via the cron's own `redirectSource`/`cancelOrder` primitives, never by ad-hoc setters. Note `redirectSource:327` may **downsize** `requestedamount` to the alternate's available quantity (expected — see Fix A).
- **I-2 (atomic per move tree):** all writes run inside the move's single tenant transaction (REQUIRED). A later `BusinessException` rolls back every relocation + realign + reassign — no partial state (AC7).
- **I-3 (SBDEV-2033 not re-opened):** do **not** re-add `recalculateForItem` to `StockunitService.transferStock`. The moved SU (now on `useforreplenish=false`) self-excludes from `StockunitRepository.getAvailableReplenishmentSources(itemDataId)` (called inside `redirectSource`), so reassignment finds a *different* source without a global recalc (AC9).

### Fix A — new public `reassignOrCancelForMovedStockUnit` on `ReplenishmentOrderMaintenanceService`

**Why here (not a new class):** the reassign/cancel logic needs the cron's **private** primitives — `redirectSource` (`:308`) and `cancelOrder` (`:415`). A public method on the *same* class reuses them directly without widening any visibility (Q2). It mirrors the cron's own `ensureValidSource:255-262`. The candidate finder is **not** a maintenance-service method — it is `StockunitRepository.getAvailableReplenishmentSources(itemDataId)`, called **inside** `redirectSource`, so the new code never references it directly.

**Verified real signatures (do not invent):**
- `redirectSource(Replenishorder order, Stockunit currentSource)` — `:308`; finds a candidate via `StockunitRepository.getAvailableReplenishmentSources(itemDataId)` internally, releases the old reservation (`:333`), reserves the new (`:349`), keeps the **same** order id, saves (`:346`); **returns `false` when there is no candidate OR the reservation fails**.
- `cancelOrder(Replenishorder order, Stockunit currentSource, String activityCode)` — `:415`.
- `releaseReservation(Stockunit, BigDecimal)` — `:427` (used inside `redirectSource`/`cancelOrder`; the new method does not call it directly).
- There is **no** `getAvailableReplenishmentSources(Replenishorder)` and **no** `ReplenishmentSource` type.

**Signature + shape (Option B, pessimistic, v2-consistent) — mirrors `ensureValidSource:255-262`:**

```java
/** Handle an active replen bound to a Stockunit whose UL has moved onto a
 *  NON-replenishable destination. Reassign to another live source if one exists,
 *  else cancel. Blocks (throws) if the replen is already STARTED (>=500, incl. 530).
 *  Joins the caller's tenant tx (REQUIRED); findByIdForUpdate serializes with the
 *  cron on the same row (must be in a tx). */
@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRED,
               rollbackFor = { BusinessException.class, FacadeException.class })
public void reassignOrCancelForMovedStockUnit(Stockunit movedStock, Location destination) throws BusinessException {
    // AC5: replenishable destination -> no-op; the SBDEV-2492 re-point stays in charge.
    if (isReplenishableDestination(destination)) {
        return;
    }
    Replenishorder probe = replenishorderRepository
        .findByStateLessThanAndStockunitId(WmsConstants.State.FINISHED, movedStock.getId())
        .orElse(null);
    if (probe == null) {
        return;                                                   // AC6: no active replen -> no write
    }
    Replenishorder order = replenishorderRepository.findByIdForUpdate(probe.getId())  // AC8: serialize w/ cron
        .orElseThrow(() -> new EntityNotFoundException("Replenishorder", probe.getId()));
    if (order.getState() >= WmsConstants.State.STARTED) {         // D1 / AC4: block in-progress (incl. 530)
        throw new BusinessException(
            "Replenishment in progress for this stock; complete or cancel it before moving.");
    }
    // Mirror ensureValidSource:255-262. redirectSource keeps the SAME order id, releases the old
    // reservation (:333) and reserves at a fresh candidate (:349); it returns false when there is
    // no candidate OR the reservation fails (Q6).
    if (redirectSource(order, movedStock)) {
        // reassigned to a live source, same order id (AC2)
    } else {
        cancelOrder(order, movedStock, WmsConstants.CODE_REPLENISHMENT_CANCELLED);  // AC3: no alternate -> cancel; move still proceeds
    }
}
```

- **Downsizing note (Fix A + R-5 — expected behavior):** `redirectSource:327` sets `requestedamount = min(requestedamount, candidate.available)`. So reassignment can **silently downsize** the replen if the alternate source holds less than the original request. This is expected (it matches the cron's own behavior); it is called out so reviewers/operators are not surprised by a smaller replen after a move.
- **Why-this-not-alternatives:** the alternative "grow `ReplenishmentOrderSourceSyncService` to own reassignment" (a new class) would need `redirectSource`/`cancelOrder` promoted to package/public — widening the cron's private surface for no gain (rejected, §10 D2). Extracting a shared repos+`StockunitBusinessService`-only collaborator is held as the **DI-cycle fallback** only (see §10 D2 / Q1).
- **Q6 handling:** `redirectSource` returning `false` (no candidate OR reservation failed) → the method **cancels and allows the move** (`cancelOrder` releases the old reservation internally). A move must not be blocked by an inability to reserve elsewhere; the destination simply stays short and the next generation re-creates the replen.
- **Q5 coexistence:** the cron heals only state ≤ 300 (recalc needs `state==300`; `cancelUnreachableReplenishment` needs `state<=300`). This synchronous method is what durably covers **RESERVED (400)**. Both this method and the cron take `findByIdForUpdate` on the `replenishorder` row → serialized (no lost update). Making the **cron recalc** also process RESERVED(400)/other open states is the real cron limitation and an out-of-scope durable complement (§10 follow-up).

### Fix B — make the choke point replenishability-aware

The `BLOCK_REALIGN` loop at `UnitloadBusinessService.java:290-296` already calls the SBDEV-2492 sync at `:294`. We must branch on the **destination's** replenishability. Two shapes:

**Shape (i) — RECOMMENDED. Branch inside `ReplenishmentOrderSourceSyncService`.**
Grow the existing `syncForMovedStockUnit` to decide:

```java
// ReplenishmentOrderSourceSyncService constructor — the @Lazy PARAMETER on the maintenance-service
// edge is the cycle-breaker (Correction 4): Spring only injects a lazy proxy when @Lazy sits on the
// injection point. Precedent: ReplenishmentOrderMaintenanceService already uses a @Lazy self field (:78-80).
public ReplenishmentOrderSourceSyncService(
        ReplenishorderRepository replenishorderRepository,
        LocationRackRepository locationRackRepository,
        @Lazy ReplenishmentOrderMaintenanceService replenishmentOrderMaintenanceService) { ... }

public void syncForMovedStockUnit(Stockunit su, Location destination) throws BusinessException {
    if (isReplenishableDestination(destination)) {              // dest.area.useforreplenish == true
        repointSourceTriple(su, destination);                  // SBDEV-2492 behaviour, unchanged (AC1)
    } else {
        replenishmentOrderMaintenanceService
            .reassignOrCancelForMovedStockUnit(su);             // Fix A (AC2/AC3) — Stockunit only
    }
}

private boolean isReplenishableDestination(Location dest) {
    return dest.getArea() != null && Boolean.TRUE.equals(dest.getArea().getUseforreplenish());
}
```

- **Pros:** the replenishability decision lives in the replen-domain service; the `UnitloadBusinessService` loop stays a single unchanged call (`:294`); shipping/split PASS_THROUGH still never reach it (AC5); one place to test the branch.
- **Cons:** `ReplenishmentOrderSourceSyncService` now depends on `ReplenishmentOrderMaintenanceService` — a **potential DI cycle** (see §8 hard gate + §10 D2 fallback). **Cycle-breaker (Correction 4):** a `@Lazy` **constructor parameter** on that new injection edge (not `UnitloadBusinessService`'s class-level `@Lazy` at `:31` — class-level `@Lazy` does **not** lazy-proxy the hard `StockunitBusinessService → UnitloadBusinessService` constructor edge at `:42`/`:64`; a lazy proxy is injected only when `@Lazy` is on the injection point). Precedent for the pattern: the maintenance service already uses a `@Lazy @Autowired` self field at `:78-80`.

**Shape (ii) — alternative. Branch in the `UnitloadBusinessService` loop.**

```java
for (Stockunit movedSu : stockunitRepository.findByUnitloadId(unitload.getId())) {
    pickLineRealignmentService.assertNoActivePickFor(movedSu.getId());
    pickLineRealignmentService.realignForMovedStockUnit(movedSu, unitload, destinationLocation);
    if (replenishmentOrderSourceSyncService.isReplenishableDestination(destinationLocation)) {
        replenishmentOrderSourceSyncService.syncForMovedStockUnit(movedSu, destinationLocation);
    } else {
        replenishmentOrderMaintenanceService.reassignOrCancelForMovedStockUnit(movedSu);
    }
}
```

- **Pros:** the sync service keeps a single responsibility (re-point only); the branch is visible at the call site.
- **Cons:** puts replen-domain policy in `UnitloadBusinessService`; adds a *second* replen collaborator to that class (wider DI surface + a new `@Lazy` field); duplicates the branch anywhere else the sync is called.

**Recommendation: Shape (i).** It centralizes the replenishability policy in the replen domain and keeps the choke-point loop untouched. The DI-cycle risk is real but bounded and gated (§8 hard gate, §10 D2). Verdict unchanged after review.

### (Dropped) Fix C — transfer-order path

Fix C is **removed** (Correction 3). The transfer-order build path (`MobileTransferOrderService.transferStock:387-410`) does not strand a reservation: reserved stock is left at source (`:404`) and the whole-UL-to-lane branch is `reservedamount==0` guarded (`:388`,`:392`). There is nothing to fix there, so no explicit call and no `@Transactional` prerequisite (the former Q4) are needed. Recorded as resolved finding D2b (§10).

---

## 6. File Change Summary

| # | File | Site | Change | Fix |
|---|------|------|--------|-----|
| 1 | `service/ReplenishmentOrderMaintenanceService.java` | new method (~`:110`) | Add public `reassignOrCancelForMovedStockUnit(Stockunit)`; reuse private `redirectSource:308`/`cancelOrder:415` (mirrors `ensureValidSource:255-262`); `@Transactional(tenantTransactionManager)`; block `>=STARTED`; `findByIdForUpdate` | A |
| 2 | `service/ReplenishmentOrderSourceSyncService.java` | `syncForMovedStockUnit` + constructor | Branch on `isReplenishableDestination(dest)`: true → re-point (2492, unchanged); false → delegate to Fix A; inject `ReplenishmentOrderMaintenanceService` via a **`@Lazy` constructor parameter** (cycle-breaker) | B (i) |
| 3 | `service/StockunitService.java` | `transferStock:150` | **NO CHANGE** — I-3 guard (verify script asserts no `recalculateForItem` call in the method body) | I-3 |
| 4 | `service/UnitloadBusinessService.java` | `:290-296` | **No change** under shape (i) — the existing `:294` call reaches the new branch inside the sync service | B wiring |

**Removed vs. the first draft:** `MobileTransferOrderService.java` (former Fix C) — no change; verified not a defect (§2, §10 D2b).

---

## 7. Implementation Steps

Sequence: **prerequisites → Fix A (primitive) → Fix B (branch, shape i) → I-3 guard → tests → verify.**

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|--------------|-------------------------|-------|
| 1 | **Database state** | No schema change. `replenishorder` columns (`stockunit_id`, `requestedlocation_id`, `sourcelocationname`, `requestedrack_id`, `state`, `version`) + `area.useforreplenish` all exist in v2 (confirmed on `wms2-wineco-dev`). Re-run the §1 detector on the **client prod/UAT DB** before merge. | db_verified: true (dev topology) |
| 2 | **Feature flags / sysprops** | **N/A** — always-on. Note the replen cron cadence gates: `NEW_CRON_JOB_ACTIVATED` / `REPLENISHMENT_TIMER_ACTIVATED` control the cron backstop only — they must **not** gate this synchronous fix (a flag-off cron would otherwise leave stranded reservations with no recovery). | |
| 3 | **Config / env** | **N/A** — no new dependency. `spring-retry` not added; `OptimisticLockRetry` not wired into the move path (SBDEV-2492 stance inherited). | |
| 4 | **Deploy-order dependencies** | **None.** SBDEV-2481 + SBDEV-2492 already on develop; this plan hooks beside them. | |
| 5 | **Data migration / backfill** | **N/A for state 300** (cron reassigns-or-cancels on the next pass). **RESERVED-400 rows are NOT healed by the cron** — any pre-existing stranded 400 rows on client prod were fixed manually and will not recur after this ships; consider a one-off detector sweep post-deploy rather than a migration. | DBA: optional post-deploy detector run |
| 6 | **External systems** | **N/A** — no OMS/printer/keycloak interaction on this path. | |
| 7 | **Access / permissions** | **N/A** — no new endpoint/authority. | |
| 8 | **Monitoring** | Schedule the §1 stranded-reservation detector; **alert on count > 0 sustained across more than one maintenance interval** (a brief non-zero window between a move and the cron pass is normal for state 300; a persistent count implies stranded RESERVED-400 rows). | reuses §1 SQL |
| 9 | **Transaction legality** | The choke-point path is already transactional (`transferUnitLoadToLocation` is `@Transactional(tenantTransactionManager):113`), so `findByIdForUpdate` is legal. **N/A** — the former Fix C transaction prerequisite is dropped (Correction 3). | |

### 7.2 Implementation Checklist

- [ ] **Step 1 — Fix A.** Add public `reassignOrCancelForMovedStockUnit(Stockunit)` on `ReplenishmentOrderMaintenanceService`; mirror `ensureValidSource:255-262` — reuse private `redirectSource:308` / `cancelOrder:415`; block `>=STARTED` (incl. 530); `findByIdForUpdate` lock+re-read; `@Transactional(tenantTransactionManager)`.
- [ ] **Step 2 — Fix B (shape i).** Branch `syncForMovedStockUnit` on `isReplenishableDestination`; inject `ReplenishmentOrderMaintenanceService` via a **`@Lazy` constructor parameter**. **Run the context-load hard gate immediately** — if it fails, switch to the D2 fallback (extract a repos+`StockunitBusinessService`-only collaborator shared by cron + move path).
- [ ] **Step 3 — I-3 guard.** Confirm `StockunitService.transferStock` still does **not** call `recalculateForItem` (SBDEV-2033 preserved).
- [ ] **Step 4 — tests.** Unit per §8; ITs written but `@Disabled("SBDEV-2217")`.
- [ ] **Step 5 — gates.** `mvn clean compile` + context-load (cycle gate) green; targeted `mvn test` green; verify script 0 FAIL.

---

## 8. Testing Plan

> **v2 gate:** unit test per change (Mockito; v2 CAN `mockStatic`). ITs written but `@Disabled("SBDEV-2217")` (Testcontainers lane cannot boot — see MEMORY). **Hard gates:** `mvn clean compile` + an `OmsNotificationConfigContextLoadTest`-style **context-load test** + targeted `mvn test`. Verify script 0 FAIL.

### HARD GATE — DI-cycle / context-load

Shape (i) introduces `ReplenishmentOrderSourceSyncService → ReplenishmentOrderMaintenanceService`. MEMORY practice ("Verify Spring bean changes with clean compile + context-load"): a unit/incremental compile **misses** DI-wiring drift. Therefore:

| Gate | Assertion |
|------|-----------|
| `mvn clean compile` | compiles (catches missing constructor param / type drift) |
| `ReplenishReassignContextLoadTest` (`OmsNotificationConfigContextLoadTest`-style `@SpringBootTest` slice) | **Spring context loads with no cycle.** The cycle-breaker is the **`@Lazy` constructor parameter** on the new `ReplenishmentOrderSourceSyncService → ReplenishmentOrderMaintenanceService` edge (Correction 4) — a lazy proxy is injected only when `@Lazy` is on the injection point. `UnitloadBusinessService`'s class-level `@Lazy` (`:31`) does **not** break the hard `StockunitBusinessService → UnitloadBusinessService` constructor edge (`:42`/`:64`) and is not the mechanism here. Precedent: the maintenance service's own `@Lazy` self field (`:78-80`). |

**FALLBACK (mandatory if the context fails to load):** extract the reassign primitive (`redirectSource` + `cancelOrder`, with the candidate finder still reached inside `redirectSource`) into a **new repos + `StockunitBusinessService`-only collaborator** injected by *both* the cron and the move path. This removes the `SourceSyncService → MaintenanceService` edge entirely. This is a live decision point (§10 D2).

### Unit tests (Mockito)

`ReplenishmentOrderMaintenanceServiceReassignTest` (Fix A):

| Test | Asserts | AC |
|------|---------|----|
| `reassign_noActiveReplen_noWrite` | finder empty → no `findByIdForUpdate`, no `redirectSource`/`cancelOrder`, no exception | AC6 |
| `reassign_redirectSucceeds_reassignsSameOrder` | `redirectSource(order, movedStock)` returns true → `cancelOrder` NOT called; same order id retained | AC2 |
| `reassign_redirectReturnsFalse_cancels` | `redirectSource` false (no candidate OR reservation failed, Q6) → `cancelOrder(order, movedStock, CODE_REPLENISHMENT_CANCELLED)`; no exception; move proceeds | AC3 |
| `reassign_started_throwsBusinessException` | state 500 → `BusinessException`, no `redirectSource`/`cancelOrder` | AC4 |
| `reassign_clubRunFinished530_throwsBusinessException` | state 530 → blocked by `>=STARTED` | AC4 |
| `reassign_locksViaFindByIdForUpdate` | `findByIdForUpdate(probe.id)` before any write | AC8 |
| `reassign_downsizesWhenAltHoldsLess` | when `redirectSource` reduces `requestedamount` to the candidate's available (`:327`), the smaller value is accepted (documented behavior, R-5) | AC2 |

`ReplenishmentOrderSourceSyncServiceBranchTest` (Fix B, shape i):

| Test | Asserts | AC |
|------|---------|----|
| `sync_replenishableDest_repointsTriple` | `dest.area.useforreplenish=true` → re-point (2492 behaviour); no reassign call | AC1 |
| `sync_nonReplenishableDest_delegatesReassign` | `useforreplenish=false` → `reassignOrCancelForMovedStockUnit(su)` invoked; no triple re-point | AC2 |
| `sync_nullArea_treatedNonReplenishable` | `dest.area == null` → delegate to reassign (safe default) | AC2 |

`UnitloadBusinessServiceReplenBranchTest` (choke-point wiring):

| Test | Asserts | AC |
|------|---------|----|
| `processTransfer_blockRealign_callsSyncPerSu` | `syncForMovedStockUnit` invoked once per SU in the tree | AC1/AC2 |
| `processTransfer_passThroughCode_skipsReplen` | ship/split/truck → neither re-point nor reassign called | AC5 |

`StockunitServiceTransferStockGuardTest` (I-3):

| Test | Asserts | AC |
|------|---------|----|
| `transferStock_doesNotRecalculateForItem` | no `recalculateForItem` call in the `transferStock` body (SBDEV-2033 preserved) | AC9 |

### Integration tests (`@Disabled("SBDEV-2217")` — written, not executable)

`ReplenReassignOnNonReplenishableMoveIT` (AC1-AC9): move onto replenishable → re-point (AC1); onto transfer lane with alt source → reassign, same order id (AC2); onto transfer lane with no alt → `redirectSource` false → cancel (AC3); STARTED/530 → block (AC4); PASS_THROUGH skip (AC5); no-replen clean move (AC6); **later throw rolls back the whole tree (AC7)**; concurrent cron heal serializes via `findByIdForUpdate` (AC8); moved SU self-excluded from candidates / no `recalculateForItem` (AC9); plus a **RESERVED-400** case proving the reservation is reassigned/cancelled synchronously (the durable-stranding hole the cron misses). All bodies carry `// TODO(SBDEV-2217): un-disable when the v2 Testcontainers lane boots.`

### AC → test map (every AC covered)

| AC | Behaviour | Test |
|----|-----------|------|
| AC1 | replenishable dest → re-point (2492 preserved) | `ReplenishmentOrderSourceSyncServiceBranchTest::sync_replenishableDest_repointsTriple` |
| AC2 | non-replen dest + alt source → reassign (same order id; may downsize, R-5) | `ReplenishmentOrderMaintenanceServiceReassignTest::reassign_redirectSucceeds_reassignsSameOrder` / `reassign_downsizesWhenAltHoldsLess` + `…Branch::sync_nonReplenishableDest_delegatesReassign` |
| AC3 | non-replen dest + no alt (`redirectSource` false) → cancel | `…ReassignTest::reassign_redirectReturnsFalse_cancels` |
| AC4 | state>=STARTED (incl. 530) → block move | `…ReassignTest::reassign_started_throwsBusinessException` / `reassign_clubRunFinished530_throwsBusinessException` |
| AC5 | PASS_THROUGH skip | `UnitloadBusinessServiceReplenBranchTest::processTransfer_passThroughCode_skipsReplen` |
| AC6 | no active replen → no write | `…ReassignTest::reassign_noActiveReplen_noWrite` |
| AC7 | whole-tree atomic rollback | `ReplenReassignOnNonReplenishableMoveIT::laterThrow_rollsBackTree` (@Disabled SBDEV-2217) + I-2 review |
| AC8 | runs inside move tenant tx; `findByIdForUpdate` serializes w/ cron | `…ReassignTest::reassign_locksViaFindByIdForUpdate` + IT (@Disabled) |
| AC9 | moved SU self-excludes from candidates (I-3, no `recalculateForItem`) | `StockunitServiceTransferStockGuardTest::transferStock_doesNotRecalculateForItem` |
| (gate) | context loads, no DI cycle | `ReplenishReassignContextLoadTest` (HARD GATE) |

### Manual test plan

| # | Scenario | Environment | Steps | Expected | Pass/Fail |
|---|----------|-------------|-------|----------|-----------|
| 1 | Move onto **replenishable** location | staging mobile | move UL backing `300` replen A→B (both replenishable) | source re-pointed to B; reservation intact (AC1) | |
| 2 | Move onto **transfer lane**, alt source exists | staging mobile | move UL backing `300` replen onto lane; another pick face has stock | replen reassigned to the other source, same order id (may downsize); move succeeds (AC2) | |
| 3 | **RESERVED (400)** replen moved onto transfer lane (ticket repro) | staging mobile | move UL backing a `400` replen (reserved qty>0) onto a lane | replen reassigned or cancelled **immediately** (not stranded until a manual fix); move succeeds (AC2/AC3) | |
| 4 | Move onto **transfer lane**, no alt source | staging mobile | move the only stock backing the replen onto a lane | `redirectSource` false → replen cancelled; move succeeds (AC3) | |
| 5 | STARTED replen | staging mobile | move UL backing a `500`/`530` replen | move blocked (422); old location intact (AC4) | |
| 6 | Shipping / truck-load | staging | ship/truck-load a UL | not blocked, not reassigned (AC5) | |
| 7 | No active replen | staging | move a UL with no backing replen | moves cleanly (AC6) | |
| 8 | DB sanity | client prod/UAT DB | run §1 detector before + after a move onto a lane | state-300 window heals; **no persistent RESERVED-400 rows** | |

### Test execution (fill in after running)

| Command | Result | Pass/Fail/Skipped |
|---------|--------|-------------------|
| `mvn clean compile` (cycle/compile gate) | _to fill_ | |
| `ReplenishReassignContextLoadTest` (HARD GATE) | _to fill_ | |
| `mvn test -Dtest=ReplenishmentOrderMaintenanceServiceReassignTest` | _to fill_ | |
| `mvn test -Dtest=ReplenishmentOrderSourceSyncServiceBranchTest` | _to fill_ | |
| `mvn test -Dtest=UnitloadBusinessServiceReplenBranchTest,StockunitServiceTransferStockGuardTest` | _to fill_ | |
| `RUN_MVN=1 bash sbdocs/9-System/scripts/verify-SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.sh` | _to fill_ | 0 FAIL |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Executable ITs | v2 Testcontainers lane blocked by SBDEV-2217; ITs written + `@Disabled` with TODO. AC8/AC9 rest on unit tests + static review until the lane is restored. |
| One-off backfill SQL | N/A — cron cancel-backstop + client manual fixes; no new stranded rows after this ships. |

---

## 9. Risks & Mitigations

| ID | Risk | Impact | Mitigation |
|----|------|--------|-----------|
| R-1 | Reassign **halts shipping / truck-load / split** | Critical | Runs only inside SBDEV-2481's `BLOCK_REALIGN` block; PASS_THROUGH never reaches the re-point/reassign branch. `processTransfer_passThroughCode_skipsReplen` + IT AC5. |
| R-2 | **Spring context cycle** (shape i: `SourceSyncService → MaintenanceService`) | HARD startup failure | **`@Lazy` constructor-parameter** on the new injection edge is the cycle-breaker (Correction 4 — NOT `UnitloadBusinessService`'s class-level `@Lazy :31`, which does not proxy the hard constructor edge `:42`/`:64`); precedent `:78-80`. `mvn clean compile` + **context-load HARD GATE**. FALLBACK: extract a repos+`StockunitBusinessService`-only collaborator (§10 D2). |
| R-3 | **Cron-vs-move contention** on the same `replenishorder` row (multi-replica) | server-side lock wait | `findByIdForUpdate` serializes the reassign with the cron inside the move tx (AC8); cron holds ≤1 replen lock and requests nothing else → no deadlock cycle (§7-HScale row 8). |
| R-4 | Wider block radius — a STARTED/530 replen refuses the whole move | Medium | Intended (AC4). Whole-tree granularity: one STARTED child replen fails the entire move atomically (I-2/AC7). Surfaced as 422; call out in operator docs. |
| R-5 | Reassignment picks a **poor** or **smaller** alternative source | Medium | Reuse the cron's own selection inside `redirectSource` (no new heuristic). **Downsizing is expected:** `redirectSource:327` sets `requestedamount = min(requested, candidate.available)` — a move can shrink the replen if the alternate holds less. When there is no candidate (or reservation fails), `redirectSource` returns false → `cancelOrder`, never block the move (Q6). |
| R-6 | Re-opening the SBDEV-2033 regression by re-adding `recalculateForItem` | self-depleting recalc | I-3 invariant; verify-script NEGATIVE guard + `StockunitServiceTransferStockGuardTest`. Moved SU self-excludes from candidates (AC9) — no recalc needed. |
| R-7 | Option-B lock wait — move hits a `replenishorder` row the cron is healing | Medium (operator stall, not 409) | Blocks until the cron tx commits/rolls back; bounded only if the tenant datasource sets `lock_timeout` / `jakarta.persistence.lock.timeout` — **implementer to verify** (inherited from SBDEV-2492 R-9). No deadlock (one-directional wait). |

### Acceptance

Machine-checkable script: **`sbdocs/9-System/scripts/verify-SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.sh`**. Run before the first change (FAIL baseline) and after every pass; a "DONE" claim with any FAIL is not accepted. POSITIVE checks (a, b, c, d1, d2, e, f): new public `reassignOrCancelForMovedStockUnit`; replenishability/`useforreplenish` check; `>=STARTED` block; `redirectSource` + `cancelOrder` calls; choke-point branch to reassign on non-replen dest; `@Transactional(tenantTransactionManager)` on the new method. NEGATIVE (g-h): `StockunitService.transferStock` body still has no `recalculateForItem` call (SBDEV-2033 guard, scoped to the method + ignoring comments); new method not bare `@Transactional`. The former transfer-path check is **removed** (Fix C dropped). `mvn` unit runs gated behind `RUN_MVN=1`.

---

## Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change… | Verdict | Mitigation / rationale |
|---|---------|--------------------|---------|------------------------|
| 1 | **In-JVM state** | new Caffeine/`ConcurrentHashMap`/static/`ThreadLocal`? | **No** | New method holds only injected repos/collaborators; no per-replica state. |
| 2 | **Connection pool math** | change per-request DB connection usage? | **No** | Reassign runs inside the existing move tx on the move's single connection; no new pool/tenant. |
| 3 | **Scheduled jobs** | add/modify a `@Scheduled`/cron? | **No** | No job added; the existing heal/cancel cron is unchanged (backstop). |
| 4 | **Long transactions** | hold a tx across extra repo calls / external I/O? | **Yes** | Reassign adds ≤ finder + `findByIdForUpdate` + candidate query + `redirectSource`/`cancelOrder`/`releaseReservation` per active replen per moved SU, inside the existing move tx. No external I/O. `findByIdForUpdate` holds a `PESSIMISTIC_WRITE` row lock to move-commit. **Row to watch.** |
| 5 | **Request affinity** | assume follow-up lands on same replica? | **No** | Stateless; no session/SSE/WebSocket. |
| 6 | **Retry / idempotency** | rely on single-execution semantics that break on replica death + retry? | **Yes — addressed** | Reassign is idempotent by state: a re-run finds the already-reassigned/cancelled replen (state changed or source now replenishable) and no-ops. `@Version` + 409 `retryable:true` (`RestExceptionHandler:144-150`) backstop; no `OptimisticLockRetry` on the move path. **Row to watch.** |
| 7 | **Tenant context** | use `TenantContext`/`ThreadLocal` across async boundaries? | **No** | Synchronous inside the move's tenant tx; no `@Async`. |
| 8 | **Distributed lock correctness** | add/rely on pessimistic/optimistic lock across replicas? | **Yes** | `findByIdForUpdate` (PESSIMISTIC_WRITE) on `replenishorder`, inside `@Transactional(tenantTransactionManager)`. **Lock order:** move holds SBDEV-2481 PO/CO + `unitload` locks, then `findByIdForUpdate` per replen. Cron locks ≤1 replen row and requests nothing else → **no cycle**, worst case a one-directional wait (R-7). **Row to watch.** |
| 9 | **Cache invalidation** | write to a cached entity? | **No** | `Replenishorder` not cached. |
| 10 | **External notifications** | HTTP/message to external system inside a tx? | **No** | No OMS/printer notification on this path. |

### Evidence (for "Yes" rows)

| # | What was verified | File:line / test |
|---|-------------------|------------------|
| 4 | Reassign runs inside the move tx; indexed finder (≤1 row) + lock + `redirectSource`/`cancelOrder` (candidate query internal); row lock held to commit; no external I/O | `UnitloadBusinessService.transferUnitLoadToLocation` `@Transactional(tenantTransactionManager):113`; `ReplenishorderRepository:91-92`, `:27-29`; `redirectSource:308`, `cancelOrder:415` |
| 6 | State-idempotent reassign; `@Version` 409 path; no `OptimisticLockRetry` wiring on move path | `RestExceptionHandler:144-150`; `OptimisticLockRetryScopeTest` |
| 8 | Pessimistic lock inside tenant tx; same row the cron locks; lock order PO/CO→unitload→replenishorder; cron holds ≤1 replen lock → no cycle | `ReplenishorderRepository.findByIdForUpdate:27-29`; cron `ReplenishmentOrderMaintenanceService:154`; warning `:73-77` |

---

## v2-Only Constraint Checklist

| # | Constraint | Verdict | Citation |
|---|------------|:-------:|----------|
| 1 | Tenant writes use `@Transactional(value="tenantTransactionManager", rollbackFor={…})` (never bare) | **Met** | Fix A method annotation; §5 Fix A; Q3 REQUIRED propagation |
| 2 | `jakarta.*` imports (not `javax.*`) | **Met** | Spring Boot 3.x; §5 code uses `jakarta`-era patterns |
| 3 | `.orElseThrow(...)` not `.get()` on `Optional` | **Met** | `findByIdForUpdate(...).orElseThrow(EntityNotFoundException)` |
| 4 | Constructor injection, not field `@Autowired` | **Met** | `@Lazy` collaborator via constructor (shape i); `UnitloadBusinessService:31` |
| 5 | `AbstractBaseEntity` ID-equality (no `.equals()` on detached refs) | **Met** | `Replenishorder extends AbstractBaseEntity:34-35`; compare by ID |
| 6 | Reuse `findByIdForUpdate` inside a tx (multi-replica serialization) | **Met** | §5 Fix A; §7-HScale row 8; choke-point path already `@Transactional(tenantTransactionManager):113` |
| 7 | No new cache/metric/scheduled job (cron is the backstop) | **Met** | §7-HScale rows 1,3,9; Q5 |
| 8 | ITs `@Disabled("SBDEV-2217")`; gate on unit + `mvn clean compile` + context-load | **Met** | §8; MEMORY SBDEV-2217 |

---

## Completeness Checklist

| # | Item | Status |
|---|------|:------:|
| 0 | **DB-verified** (detector query run; schema + topology confirmed) | ✅ `db_verified: true` — `wms2-wineco-dev` 2026-07-19 (6/8 areas + 26/26 lanes non-replenishable; 0/562 dev rows expected; re-run on client DB) |
| 1 | §0 affected-sites enumeration (all 10 rows, in-scope flagged) | ✅ |
| 2 | Each in-scope §0 row visited by §5 | ✅ rows 1-3 → Fix A/B; row 5 → I-3 guard (row 4 verified out of scope, D2b) |
| 3 | RC1/RC2/RC3 with file:line + broken excerpt + why-fails | ✅ §2 |
| 4 | Regression/design chain documented | ✅ §3 |
| 5 | Fix design: A (new public method), B (both shapes, shape i recommended); Fix C investigated + dropped (D2b) | ✅ §5 |
| 6 | Every AC1-AC9 mapped to a test | ✅ §8 AC→test map |
| 7 | DI-cycle context-load HARD GATE + explicit fallback | ✅ §8 + §10 D2 |
| 8 | Horizontal Scalability 10-row table + evidence | ✅ |
| 9 | Risks + Acceptance script path | ✅ §9 |
| 10 | ADR + resolved decisions D1/D2/D3 + open questions | ✅ §10 |

---

## 10. ADR + Resolved Decisions

### Resolved Decisions (record)

- **D1 — Fix B shape: adopt shape (i) (branch inside `ReplenishmentOrderSourceSyncService`).** The replenishability decision lives in the replen domain; the `UnitloadBusinessService` `BLOCK_REALIGN` loop stays a single unchanged call at `:294`. Shape (ii) (branch in the loop) is the documented alternative — rejected because it puts replen policy in `UnitloadBusinessService` and duplicates the branch at every call site.
- **D2 — DI approach: single new public method `reassignOrCancelForMovedStockUnit(Stockunit)` on `ReplenishmentOrderMaintenanceService`, no widened visibility (Q2).** Injected into `SourceSyncService` via a **`@Lazy` constructor parameter** on that new edge (Correction 4 — the class-level `@Lazy` on `UnitloadBusinessService:31` is *not* the mechanism; a lazy proxy is injected only when `@Lazy` is on the injection point; precedent `:78-80`). **FALLBACK (mandatory if the context-load HARD GATE fails):** extract the reassign primitive (`redirectSource` + `cancelOrder`, candidate finder still reached inside `redirectSource`) into a new repos + `StockunitBusinessService`-only collaborator shared by both the cron and the move path, removing the `SourceSyncService → MaintenanceService` edge. This is a live decision point resolved at implementation time by the gate result.
- **D2b — RESOLVED FINDING (transfer-lane build path): moot.** The user decision "also cover the transfer-order build onto a lane" is rendered moot by a verified code fact: `MobileTransferOrderService.transferStock:387-410` leaves reserved stock at source (`:404`) and only moves the whole UL to the lane when `reservedamount==0` (`:388`,`:392`). No reservation is stranded there → **Fix C dropped**, no `@Transactional` prerequisite. Recorded here rather than silently dropped.
- **D3 — Reassignment runs atomically INSIDE the move's tenant tx (REQUIRED propagation, Q3).** The reassign/cancel joins `transferUnitLoadToLocation`'s `@Transactional(tenantTransactionManager)`. A later `BusinessException` rolls back the whole move tree with the reassign (I-2/AC7). `findByIdForUpdate` is legal because the path is always transactional.

### ADR — Where the reassign/cancel primitive lives + how the move path reaches it

**Decision.** Add a single **public** `reassignOrCancelForMovedStockUnit(Stockunit)` on `ReplenishmentOrderMaintenanceService` (mirroring `ensureValidSource:255-262`, reusing its private `redirectSource:308` / `cancelOrder:415`; the candidate finder `StockunitRepository.getAvailableReplenishmentSources` is reached **inside** `redirectSource`). Reach it from the choke point by **growing `ReplenishmentOrderSourceSyncService` to branch on destination replenishability** (shape i), injecting the maintenance service via a **`@Lazy` constructor parameter**. All writes run inside the move's tenant tx.

**Drivers (top 3).**
1. **Reuse the cron's proven reassignment primitives** without widening their visibility (`redirectSource`/`cancelOrder` already reserve/release/cancel correctly).
2. **Multi-replica correctness** — serialize the reassign with the cron on the shared `replenishorder` row (`findByIdForUpdate`) inside the move tx.
3. **Smallest faithful diff** that durably closes the RESERVED-400 hole (the state the cron misses), respecting the SBDEV-2033 invariant (I-3).

**Alternatives considered.**
- **Fix B shape (ii) — branch in the `UnitloadBusinessService` loop.** Rejected (D1): replen policy leaks into the move service; branch duplicated at each call site; second replen collaborator + `@Lazy` field on `UnitloadBusinessService`.
- **Grow `ReplenishmentOrderSourceSyncService` to OWN reassignment (new class doing reserve/release/cancel).** Rejected: requires promoting the cron's private `redirectSource`/`cancelOrder` to package/public — widening the surface for no benefit and risking divergence from the cron's behaviour.
- **Extract-collaborator (repos + `StockunitBusinessService`-only) shared by cron + move.** Held as the **DI-cycle fallback** (D2), not the primary — a larger refactor of the cron, justified only if the `@Lazy` cycle break fails the context-load gate.
- **Cover the transfer-lane build path (Fix C).** Dropped — verified not a defect (D2b).
- **Teach the move to re-add `recalculateForItem` (undo SBDEV-2033).** Rejected (I-3) — re-opens the self-depleting recalc regression; unnecessary because the moved SU self-excludes from candidates (AC9).

**Why chosen.** Public-method-on-maintenance-service reuses the correct primitives with zero visibility widening; shape (i) centralizes policy and keeps the loop clean; the `@Lazy` edge is a bounded, gated risk with a concrete fallback. It is the minimal change that durably fixes the RESERVED-400 hole (RC1) and the blind re-point onto a lane (RC2).

**Consequences.**
- Positive: reservations are **reassigned** (not just cancelled) synchronously on move — including RESERVED (400), which neither cron path heals today; no stranded reservations on non-replenishable lanes; whole-tree atomicity preserved; SBDEV-2033 invariant respected.
- Negative: adds a `PESSIMISTIC_WRITE` lock held to move-commit (§7-HScale row 4); a move colliding with an in-flight cron heal **stalls** until the cron tx finishes, bounded only by a configured `lock_timeout` (R-7); a STARTED/530 replen refuses the whole move (R-4, intended); reassignment may **downsize** the replen to the alternate's available quantity (R-5, expected).

**Follow-ups.**
- **v1 paired plan** — port to v1/wms-api under the same base name `SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.md` (v1 is single-replica; drop `findByIdForUpdate`/multi-replica notes).
- **Extend the cron recalc to also process RESERVED (400) / other open states** — the real cron limitation is that `recalculateOrder` bails on `state != PROCESSABLE` and `cancelUnreachableReplenishment` only reaches `state <= 300`, so RESERVED-400 has no backstop. Broadening the cron recalc is an out-of-scope **durable complement/alternative** to this synchronous fix.
- Verify tenant datasource `lock_timeout` / `jakarta.persistence.lock.timeout` (R-7).
- NEW-2 (`setLockOnHold` plain `findById`) remains a deferred hardening (inherited from SBDEV-2492).

### Open Questions

| # | Item | Why it matters |
|---|------|----------------|
| OQ-1 | Confirm shape (i) + the `@Lazy` constructor-parameter breaks the cycle on the real context, else invoke D2 fallback. | Determines whether a larger cron refactor is needed (context-load gate is the decider). |
| OQ-2 | R-7 — is `lock_timeout` / `jakarta.persistence.lock.timeout` configured on the tenant datasource? | Bounds the cron-collision stall; else indefinite wait. |
| OQ-3 | Candidate-selection + downsizing policy — is `redirectSource:327`'s `min(requested, available)` downsize acceptable to operations, or should a move be blocked when the alternate can't cover the full request? | Reassign quality vs. move throughput; plan reuses the cron's existing selection + downsizing as-is (R-5). |
| OQ-4 | Re-run the §1 detector on client prod/UAT (dev count is masked by manual fixes); confirm a persistent RESERVED-400 population. | True confirmation of live impact before merge. |

These are persisted to `.omc/plans/open-questions.md`.

---

## 11. Implementation Status

**Status:** IMPLEMENTED 2026-07-20 (ralplan consensus → TDD gate → implement → code-review APPROVE, 0 High / 4 Medium all fixed + M5 documented). PR #82 open → `develop`.

| Field | Value |
|-------|-------|
| Branch | `fix/SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move` (off `develop`) |
| Commit(s) | `7e0536c` |
| PR | [SiteBossInc/wms2-api#82](https://github.com/SiteBossInc/wms2-api/pull/82) → `develop` |
| `mvn clean compile` | SUCCESS (on the develop-based branch) |
| `ReplenishReassignContextLoadTest` (HARD GATE) | PASS — context loads, no `BeanCurrentlyInCreationException` (DI cycle broken by `@Lazy`; ran, not skipped) |
| `mvn test` (§8 unit classes) | 26 run, 0 fail (5 SBDEV-2074 classes + SBDEV-2492 regression suite) |
| Cron regression (`ReplenishmentOrderMaintenanceServiceUnitTest`, `ReplenishOrderJobTest`, `ReplenishorderServiceUnitTest`) | 137 run, 0 fail (M4 reorder did not regress the cron) |
| `verify-SBDEV-2074-…sh` (RUN_MVN=1) | 14 pass, 0 fail, 1 skip (IT — SBDEV-2217) |
| Full suite `mvn test` | 2 failures, both PRE-EXISTING + unrelated (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`); 0 new |
| `mvn verify` (Testcontainers) | Not run (blocked — SBDEV-2217; ITs `@Disabled`) |
| DB re-verify on client prod/UAT | Pending — run the §1 detector on the affected client DB before/at release |

### Implementation notes
- **Signature reconciliation:** the final method is 2-arg `reassignOrCancelForMovedStockUnit(Stockunit movedStock, Location destination)` (the §5 sketch's 1-arg is superseded — the destination is needed for the replenishability check). Fix B shape (i) used: the branch lives in `ReplenishmentOrderSourceSyncService`; the choke-point call site in `UnitloadBusinessService` is unchanged.
- **Code-review findings fixed:** M1 (extract `LocationReplenishabilityUtil` — 3 copies → 1), M2 (defensive re-check documented; dedup lookup), M3 (context-load DI gate proven to boot + pass), M4 (`redirectSource` reserve-before-release — fixes a latent double-release / negative `reservedamount`, benefits the cron too, with a regression test).
- **M5 (accepted contract):** a `FacadeException` on the alternate reserve marks the tenant tx rollback-only → the move is rejected (422) and retried; intentionally **not** `REQUIRES_NEW` (would orphan a reservation). Documented at the catch site.
- **Docs:** `sbdocs/3-Resources/design/wms2-replenishment-design.md` updated (§0/§2/§3/§9/§11, `last_verified` 2026-07-20).
- **v1 paired follow-up:** still pending (same base name in `1-Projects/wms1/plan/`).

### Recommended OMC Composition

| Aspect | Value | Rationale |
|--------|-------|-----------|
| Size class | Standard | 1 new public method + 1 branch + I-3 guard; single subsystem. |
| Pre-draft | analyst+planner → ralplan consensus (Architect/Critic) | shared choke point + DI-cycle + cron-limitation interplay need consensus. |
| Plan-review | critic | verify shape-i cycle break (`@Lazy` param), I-3 guard, RESERVED-400 coverage, AC map. |
| Implementation shape | executor → `wms-tdd-gate` (write named failing tests first) | small, well-scoped; context-load gate is decisive. |
| Verification | verify-script + verifier | mandatory; `mvn clean compile` + context-load are hard gates. |
| Code-review | code-reviewer | confirm reassign preserves reservation semantics, Q6 cancel-allows-move, downsizing (R-5), tenant-TM routing. |
| Commit | git-master (split Fix A / Fix B if desired) | multiple logical units. |
