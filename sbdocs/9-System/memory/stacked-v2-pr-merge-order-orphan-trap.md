---
name: stacked-v2-pr-merge-order-orphan-trap
description: "In wms v1→v2 sync Lane B, stacked v2 PRs must merge base-first INTO develop or get orphaned"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: de3c793e-3b2a-4867-a86a-d6728c73aacc
---

When a Lane-B sync port stacks v2 PRs (e.g. PR-B based on PR-A's branch), the stacked PR MUST be merged into `develop` — either by merging A→develop first (GitHub then auto-retargets B's base to develop) or by retargeting B to develop after A lands. NEVER merge the stacked PR into the (soon-to-be-deleted) base branch.

**Why:** On the 2026-06-25 sweep, SBDEV-2481's PR #51 was merged into its stacked base `port/SBDEV-2488-relocation-stock-history` instead of develop. That base merged to develop via a *squash* that didn't include #51, so #51's content (`PickLineRealignmentService`, the BLOCK_REALIGN loop) was orphaned on its branch and never reached develop — yet the sync-log advanced the wms-api anchor counting it as landed. Discovered only on 2026-06-26 because SBDEV-2492 depended on that base. Recovery: clean cherry-pick of the orphaned commit onto develop (PR #52).

**How to apply:** After a stacked-PR sync port, verify each commit is actually an ancestor of `origin/develop` (`git merge-base --is-ancestor <sha> origin/develop`) BEFORE advancing the sync-log anchor — don't trust "PR merged" status, since a PR can merge into a throwaway base. Document the merge order loudly in the PR body. See [[wms2-it-harness-broken-sbdev-2217]] for why these ports ship with @Disabled ITs.

**SECOND SHAPE, measured 2026-08-27 — pushing to a branch AFTER its PR merged.** Not a wrong merge
*order*: PR #220 was merged (by another session) at 20:23:04Z capturing branch tip `f98d665e`; I then pushed
`70f79584` to that same branch. **A merged PR's branch is a dead end** — the commit went to the remote
branch and never to `develop`, so `develop` carried a version of the code whose central guard had six known
escapes for ~40 min. Recovery: re-cut onto fresh `origin/develop` and open a new PR (#223).

**The check, after EVERY push, no exceptions:**
```bash
git merge-base --is-ancestor <commit> origin/develop && echo ON || echo NOT-ON
```
- A successful `git push` is **not** evidence the work is on `develop`.
- `gh pr view <n>` showing `MERGED` says nothing about commits pushed **after** that `mergedAt`.
- Better still, confirm the *content*: `git show origin/develop:<path> | grep -c <marker>` — that is what
  revealed the gap here (0 markers where 9 were expected).

**Root cause was concurrency:** another session was merging PRs and editing the same plan document at the
same time (it also appended a duplicate section number). **When another session may be active on the same
repo, re-fetch and re-check ancestry before assuming any earlier push still describes reality.**
