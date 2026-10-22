---
name: pgrep-f-wait-loop-matches-itself
description: "`while pgrep -f plexus-classworlds; do sleep; done; mvn ...` never starts — every queued loop's own bash command line contains the pattern, so loops deadlock on each other"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 1622ae45-d0bb-48e8-bd54-3543480f2f93
  modified: 2026-10-07T16:38:36.643Z
---

Measured 2026-10-07 (SBDEV-3677): a "wait for the peer's Maven, then run mine" loop sat forever.
`pgrep -f plexus-classworlds` matched the **waiting bash shells themselves** (their command line
contains the literal string), so with two or more queued loops each sees the others and none ever
starts. My own earlier one-shot check printed "PEER MAVEN RUNNING" when no JVM existed. The other
session's 3496 jobs were stuck the same way.

**Why:** `pgrep -f` matches the full argv of every process, including the shell running the loop.

**How to apply:** gate on Maven's launcher class with the bracket trick (a peer session's fix, verified):
`while pgrep -f '[c]lassworlds\.launcher\.Launcher' >/dev/null; do sleep 15; done` — it can't self-match, and
other waiters' `plexus-classworlds` argv doesn't contain the launcher class. Or check for a real JVM —
`ps -eo args | grep -E '^\S*java .*classworlds' | grep -v grep` — or `pgrep -f '^\S*java .*classworlds'`.
If a background run "hasn't started", look for its log file before assuming it's queued behind a peer.
Related: [[concurrent-maven-one-worktree-false-reds]].

---

**Additions from the SBDEV-3674 session, 2026-10-07 (same incident, other side of it).**

Scale when it was caught: **8 processes matched the pattern and 0 were Java JVMs** — the only `java`
on the box was DBeaver. Three sessions had jobs "queued" for hours with nothing building, and two of
them were additionally pointed at `(deleted)` worktrees, so they could never have succeeded anyway.

- **Prefer `flock` over any pattern-matching loop.** It is atomic, queues properly, releases when the
  holder dies, and cannot self-match:
  ```bash
  flock /tmp/wms2-maven.lock mvn -B -ntp -o verify ...
  flock -n /tmp/wms2-maven.lock mvn ... || echo "busy"   # non-blocking probe
  ```
- **The bracket trick fixes SELF-match but not SIBLING-match.** Both matter: other sessions' waiters
  carry `plexus-classworlds` in their argv, so a pattern containing that substring is blocked by them
  even once it stops matching itself. `[c]lassworlds\.launcher\.Launcher` avoids both, because the
  peers' waiters do not contain the launcher class.
- **Test the predicate before waiting on it** — one command, and it is the step that was skipped:
  ```bash
  pgrep -f '<pattern>' >/dev/null && echo "WOULD BLOCK — suspect self-match" || echo "gate opens"
  ```
  A wait condition is an instrument. An untested one that says *keep waiting* is indistinguishable
  from a broken one — and the broken state is the one that confirms your assumption that the queue is
  merely busy. Same shape as [[a-zero-scan-needs-a-positive-control]].
- **Bound every wait and emit a heartbeat.** An unbounded silent wait makes a hang look like patience.
- ⚠ **Do not infer which session owns a background process from a scratchpad UUID in its argv.** Doing
  that mis-attributed five stuck jobs to the wrong two sessions; both peers corrected it. Use the
  process's `ppid` and that parent's identity, or just report the pids and let each session check.
