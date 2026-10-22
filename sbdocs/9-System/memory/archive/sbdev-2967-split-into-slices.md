---
name: sbdev-2967-split-into-slices
description: SBDEV-2967 web-UI gating was split 3 ways + handed a door to 3013; the monolith shipped two contradictory implementation instructions and 10 bad verify rows
metadata:
  type: project
---

SBDEV-2967 (web UI has no authorization layer) was split on 2026-08-21 into
`SBDEV-2967-A` (axios 403 logs you out — 1 file, unblocked, hard prereq for C),
`SBDEV-2967-B` (view gating: menu/routes/entry/admin tabs + VIEW grants),
`SBDEV-2967-C` (action gating: 13 endpoints + ACTION grants), with the
self-escalation gate moved out to **SBDEV-3013**. The original file is now an index;
the pre-split doc is in `4-Archieves/wms2/plan/SBDEV-2967-presplit-2026-08-21.md`.

**Why:** one gate (Brent's grant sign-off) blocked four workstreams and only two
needed it, and view-vs-action have opposite failure modes plus a deploy-order
constraint (UI before API gates) one PR can't honour.

**LANDMINE the split uncovered — the monolith contained BOTH instructions at once.**
§3.5 was headed *"REVERSED at architect review — the gates go on the CONTROLLER"* and
four paragraphs later said *"at the entry of the service method… **Not**
`@RequiresFunction`."* The test plan, risk R6 and **8 of the verify script's 50 rows**
encoded the superseded half — including row `E9`, which asserted no `WEB_UI_ACTION_*`
may appear inside a `@RequiresFunction` and so **would FAIL a correct implementation**.
Two more rows were dead: `E8` pinned `ADJUST_LOCK_DAMAGED` as "unchanged" when
`setLockDamaged` is unguarded, and `R2` forbade annotations on `StockUnitController`
that SBDEV-2968 had legitimately added. **A long plan can carry a reversed decision in
its prose while its script enforces the old one — reconcile heading vs trailing
paragraph before trusting either.** See [[verify-script-traps]].

Controller placement is correct because `StockUnitController:224-254` catches
`BusinessException` → `ResponseEntity.ok(errorMap)`, so a service-layer guard returns
**HTTP 200 on every bulk path**. Also: `WEB_UI_VIEW_TRANSFER_ORDER` was already granted
by 2968 D4 + V2.2.18 (orphan count 13→12); the method is
`getStorageLocationsForStockMovement` (the plan quotes the URL path); the mobile
services are in `service/mobile/`. Related: [[wms2-only-one-of-80-functions-is-enforced]],
[[wms2-function-gates-are-self-grantable-via-ungated-usercontroller]].
