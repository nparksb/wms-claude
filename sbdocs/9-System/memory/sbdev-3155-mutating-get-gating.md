---
name: sbdev-3155-mutating-get-gating
description: "SBDEV-3155 gated the 10 state-changing GETs on ClubLine/Transfers/PickingOrderPosition — MERGED on dev 152108d3, gated probe 30/30, zero new constants, T2; 4 of the 10 stay reachable via PATCH /v3/customerorder so it closes only 6; DEV grants drift mid-session"
metadata: 
  node_type: memory
  type: project
  originSessionId: 697836c7-1396-4257-9830-c4ad17aae1df
  modified: 2026-09-01T16:14:29.477Z
---

**MERGED `on dev` 2026-09-01 — merge `152108d3`, PR #261, commit `d7fd4e41`. VERIFIED LIVE on DEV:
gated probe 30/30.** Re-verified on `origin/develop` itself: ClubLine 7 annotations, Transfers 9,
PickingOrderPosition 1, **zero class-level**, pin 145. Code-only merge, no Flyway run.
Branch `bugfix/SBDEV-3155-mutating-get-gating` off `ad681319`. **T2, not T3** — zero new constants, no
Flyway, one repo, same reasoning as [[sbdev-3154-admin-action-console-gating]]. Suite **5979/0/0/67**
vs a fresh **5974/0/0/67** baseline. See [[wms2-gate-a-route-on-its-screens-existing-function]].

Gates: `ClubLineController` ×4 → `WEB_UI_VIEW_CLUB_LINE`, `TransfersController` ×5 →
`WEB_UI_VIEW_TRANSFER_ORDER`, `fixPickingPosition` → `WEB_UI_VIEW_PICKING_POSITION`. All three exist in
**all six** v2 tenant DBs (holders 45/43/15/25/9/7 incl. Hydra PRD), so no fail-closed tenant.

🔴 **IT CLOSES ONLY SIX OF TEN.** `assign`/`reassign`/`unlink TransferLane` + `activateTransferOrder`
reduce to `setTransferlaneId` + `setState` + `save` on **`Customerorder`, which is NOT in
`RestConfiguration.SDR_WRITE_WITHDRAWN`** (deliberately — live UI writer `store/common/order.js:15`
`$patch('/customerorder/…')`). So `PATCH /v3/customerorder/{id}` reproduces the mutation for a
**zero-function** `wms_user`, and is **worse** than the gated route: it skips
`getAvailableTransferLanesForUpdate`'s `PESSIMISTIC_WRITE`, so it can bind an already-held lane.
`SdrFunctionGuard` can't help — ships `OFF`, verb-blind, `Customerorder` unruled. **PROPOSED, not filed**
(T3). The other six ARE closed: `CustomerorderBatch` (`RestConfiguration:328`) and `PickingorderPosition`
(`:352`) are both withdrawn. Same shape as [[sbdev-3142]] / [[a-guard-fences-the-mechanism-you-aimed-at]].

**The negative rows are the whole mutation story.** Neither `ClubLineController` nor `TransfersController`
is in `FunctionGuardArchTest.SHARED_CONTROLLERS` (exactly StockUnit/Dashboard/ReplenishOrder/UnitLoad), so
**nothing forbids a class-level `@RequiresFunction`** — and one satisfies all ten positive rows
*identically*. Measured: that mutant reds ONLY on the 4 asserted-UNGATED sibling rows. Pin 131 → **145**.
`PickingOrderPositionController` has ONE declared handler, so no negative row is possible there.

