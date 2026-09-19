---
name: sbdev-2074-nonreplenishable-move-reservation-gap
description: SBDEV-2074 (v2) is ON PROD (fixed 232a84c2 / PR #82) — corrected 2026-08-21; it hooks the MOVE path only, not manual reserved-amount edits
metadata: 
  node_type: memory
  type: project
  originSessionId: 5be84168-0393-48e6-a5d0-c22f38c28152
---

SBDEV-2074 ("Replenishment Reservations Not Reassigned When Unit Load Moved to Non-Replenishable Location", urgent, tagged wmsv1+wmsv2) is STILL APPLICABLE to WMS v2 and needs a fix (verified against v2/wms2-api 2026-07-19).

**Gap:** desired behavior = on move to a non-replenishable location, release the reservation from the moved UL and reassign the same Replenishorder to another eligible UL (keep order intact; cancel only if no alternate). Not implemented as a move-time action.

Key v2 facts:
- "Non-replenishable" = `LocationArea.useforreplenish=false` (model/LocationArea.java:23), NOT the `Location.transferlane`/`staginglane` booleans (never cross-checked). Enforced in `ReplenishmentOrderMaintenanceService.isSourceUsable` (:265-306).
- The reassignment logic SBDEV-2074 wants ALREADY EXISTS: `ReplenishmentOrderMaintenanceService.redirectSource` (:308-355) — release old, pick best useforreplenish=true candidate, keep order, cancel if none. BUT only driven by the recalc cron; no UL-move path invokes it (StockunitService.transferStock:260-264 suppresses trigger per SBDEV-2033).
- [[stacked-v2-pr-merge-order-orphan-trap]] sibling: SBDEV-2492 (merged, archived) made this WORSE — `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit` (:53-89) blindly re-points the replen source triple onto ANY destination incl. a lane, no replenishability check; sets requestedlocationId to the lane so cron isSourceUsable:290 location-match passes → self-heal hinges entirely on lane area useforreplenish=false.
- Two move paths differ: mobile "Move Unit Load"/web "Move Stock" = CODE_TRANSFER/CODE_MANUAL_TRANSFER → BLOCK_REALIGN → SBDEV-2492 re-points to lane (wrong). Dedicated transfer-lane build MobileTransferOrderService.java:392 = activityCode null → PASS_THROUGH → nothing fires at all.
- SBDEV-2492 Fix B removed the cancel guard in MobileMoveUnitloadService.checkReservedStock:196-201, so move just proceeds.

Fix shape: drive existing redirectSource release+reassign from the move (check destination area useforreplenish before re-pointing; reassign-or-cancel).

IMPLEMENTED 2026-07-20 → wms2-api PR #82 (open, → develop), commit 7e0536c on branch fix/SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move (branched off develop — the working dir had been on feature/SBDEV-2001; stashed+rebased clean). Tests: targeted 26/0, context-load DI gate green, verify 14/0, cron regression 137/0, full suite 2 pre-existing unrelated fails (OptionalSafetyArchTest, MobilePalletizingServiceTest). Code review 0 High/4 Medium (all fixed)+M5 documented. Plan status→implemented; design doc wms2-replenishment-design.md updated. v1 paired follow-up still PENDING.
Implemented shape: 2-arg reassignOrCancelForMovedStockUnit(Stockunit,Location) on ReplenishmentOrderMaintenanceService (reuses redirectSource/cancelOrder); ReplenishmentOrderSourceSyncService branches on replenishability (@Lazy Maint injection breaks the cycle); redirectSource reordered reserve-before-release (M4 fixes latent double-release); shared LocationReplenishabilityUtil (M1). M5 accepted contract: FacadeException on alternate reserve → tenant tx rollback-only → move 422+retry (NOT REQUIRES_NEW, would orphan reservation).

PLAN WRITTEN + ralplan-APPROVED 2026-07-19: sbdocs/1-Projects/wms2/plan/SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.md (+ verify script). Consensus refined two earlier errors — verify before repeating them:
- CRON IS NOT CANCEL-ONLY. Two mechanisms: (a) ReplenishmentOrderMaintenanceService recalc (recalculateOrder:155 bails if state!=PROCESSABLE) → ensureValidSource:258 REASSIGNS via redirectSource, else cancelOrder:261 — but ONLY state==300; (b) ReplenishOrderJob.cancelUnreachableReplenishment:269-295 (it DOES exist) cancels only useforreplenish=false AND state<=300. State ladder: PROCESSABLE=300, RESERVED=400, STARTED=500, ORDER_BATCH_CLUB_RUN_FINISHED=530, FINISHED=700, CANCELED=800. THE GENUINE DURABLE GAP = RESERVED(400) re-pointed onto a lane, healed by NEITHER cron path (recalc needs ==300, cancel needs <=300) — matches the ticket's "reserved qty=6". PROCESSABLE(300) is only a transient window.
- TRANSFER-ORDER BUILD PATH does NOT strand reservations (earlier D2b assumption was WRONG): MobileTransferOrderService.transferStock leaves reserved stock at source (:404 "Bring back reserved stock"), whole-UL-to-lane branch guarded reserved==0 (:388/:392). Fix targets the generic Move-Unit-Load choke point (UnitloadBusinessService.processTransfer BLOCK_REALIGN) only.
- Fix = new public reassignOrCancelForMovedStockUnit on ReplenishmentOrderMaintenanceService mirroring ensureValidSource:255-262 (redirectSource(order, movedStock) else cancelOrder(order, movedStock, CODE_REPLENISHMENT_CANCELLED)); block state>=STARTED (D1). redirectSource:327 downsizes requestedamount to min(requested, candidate.available). DI-cycle risk (SourceSyncService→MaintenanceService→StockunitBusinessService→UnitloadBusinessService→SourceSyncService) broken by @Lazy ctor param on the new edge — HARD GATE = Spring context-load test; fallback = extract reassign primitive into repos+StockunitBusinessService-only collaborator.
- ClickUp SBDEV-2074 comment posted 2026-07-19.

**CORRECTED 2026-08-21 — this note said "STILL OPEN"; it is not.** SBDEV-2074 is **`on prod`**.
Implemented in v2 as `232a84c2` (PR #82) with `LocationReplenishabilityUtil` +
`ReplenishmentOrderMaintenanceService`; the plan is archived at
`4-Archieves/wms2/plan/SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.md` and its
verify script is retired. Reading the stale line cost a wrong statement to Nam — re-check ClickUp
status before repeating a note's disposition.

**Scope boundary worth keeping:** 2074 hooks the **move** path only. A **manual** reserved-amount
edit (`POST /v3/stockUnit/adjustReservedAmount` → `StockunitService.adjustReservedAmount`) is a
different entry point that 2074 never touches. That method has its own guards — refuses on SHIPPED,
GOING_TO_DELETE, and any related picking position at state ≥ STARTED — and **deliberately does not
trigger replenishment maintenance** (explicit comment: re-triggering would instantly re-reserve what
the user just released; the scheduled `ReplenishOrderJob` re-evaluates instead). Bulk and single
paths share the service method, so guard parity holds. See [[sbdev-1615-overtaken-not-duplicate]].
