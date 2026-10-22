---
name: sbdev-2821-tier1-putaway-candidate-surfacing
description: "SBDEV-2821 merged 2026-08-09 (wms2-api PR #135) — tier-1 putaway destination surfacing; landmines for SBDEV-2732 step 17a"
metadata: 
  node_type: memory
  type: project
  originSessionId: 38cc5645-9fe3-457e-a519-478ebfb361b8
  modified: 2026-08-09T13:18:29.261Z
---

SBDEV-2821 MERGED 2026-08-09 → wms2-api PR #135 into `develop` (merge `fd90487`, feature commit `cfb6d49`), ClickUp `on dev`. API-only: no Flyway, no sysprop, no deploy prerequisite. Design is **option (iii) route at putaway** — receiving is untouched; `LocationRepository.getPutAwayCandidateLocations(itemDataId, configuredLocationId)` UNIONs stock-derived candidates with the configured destination, which is passed as a **parameter** so [[sbdev-2732]] step 17a extends it by passing `Resolution.locationId()` rather than rewriting it.

**Why:** the merge unblocks SBDEV-2732 — its Q12 → (iv-b) diverts pick-face receipts to the putaway lane at every tier, which is only safe once putaway can *offer* them. Dependency order is `2731 → 2821 → 2732`; do NOT branch either off the other ([[stacked-v2-pr-merge-order-orphan-trap]]).

**How to apply — landmines:**
- **There are TWO type switches, not one.** `storeBoxOnLocation` AND `calculatePutAwayList:277-295` each have the same three-constant gap; the latter's `default:` only logs, so fixing one alone surfaces a club destination and then **silently drops it before the operator sees it**.
- **`PutAwayLane` is itself a `cases and pallets` location** with `useforstorage = false`, and is the `putawaylocation_id` of **8,803 of 8,804** SKUs on `wms2-wineco-dev`. The query's area predicate `(useforstorage = 'true' OR staginglane = true)` is load-bearing, not defensive — without it every putaway offers "put it back on the PutAwayLane".
- **Club lanes must never acquire a `FixLocationAssignment`** — they are live multi-SKU pick faces (`Club01` = 15 SKUs dev / 27 UAT) and `fix_location_assignment` is `UNIQUE(assignedlocation_id)`, so binding one to the first SKU breaks every other SKU on the lane.
- **The new UNION SQL has zero automated coverage and cannot get any** — the v2 Testcontainers lane can't boot ([[wms2-it-harness-broken-sbdev-2217]]) and unit tests mock the repository. It was only ever run as hand-executed SQL against `wms2-wineco-dev`. The first DEV run is its first pass through Hibernate; re-run plan §6.1 M1a/M1b on DEV before QA.
- Open, non-blocking: **Q13** (Brent — pre-select vs merely offer) gates the mobile-UI slice; the `wms2.putaway.*` counter is unbuilt. `DefaultStrategy` can throw if two `cases and pallets` locations share `(rack, rackrow, xpos, ypos)` — zero collisions on dev, **unverified on UAT and prd**.

Plan: `sbdocs/1-Projects/wms2/plan/SBDEV-2821-tier1-direct-placement-onto-pick-face.md`
