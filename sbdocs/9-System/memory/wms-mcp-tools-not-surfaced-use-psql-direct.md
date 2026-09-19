---
name: wms-mcp-tools-not-surfaced-use-psql-direct
description: UAT/PRD DB MCP tools can stay absent from the session all turn even while `claude mcp list` says Connected — fall back to psql with the URIs from ~/.claude.json
metadata:
  type: reference
---

When a tenant DB MCP server's tools never appear in the deferred-tool list, do **not** report the
environment as unreachable. Measured 2026-08-25 during SBDEV-3004 triage: `nywh-hydra-uat`,
`wsl-wineco-uat`, `c1wh-shipitez-uat` and `nywh-shipitez-uat` never surfaced any
`mcp__<server>__execute_sql` for the whole session — two `ToolSearch` sweeps and a
`select:`-by-name query all returned nothing — while `claude mcp list` reported all four
**✔ Connected**. The health check and the session's tool registry disagree, and the registry is the
one that blocks you.

Inverted too: the four `*-dev` servers showed **✘ Failed to connect / timed out after 30000ms** in
that same health check, yet `mcp__wms2-wineco-dev__execute_sql` worked fine all session. So
`claude mcp list` is not evidence either way — it is a fresh probe, not the session's state.

**The fallback:** `psql` is on PATH (16.14) and every connection URI is in `~/.claude.json`
(`grep -o '"[a-z0-9-]*uat[a-z0-9-]*"'` to find server names, or just read `claude mcp list` output,
which prints the full URI including credentials). Port convention on the local tunnels:
**25060 = dev, 25062 = UAT, 25061 = PRD**. Percent-encoded passwords work as-is in the URI.
Use `psql "$uri" -qAtX -c "$SQL"` and loop the tenants in one Bash call — five environments in a
single round-trip, faster than the MCP path anyway.

This is distinct from [[wms-mcp-first-query-after-idle-drops]], which is a *connected* server
dropping its first query after idle and needing one retry. Here the tool never exists to call.

Relevant to the floor's "one DB query confirming the symptom" ([[wms-fix-effort-tiers-and-the-floor]]):
never downgrade a tier or ship a caveat like "could not verify the UAT tenants" before trying psql.
