---
name: postgres-mcp-pglast-720-deleted-needs-override
description: ALL 15 DB MCPs died with CONNECTION_CLOSED because PyPI pglast 7.2.0 has no files; postgres-mcp pins it — fixed with uvx --overrides pglast==7.21
metadata:
  node_type: memory
  type: reference
  originSessionId: e0bdbabe-4501-4b0d-b267-d7510d74a1a6
  modified: 2026-10-25T13:23:42.772Z
---

**Symptom (2026-10-25):** every DB MCP (`*-prd`, `*-uat`, `*-dev`, `landlord-*`, `wms1-*`) showed `CONNECTION_CLOSED` even with the SSH tunnels up (25060/25061/25062 open, `psql` worked). `/mcp` reconnect failed too.

**Cause:** the servers launch as `uvx --python 3.12 --with 'mcp<2' postgres-mcp …`. Every `postgres-mcp` from 0.1.1 to 0.3.0 pins `pglast==7.2.0`, and PyPI's 7.2.0 release now has **zero files**. Version 0.1.0 needs Python 3.13. So uv resolves nothing and exits in about 1 s. It had worked until uv's cached tool environment had to resolve again. Run the launch command by hand to see the uv error; Claude Code only reports "Connection closed".

**Fix applied:** the overrides file `~/.config/postgres-mcp-overrides.txt` contains `pglast==7.21`, and every postgres-mcp server's args gained `--overrides <that file>` before `postgres-mcp` in `~/.claude.json`. The original was backed up as `~/.claude.json.bak-pglast-20261025222314`. Verified: the server initializes and logs "Successfully connected".

**How to apply:**
- If the DB MCPs die again, check this first by running one server's command by hand, with the URI redacted.
- A server added later needs the same `--overrides` arg.
- A running session keeps its startup MCP registry, so use `/mcp` reconnect or a new session. Meanwhile, use the psql fallback in [[wms-mcp-tools-not-surfaced-use-psql-direct]].
