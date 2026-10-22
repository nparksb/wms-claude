---
name: pkill-f-matches-its-own-shell
description: "pkill -f <worktree path> kills the Bash tool's own shell (exit 144) and orphans the surefire/failsafe fork, which keeps the shared flock"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 8d065bea-3b84-445b-bf5f-dce68ef8df92
  modified: 2026-10-08T19:01:45.641Z
---

`pkill -f "<pattern>"` run from the Bash tool also matches the tool's own `bash -c` wrapper, because the pattern text is in that command line. Measured 2026-10-08 (SBDEV-3286): the call died with exit 144, the Maven parent was killed, and the forked failsafe JVM survived as an orphan. Its cwd was the worktree, it was still running tests, and it plausibly kept `/tmp/wms2-maven.lock` held.

**Why:** a killed build that leaves its fork running also leaves the shared Testcontainers DB and the build lock busy. Peers then see false reds (see [[concurrent-maven-one-worktree-false-reds]]).

**How to apply:** find the PIDs first (`pgrep -af`, or `ls -l /proc/<pid>/cwd` to confirm ownership), then `kill <pid>`, then `kill -9` if it survives. Never `pkill -f` on a string that also appears in the command you are typing. Check for surviving `surefire`/`failsafe` JVMs afterwards.
