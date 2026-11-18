---
name: never-print-process-command-lines
description: Never run pgrep -fl / ps aux / ps -ef or anything that prints process command lines; find peer Maven runs by cwd or count only
metadata:
  type: feedback
---

Never print process command lines (`pgrep -fl`, `pgrep -a`, `ps aux`, `ps -ef`, `ps -o args`). Count with `pgrep -f '<pat>' | wc -l`, or list only working directories:
`for p in $(pgrep -f 'surefire|failsafe|plexus-classworlds'); do lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'; done | sort | uniq -c`

**Why:** an earlier `ps | grep` printed postgres-mcp connection strings with passwords (wms2_landlord_app, wh01_om1, wh01_om1_v2_app) into the transcript; Nam's rule since is "never list process args". On 2026-10-29 (SBDEV-3951) I broke it twice with `pgrep -fl`, because three memories still recommended that exact command — no secret leaked those times (Java/Maven args), but the next process might be an MCP server.

**How to apply:** any "is a peer Maven/Jest running?" check — the cwd form shows the peer's worktree, which is all the decision needs. A self-matching wait loop is still a trap: see [[concurrent-maven-one-worktree-false-reds]]. Related: [[hub-secrets-exposures]].
