---
name: squash-by-soft-reset-onto-moved-origin-reverts-peers
description: "Squashing via `git reset --soft origin/develop` right after a fetch silently reverts every commit that landed on develop since you branched"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 82a39929-1861-4013-a6f8-551c76cd7c65
  modified: 2026-10-06T18:15:02.129Z
---

To squash a branch, soft-reset to its **merge-base**, never to a freshly fetched `origin/develop`. If develop moved since you branched, `reset --soft origin/develop` + commit records your OLD tree on top of the NEW tip. The resulting commit silently reverts every peer change that landed in between. It looks like a normal commit and pushes cleanly.

**Why:** On SBDEV-3496 (2026-10-06), `git fetch && git reset --soft origin/develop && git commit` ran after SBDEV-3667 (PR #464) had merged. It produced a 14-file commit that undid 3667, and it was pushed before the `--stat` showed too many files. It was fixed before any PR was opened: soft-reset to the old base, recommit, rebase, then force-push with a lease.

**How to apply:**
- Squash with `git reset --soft $(git merge-base HEAD origin/develop)`, then rebase separately.
- Before every push, compare `git diff --stat origin/develop` against the files you actually touched. The file count is the tell.
- Related: [[git-add-all-in-worktree-sweeps-omc-state]], which is the same "commit contains things you did not author" family.
