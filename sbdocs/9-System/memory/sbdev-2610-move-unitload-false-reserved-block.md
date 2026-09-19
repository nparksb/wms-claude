---
name: sbdev-2610-move-unitload-false-reserved-block
description: "SBDEV-2610 (v1) Move Unit Load blocked while UI shows 0 reserved-out — REAL cause is SBDEV-2492 in-progress-replen block, NOT checkReservedStock"
metadata:
  node_type: memory
  type: project
  originSessionId: e9fe389b-0c52-4a5d-83f6-3f13df9e1529
  modified: 2026-07-23T02:03:41.299Z
---

WineCo prod, ST#1047. Move Unit Load on UL347145 (SKU 2290074) was blocked while UI showed **0 reserved out**; canceling the open Replenishment Request unblocked it.

**⚠ Root cause was CORRECTED after critic+architect review.** NOT `checkReservedStock` (my first guess). Prod stockrecord proves it: `reservedamount` on the only su (32439754, on UL347145=unitload 32439752) was **0 for 2m34s before the move succeeded** (11:04:19 → TRANSFER 11:06:57), and REPL061406 kept exact `stockunit_id=32439754` and stayed open the whole time — so `checkReservedStock` would `continue` (SBDEV-2492), never throw.

**Actual cause:** `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit` (`:52-63`), called from `UnitloadBusinessService:247` inside `processTransfer` on every unit-load move. It re-points the replen source silently when replen `state < STARTED`, but **THROWS** `"Replenishment in progress for this stock; complete or cancel it before moving. replenOrderNumber=…"` when `state >= STARTED (500)`. Operator was forced to cancel ⇒ REPL061406 was >=STARTED ⇒ SourceSync threw ⇒ cancel made it state 800 ⇒ move proceeded 4s later. This is SBDEV-2492 working-as-designed; the ticket is really a UX/visibility gap ("0 reserved out" doesn't reflect a replenishment-in-progress hold).

**Separate LATENT bug (did NOT cause this incident):** `checkReservedStock` (MobileMoveUnitloadService:166-183) dead-ends any `reservedamount!=0` with no open exact-id replen and no recourse. `reservedamount` is SHARED (picking/customer-order/manual/replen). Prod today: 631 reserved-nonzero, 40 no-open-replen, **17 truly orphaned (no replen ever + no pick ever)** — dominated by CREATE_PICK_POSITION/PICKING codes (picking origin, NOT replen). Split does NOT carry reservedamount to a child (StockunitBusinessService:238-286) so "split-carry leak" is a non-issue; replen release-target rework was DROPPED.

**Plan (v1, draft):** SBDEV-2610-move-unitload-false-reserved-block.md — Part 1 = clarify SourceSync block + surface replen state in mobile UI; Part 2 = checkReservedStock honesty (exact-id replen continue / active-pick block / stranded warn+allow, no broadened lookup) + Flyway **V1.26.32** Java callback reconciling the 17 orphans. BLOCKING gate: confirm prod deployed SHA + exact operator error text. Flyway head is V1.26.31 (v1.26.45 is a release TAG not a schema version — earlier confusion). Related [[sbdev-2074-nonreplenishable-move-reservation-gap]].

**v2 IMPLEMENTED 2026-07-22 (ralph):** ops gate resolved from v1 `release` — v1 has ONE unconditional SourceSync throw site (no `isReplenishableDestination` gate); the two-site split is v2-only (SBDEV-2074), so both v2 sites must be fixed. v2 message REGRESSED (dropped the order number v1 `release` still carries). Delivered A1 (shared `ReplenishmentOrderMessages.replenBlockMessage` from both `ReplenishmentOrderSourceSyncService`+`ReplenishmentOrderMaintenanceService`), B1 (`checkReservedStock` honest read-only: exact-id replen continue / in-progress pick <PICKED block+named / stranded warn+allow; keep recursion; drop dead-end; new `PickingorderPositionRepository`), A2 (`TransferInfoDto.activeReplenNumber` + `scanDestination.vue` alert), C1 (`ReplenishmentReservationReconciliationService`+controller, sb_admin, audited via `changeReservedAmount`, report-only native query re-validated per row, NO Flyway migration — C1 exec deferred until a v2 tenant is live). Verify 17/0; 113 tests; review 0 crit/high. **PRs: wms2-api [#90](https://github.com/SiteBossInc/wms2-api/pull/90) + wms2-mobile-ui [#23](https://github.com/SiteBossInc/wms2-mobile-ui/pull/23) into develop (merge #90 first).** ClickUp SBDEV-2610 → "pr submitted". v2 plan status=implemented.

## Index-hook detail

Condensed status/landmine notes that previously lived in the `MEMORY.md` index line:

CORRECTED dx: real cause is SBDEV-2492 SourceSync `>=STARTED` block (ReplenishmentOrderSourceSyncService:59 via UnitloadBusinessService:247), NOT checkReservedStock (reserved was 0 at move time); checkReservedStock dead-end is a SEPARATE latent bug (17 orphaned rows); split does NOT carry reservedamount; Flyway head V1.26.31
