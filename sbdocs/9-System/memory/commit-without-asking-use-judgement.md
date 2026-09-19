---
name: commit-without-asking-use-judgement
description: "Nam 2026-09-01 — commit changes without asking, using my own judgement on what and when"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d8823e53-7d17-4b68-922c-fdad9422ff2d
  modified: 2026-09-01T21:01:14.833Z
---

Nam (2026-09-01): *"commit the changes as needed with your best judgement without asking me from now on."*

This is standing authorization to **commit** — it overrides the default "commit or push only when the
user asks". It covers what to commit, when, and how to split it.

**Why:** the alternative was leaving finished work uncommitted in a per-ticket worktree and asking each
time. That is the exact state `plan-state.sh` exists to detect — on SBDEV-2968 a plan read "not started"
while 46 dirty paths held the finished implementation. Uncommitted work is invisible work.

**How to apply:**
- Commit at natural checkpoints (a slice done, a rail green, a cleanup verified), not one giant commit.
- **Do not commit on top of a broken build.** Run the suite and compare against the known develop
  baseline first; if a failure is pre-existing, say so with evidence rather than assuming.
- Message ends with the required `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **This authorizes commit, not push or PR.** Pushing and opening a PR is `wms-plan-executor`'s job and
  is outward-facing — keep asking for those unless separately authorized. Never commit to a default
  branch; ticket work lives on its per-ticket worktree branch.

Related: [[plan-state-probe-beats-reading-plan-status]], [[spawn-agents-without-asking]],
[[deploy-only-to-develop-release-and-main-are-devops]].
