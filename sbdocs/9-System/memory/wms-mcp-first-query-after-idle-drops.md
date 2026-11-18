---
name: wms-mcp-first-query-after-idle-drops
description: "wms DB MCP servers' first query after idle fails with \"server closed the connection unexpectedly\" — retry once before diagnosing"
metadata: 
  node_type: memory
  type: reference
  originSessionId: b1a874d2-faf1-493a-91e4-8d1e02a8f8e5
  modified: 2026-11-03T13:01:02.316Z
---

The `wms1-*`/`wms2-*` database MCP servers (SSH-tunneled Postgres) routinely fail the **first**
`execute_sql` after the connection has sat idle with:
`Error: consuming input failed: server closed the connection unexpectedly`.

An immediate retry of the same query succeeds. Observed 2026-06-11 on `wms2-hydra-dev2`,
`wms2-wineco-dev2`, and `wms2-wineco-dev` (each recovered on retry #1).

**How to apply:** retry once before concluding the tunnel/DB is down or asking the user to restart
anything. Only escalate if the retry also fails.

**Still true 2026-11-03, and it covers the PRD servers too.** `wsl-wineco-prd`, `nywh-hydra-prd`,
`nywh-shipitez-prd`, `c1wh-shipitez-prd` and `wms2-wineco-dev` each dropped their first query of the
session (three of them in one parallel batch); every retry succeeded. Two refinements:
- A dropped first query is **not a result**: never record "tenant not reachable" or "0 rows" from it.
  On SBDEV-3999 the three PRD censuses all failed together and came back clean on retry.
- `wms-dev-probe`'s `q.sh` (direct psql to DEV) is unaffected, so for DEV prefer it when the MCP
  keeps dropping. Prefer one tiny probe query (`select 1`) per server before a batch of real ones.
