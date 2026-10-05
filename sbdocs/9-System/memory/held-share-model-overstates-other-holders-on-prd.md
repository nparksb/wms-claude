---
name: held-share-model-overstates-other-holders-on-prd
description: "ReservationShare's ownShare treats other orders' requestedamount as what they hold; on PRD that is often false, so held-only releases can fail a move"
metadata:
  node_type: memory
  type: project
  originSessionId: 9775f266-5768-4333-9db0-d5d02f6f315b
  modified: 2026-10-02T00:17:24.476Z
---

`ReservationShare.ownShare` (SBDEV-3605/3618) subtracts every OTHER open replenish order's `requestedamount` as if each held it. On PRD 2026-10-02, 23 open orders held less than they requested (17 wsl-wineco, 6 c1wh-shipitez; e.g. requests 19, holds 0). So a path that releases only `held` and then MOVES stock can under-release and fail a transfer the old code completed.

**Why:** SBDEV-3621 initially did held-only at the handheld finish; both review lanes found it (M1). Nam chose: single-UL finish releases `min(requested⁺, max(held, amountPicked − (amount − reserved)))` (unclamped term; a clamped `free` broke over-reserved sources); multi-UL finish releases exactly requested (undo of its own same-tx booking).

**How to apply:** any new release site that is followed by a stock move must include "what the move physically needs", not held alone. Cause of the drift is unverified; the likely suspect is the pre-SBDEV-3618 recalc still on prd. Re-query before assuming the count. Related: [[hydra-prd-has-never-had-a-replenishorder-row]], [[wms2-deployed-image-differs-from-branch-head]].
