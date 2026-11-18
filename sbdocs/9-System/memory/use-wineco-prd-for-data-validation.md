---
name: use-wineco-prd-for-data-validation
description: "Nam 2026-10-26 — validate WMS v2 data claims on WineCo PRD (wsl-wineco-prd MCP, read-only) when it is connected, not only on DEV"
metadata:
  node_type: memory
  type: feedback
  originSessionId: c4d5faf2-c4b7-476e-b243-853d66611888
  modified: 2026-10-26T11:44:28.953Z
---

Nam, 2026-10-26: "WineCo's prod db is on. Use this for any data validation." The `wsl-wineco-prd` MCP (`wh01_om1_v2`) is read-only and is the high-volume v2 tenant.

**Why:** DEV data is sparse and e2e-polluted. On SBDEV-1564 the DEV census (2 intra-company batches) green-lit a rule that the PRD census (305 batches, all on REGULAR BOLs) showed would have stopped a live floor flow — [[offsite-transfers-ride-regular-bols]].

**How to apply:** for any "does this flow/shape exist", exposure, or pre-release data check, run it on `wsl-wineco-prd` when connected (keep the positive-control habit). DEV stays the place for seeding and manual tests (`wms-dev-probe`); never write to PRD.
