---
name: sbdev-3862-paused-handoff
description: "SBDEV-3862 DONE: #566 merged ab983389, dev-tested, plan ARCHIVED 2026-10-25; follow-ups live as P21/P23/P24; dev's Damaged location only admits Case/PickLocation"
metadata:
  type: project
---

SBDEV-3862 (mobile Move Unit Load onto a unit load on Damaged) is finished.
- **Shipped:** merged as wms2-api #566, merge commit `ab983389`, on 2026-10-25.
- **Dev-tested:** the same day, on `develop-ab983389`.
- **Plan:** archived at `sbdocs/4-Archieves/wms2/plan/SBDEV-3862-damaged-pallet-destination.md`. The worktree and the local branch are removed.

**Follow-ups:** recorded only in `sbdocs/2-Areas/proposals-register.md`, not in the archived plan.
- P21: the StockunitService existing-container path.
- P23: the mobile-UI `isDamagedDestination` prompt plus a read endpoint.
- P24: stranded Q3/Q4 rows, a monitoring owner, and option D if the counts grow.

**Why:** a future session will look for these items in the plan. They live in the register.

**How to apply:**
- To test anything "onto a carrier on Damaged" on dev, read this first. Dev's `Damaged` location (type "overstock box") admits only Case and PickLocation unit loads. Moving a Pallet or Tote there is refused with "Unit load type X is not permitted on location Damaged", so carrier-onto-Damaged scenarios cannot be built there.
- Use an existing Case on Damaged (there are about 97) as the destination instead.
- A no-function user can be simulated with a temporary group and role that grants only `MOBILE_UI_VIEW_TRANSFER`. `AccessService.doesUserHaveAccess` is a live query, not cached.

Related: [[sbdev-3908-on-dev]].
