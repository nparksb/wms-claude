---
name: lane-a-git-cherry-false-positives
description: "WMS v1→v2 Lane A sweeps — git cherry \"+\" is unreliable; verify by actually cherry-picking before counting a commit as a real port"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d2a9595f-cbdf-4fb9-a144-7104d26f9ae1
---

In the WMS v1→v2 sync sweep (Lane A, UI repos), `git cherry -v` flags commits `+` (= "not in v2") that are actually already applied in v2. v2 often re-implements the same v1 fix independently, producing a different patch-id that `git cherry` can't match. On the 2026-06-18 sweep, 3 of 4 web-ui `+` commits (`608d4d3`, `523e4e2`, `80041f4`) were already in v2 — they surfaced as empty cherry-picks or a whitespace-only (`try{ ` vs `try{`) conflict.

**Why:** patch-id matching is exact; v2's independent ports diverge in whitespace/context, so `git cherry` over-reports work as pending.

**How to apply:** never count a `git cherry +` commit as a real port from the cherry output alone. Actually run `git cherry-pick -x <sha>` (or inspect the target file for the change's distinctive markers). An empty cherry-pick ("nothing to commit") or a whitespace-only conflict = already-done → skip. Only commits that apply with real content are genuine ports. Reconcile the sweep report/sync-log to actual outcomes, not the cherry pre-count.

Related: [[wineco-wsl-v1-v2-migration-status]] context for the broader v1→v2 effort.