⚠️ **A probe of a MUTATING endpoint must use non-existent IDs.** All ten do
`findById(id).orElseThrow(EntityNotFound)` *before* the service call, so a well-formed-but-absent id
proves the request passed authz without changing a row. **Keep them NUMERIC** — a non-numeric path var
400s before the interceptor and proves nothing. Assert **403 vs not-403**, never an exact status.
`sbdocs/9-System/scripts/probe-wms2-mutating-get-gating-dev.sh`; **dev password is `dev@sb`** and
`wmstest`(0 fns — the deprived seat)/`sbtest`(35)/`panderson`(80)/`truckloading`(35, NOT deprived) all share it. **AC-1 = 30/30**: handler-generated 404
`"CustomerOrderBatch not found by batchid: …"` vs a generic **114-byte** 404 on an unmapped route — that
size difference is how you tell "reached the handler" from "no such route".
`sbtest` is the two-directional differential (lacks CLUB_LINE + PICKING_POSITION, **holds**
TRANSFER_ORDER) — the only thing separating a correct gate from a deny-everyone gate.

🔴 **DEV GRANTS DRIFT MID-SESSION, AND A HARDCODED ACCOUNT ASSUMPTION BECOMES A FALSE RED THAT LOOKS
EXACTLY LIKE A BROKEN FIX.** Measured: `truckloading` was picked as the deprived subject off a query
showing **4 functions, no TRANSFER_ORDER**; ~2h later the identical query returned **35 functions
INCLUDING TRANSFER_ORDER** (same grants as `sbtest`, no duplicate user rows — somebody edited groups on
a live DEV). The post-deploy run reported **"5 fail"** on exactly the five transfers routes and read as
"the transfers gate is inert". It was not — those 404s were correct for a now-entitled user. What
settled it was probing **`wmstest` (0 functions, shares `dev@sb`)**, denied on all ten. **Use a
zero-function user as the deprived seat: zero is a floor and cannot drift downward.** `truckloading` is
NO LONGER deprived — do not reuse it in that seat, and note the SBDEV-3142 script still names it as
"4 fns". Re-derive grants before every probe run; the script header now says so.
See [[verify-script-traps]], [[advertised-capability-is-not-exploitable-capability]].

**`SurfaceInventoryContextTest` has exactly ONE assertion (`total > 200`)** — `mutating`/`gatedMutating`/
`ungatedMutating` are asserted nowhere and nothing reads the TSV, so widening its heuristic has **zero**
blast radius. Added `/assign` `/reassign` `/unlink` `/activate` `/run`: GET-MUTATE **9 → 19**, `read`
379 → 369, zero new FPs, bonus true positive `unlinkSelectedPallet`. **`/fix` rejected** — 9 matches, 7
plainly wrong (6 × `/v3/fixedAssignment/*` + `/replenish/fixedLocationUpperBound`). Three lanes gave three
different precision ratios, so the javadoc states **counts, not ratios**.

⚠️ **`/activateBatch` is served by a method named `activeBatch`** — eleventh instance of the name-lies
trap; key on path, never method name. ⚠️ **`WEB_UI_VIEW_PICKING_POSITION` gates NO screen in either UI**,
so "Option B" is name-association there, not screen precedent — but it and `CLUB_LINE` are held by the
identical three roles (CS-REP 4, outbound-manager 10, super-admin 37), so the constant choice changes the
population by nobody. ⚠️ Mobile is safe two ways: zero refs, and mobile's transfer screen uses a
*different* class, `controller/mobile/TransferOrderController` at `/transferOrder/*` — grepping `transfer`
alone conflates them.

**New test `MutatingGetGateUnitTest`** — the three existing controller unit tests all use plain
`setupMockMvc` (no interceptor ⇒ vacuous). Its G4 **entitled control asserts 200, not "not 403"**, because
a servlet 500 satisfies `isNotEqualTo(403)`.

Cypress: `club-line-order.cy.js`, `transfer-offsite.cy.js` + `wmsHelpers.js` call these as
`env.KC_USERNAME`; that user needs both WEB_UI constants or the specs red — the gate working, not flake.

Evidence: `sbdocs/1-Projects/wms2/plan/SBDEV-3155-evidence/`. Related: [[sbdev-3017-tranche1-mvc-gating]],
[[wms2-gating-programme-is-live-on-prd]], [[ac2-role-count-is-not-the-unit-user-population-is]].
