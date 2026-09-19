---
name: wms-mcp-first-query-after-idle-drops
description: "wms DB MCP servers' first query after idle fails with \"server closed the connection unexpectedly\" — retry once before diagnosing"
metadata: 
  node_type: memory
  type: reference
  originSessionId: b1a874d2-faf1-493a-91e4-8d1e02a8f8e5
---

The `wms1-*`/`wms2-*` database MCP servers (SSH-tunneled Postgres) routinely fail the **first**
`execute_sql` after the connection has sat idle with:
`Error: consuming input failed: server closed the connection unexpectedly`.

An immediate retry of the same query succeeds. Observed 2026-06-11 on `wms2-hydra-dev2`,
`wms2-wineco-dev2`, and `wms2-wineco-dev` (each recovered on retry #1).

**How to apply:** retry once before concluding the tunnel/DB is down or asking the user to restart
anything. Only escalate if the retry also fails.
