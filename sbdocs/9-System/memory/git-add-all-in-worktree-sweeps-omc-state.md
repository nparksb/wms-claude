---
name: git-add-all-in-worktree-sweeps-omc-state
description: "`git add -A` in a per-ticket worktree committed OMC session-state files (.omc/state/*, session ids, paths) into a product repo"
metadata:
  node_type: memory
  type: feedback
  originSessionId: f484decd-885c-4180-b84b-9440b4c11191
  modified: 2026-10-04T04:09:11.471Z
---

On SBDEV-2624 (2026-10-02), running `git add -A` in `.claude/worktrees/oms-laravel-api/SBDEV-2624` committed four OMC session files (`.omc/state/agent-replay-*.jsonl`, `hud-stdin-cache.json`, and `sessions/<id>/…`), which leak transcript paths and session ids. oms-laravel-api's `.gitignore` doesn't list `.omc/`, and OMC writes state into whatever cwd the session is in. The conformance verifier caught it before push, and the commit had to be rewritten.

**Why:** a stray artifact in a shared repo leaks local session data, and the fix means a history rewrite.

**How to apply:** in sub-repo worktrees, stage explicit paths (`git add src/ tests/ app/`), never `-A`. Or add `.omc/` to `$(git rev-parse --git-common-dir)/info/exclude` when creating the worktree; that's local and adds no scope to the PR. Check `git diff --stat origin/develop...HEAD | grep omc` before any push. Related: [[review-lanes-must-not-share-a-worktree]].
