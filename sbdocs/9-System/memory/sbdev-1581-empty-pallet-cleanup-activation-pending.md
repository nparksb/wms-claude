---
name: sbdev-1581-empty-pallet-cleanup-activation-pending
description: SBDEV-1581 EmptyPalletCleanupJob ships OFF (V2.2.41 seeds ACTIVATED=false); per-tenant flip is a manual release step
metadata:
  node_type: memory
  type: project
  originSessionId: 484a2664-bd66-401f-85e6-3a119302a313
  modified: 2026-10-19T13:06:48.338Z
---

SBDEV-1581 (wms2-api PRs #533 + #539, on dev 2026-10-20 as develop-a2654bcf) adds the nightly `EmptyPalletCleanupJob` (lock `100011L`, Flyway `V2.2.41`). **Pallets only** — Carts were excluded by #539 because no v2 tenant's EmptyPallets location_constraint admits a Cart (checked on all nine DBs); don't re-add Cart without a Cart destination. It is **inert after deploy**: `EMPTY_PALLET_CLEANUP_ACTIVATED` is seeded `false` on every tenant.

**Why:** Nam decided the first run should move the whole backlog, but seeding `true` would have bulk-moved pallets fleet-wide (dev, UAT, Hydra) at the first night after deploy with no per-tenant review.

**How to apply:** after merge and a dev run, set `EMPTY_PALLET_CLEANUP_ACTIVATED=true` on WineCo, ShipItEZ c1wh and nywh (Hydra has 0 candidates). PRD candidates 2026-10-19: 72 / 18 / 22. "Storage location" = `location_area.useforstorage = true` (excludes Shipped, Palletizing, PutAwayLane, lanes). V2.2.40 belongs to SBDEV-3672 — whichever merges second applies out of order. See [[wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway]].
