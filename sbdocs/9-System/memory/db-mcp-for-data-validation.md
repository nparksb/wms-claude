---
name: db-mcp-for-data-validation
description: Which DB MCP to use when validating WMS data against a live database
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d18a8b35-9ef9-4731-b129-9b83a1d561ce
---

Use the **`wms2-wineco-dev`** DB MCP server for any live-data validation on this repo (postgres-mcp → `dev_wh01_om1` on localhost:25060). It is the user's designated/new DB MCP. Do NOT default to `wms1-wineco-dev` for v2 validation.

**Why:** The user added `wms2-wineco-dev` specifically for v2 data checks; `wms1-wineco-dev` points at the v1 database (`wh01_om1`).

**How to apply:** When a task needs empirical confirmation (row counts, column values, verifying a fix's premise), query `wms2-wineco-dev`. Note: newly-added MCP servers are not visible to an already-running session — if its tools aren't loaded, tell the user to reconnect via `/mcp` or restart Claude Code before attempting queries. Both wineco servers run `--access-mode=unrestricted`, so prefer read-only SELECTs for validation.
