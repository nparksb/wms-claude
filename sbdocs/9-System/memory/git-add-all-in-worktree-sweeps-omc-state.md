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

## 2026-10-06 (SBDEV-3658): the same hazard WITHOUT `-A`, in the sbdocs vault

`git add sbdocs/3-Resources/data-dictionary/wms2-sysprop-catalog.md` — one explicit path, the thing the
rule above tells you to do — swept in **another session's uncommitted SBDEV-3654 work** on that file: the
whole §6 RETIRED rewrite, the §11.1 seed annotation, the §11.2 ON/OFF row, a changelog row and a
`verified_by` entry. They committed under a message describing only SBDEV-3658's part, and could not be
split afterwards because 3654 had rewritten the very row 3658 appended to — one line, two tickets.

**Why:** naming the path bounds WHICH file you stage, not WHOSE edits. The vault is shared and routinely
dirty; the session-start `git status` had listed that file as modified and I staged it without looking.

**How to apply:** in `sbdocs/`, run `git diff -- <file>` before staging and confirm every hunk is yours.
If it is not, either `git add -p` your hunks, or commit the mixture with a message that names which hunks
belong to which ticket — never a subject line implying one ticket. Caught here only because a review lane
read the commit; `git commit` itself says nothing.
