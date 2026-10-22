---
name: sbdev-3016-mobile-controller-cleanups
description: "SBDEV-3016 — MERGED on dev 2d56ac4c; Fix 1 shipped unlinked via 8019d58a and is NOT on main; the logger misattribution is 31 sites, not 1"
metadata: 
  node_type: memory
  type: project
  originSessionId: 41868bc9-fa80-4349-b283-55928699953e
  modified: 2026-09-01T18:17:30.560Z
---

SBDEV-3016 bundled two mobile-controller defects. Resolved 2026-09-01 as **T0**.

**Fix 1 — the two reachable 500s: already closed, by an unrelated PR.** `8019d58a`
(2026-08-28, PR #247 `claude/wms-500-errors-failures-zqbvlq`, merged `8dc8f74e`) null-guards
`loadOrderById` in all three of `ReplenishController.checkSource` / `checkAmount` /
`checkDestination` (`:195`, `:225`, `:256`). On `origin/develop` **and** `origin/release`,
**not on `main`** — so prd still 500s. Nothing links the commit to the ticket, so SBDEV-3016
sat `Open` right through it. Same trap as [[sbdev-2781-expected-return-date-date-only]].

Two corrections the ticket text still carries and that a reader will otherwise trust:
- **The fix chose the HTTP 200 `{"errors":[…]}` envelope, not the 400 the ticket recommended.**
  So `checkAmount` no longer returns 400 for a bad id either — **all three rows of the ticket's
  evidence table are stale**, not just the two red ones. All three are now consistent, which
  was the real goal.
- `8019d58a` also fixed a cause the ticket never saw: `MobileReplenishService`
  `.setOrderToReplenishMobileOrder` had an unguarded `orElseThrow` on the source stockunit,
  making any order whose source stock was drained-and-deleted impossible to even load — and
  `checkSource`'s switch-unit-load path is the recovery flow for exactly that state.

**Fix 2 — the mangled name: MERGED `on dev` as `2d56ac4c` (PR #263, 2026-09-01), commits
`d5a0d19f` + `6c14a179`.** `requpickingOrdersestLocation` →
`requestPickingOrders` in `controller/mobile/PickingController.java:240`. Chose
`requestPickingOrders` over the ticket's other suggestion `pickingOrders` because
`getPickingOrders` is **already taken by both `MobilePickingService` and
`PickingorderRepository`**, and a bare `pickingOrders` invites the duplicate-handler-name
collision SBDEV-2968 §14.14 warns about.

**The rename is authorization-neutral, and this is the only thing worth re-checking on any
future handler rename here.** `FunctionGuardInterceptor` resolves via reflective annotation
lookup (`@RequiresFunction` / `@PublicHandler`) plus `GUARDED.contains(declaringClass)` —
never a name string. `PickingController` carries `@RequiresFunction(MOBILE_UI_VIEW_PICKING)`
at **class** level (`:33`) and is in `GUARDED` (`FunctionGuardInterceptor:123`). The three
`getMethod().getName()` sites at `:223`/`:234`/`:249` are log text and a Micrometer tag on
`METRIC_PUBLIC`, which fires only in the `@PublicHandler` branch. See
[[wms2-gate-a-route-on-its-screens-existing-function]].

**Mutation instrument for a pure rename.** There is no red-first test for a rename, and
§14.14 forbids adding one keyed on the method name. What works instead: break the
`@GetMapping` path in a throwaway worktree and confirm the existing **path-driven MockMvc**
tests go red. `/pickingOrdersMUTANT/{input}` turned exactly the two
`PickingControllerUnitTest$PickingOrders` tests red (19 run / 2 fail), green again unmutated —
so they are a live pin on "this URL still routes to this handler". Full suite 5982/0/0/67.

**New finding, filed on the ticket, NOT fixed: the logger misattribution is 31 sites, not 1.**
The ticket found one mangled *identifier*; sweeping for the underlying defect — a `LOG.debug`
label naming a *different real handler* — finds 30 more across 10 of the 11 mobile
controllers. `PutawayController.requestLocation` logs `"scanPallet"` (`:41`,`:67`),
`MoveUnitloadController.selectStock` logs `"selectSource"` (`:86`),
`ReplenishController.clientList` logs `"orderList"` (`:165`),
`PalletizingController.scanUnitLoad` logs `"scanParcel"`, `TruckLoadingController.scanGate`
logs `"scanDestination"`. **The merged `chore/wms2-misattributed-loggers` sweep never touched
any of these files** — a genuine gap in that chore, not a re-report. ~7 lines if scoped to the
genuinely-wrong ones (the rest are generic `start`/`end`/`search`/`Failed` prefixes).
Harm is real: a log grep for a handler name returns another handler's traffic.
See [[a-guard-fences-the-mechanism-you-aimed-at]].

**A review lane's APPROVE is scoped to the revision it saw.** Lane A approved a 2-line diff;
taking its own Low reworded one of those lines and a third was added after — so two of the three
shipped lines carried an approval that never covered them, and the PR body said "Independent
review lane: APPROVE" flat. A second lane spawned at exactly that gap is what confirmed line 303
was the enclosing method's own log rather than a copy-paste from a shared helper. Re-review after
acting on findings, and state which revision each verdict covers.
See [[idle-review-subagent-is-not-a-passing-review]].
