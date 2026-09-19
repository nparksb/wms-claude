---
name: wms-on-hold-55-is-fragmentation-not-shortage
description: WMS order position state 55 on a SKU with no fix_location_assignment means stock is sufficient but FRAGMENTED across unit loads, not short — the SBDEV-2512 guard
metadata:
  type: project
---

**Position state 55 (`RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION`, "Not enough stock on location") on a
position whose SKU has NO `fix_location_assignment` row is a two-condition fingerprint, and the label
lies:** aggregate pickable stock **was sufficient**, and **no single stock unit covered the position**.
It is written by the SBDEV-2512 Fix A guard (`ReleaseOrderJobService`, `reserveSingleCoveringUnit`).
If aggregate stock were genuinely short the job writes **56**, not 55 — so 55 + no-fix-assignment can
only be the fragmentation guard. Confirmed on SBDEV-3371 (WineCo v1, 2026-09-16).

The guard applies to **100% of positions**: `OrderRestController` hard-codes
`setPartitionallowed(false)` on import and there is no `true` writer anywhere (0 true / 0 null in
1.73M rows ever written). `partitionallowed` is dead configuration — a fix framed as "flag these
orders correctly" has no writer to go through.

**Why:** it reads as an inventory shortage to everyone — client, ops and the order list (order state
50 = "On Hold", no reason shown). On SBDEV-3371 WineCo reported "the stock is right there in Club01 /
Club02"; it was, 3+2+1 = 6 for a 6-bottle line and 10+2 = 12 for a 12-bottle line. Club01/Club02 are
ordinary `Storage and Picking` locations (`useforpicking = true`) — club-location eligibility is a red
herring; the stock **was** counted. Club faces just accumulate small partial unit loads from club-run
leftovers, so they hit this shape most.

**How to apply:**
- Diagnose with: per-SKU `max(amount - reservedamount)` vs the position amount over
  `location_area.useforpicking = true`, `entity_lock = 0`. Aggregate >= requested AND max unit <
  requested ⇒ this guard.
- Unblock without code: mobile **Move Stock** (`/v3/moveStock`) merges same-SKU stock units onto one
  unit load (`dest.amount += amount`) → one covering unit → releases on the next per-minute cron. Or
  move a big enough unit load in from a `useforreplenish` area.
- Emergency software lever: insert `los_sysprop` row `ENFORCE_PARTITIONALLOWED = false` (absent row
  defaults the guard **ON**). No redeploy. It disables Fix B too, so split picking returns everywhere.
- Ops already has a surface: the Replenishment Monitor (SBDEV-3120) exposes `max_unsplittable_amount`
  vs `largest_single_unit`; the mobile Replenish > Critical list renders it.
- The behaviour is **order-sequence-dependent**: on SBDEV-3371 a sibling order for the same SKU and
  amount took the one covering unit 8 minutes earlier and shipped; its twin held.
- **v2/wms2-api carries the same guard** (`ReleaseOrderJobService` + the same sysprop key).
- Prod v1 tags are cut from `origin/release`; `origin/main` is stale (2026-07-09) and does NOT contain
  the guard — never infer what's deployed from `main`.

Related: [[wms-fix-effort-tiers-and-the-floor]], [[a-guard-fences-the-mechanism-you-aimed-at]]
