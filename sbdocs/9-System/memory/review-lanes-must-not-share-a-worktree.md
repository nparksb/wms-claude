---
name: review-lanes-must-not-share-a-worktree
description: Two review subagents on one worktree — a stash/pop in one silently made the other grade the baseline
metadata:
  type: feedback
---

Measured 2026-08-28 (SBDEV-3136). I pointed two parallel review lanes at the **same** git
worktree. One lane ran `git stash push && mvn test && git stash pop` to establish its own
baseline. During that window the other lane's tree read as **0 changed files**, and one of its
experiments silently graded the **baseline instead of the change** — it reported a test failure
it then had to spend effort disproving as a "phantom".

**Why:** a worktree is shared mutable state. `git stash` is invisible to a sibling agent, and a
green/red result against the stashed tree is indistinguishable from one against the change.
Nothing in the tooling warns you.

**How to apply:** give each review lane its **own** detached worktree
(`git worktree add --detach <path> <ref>`), or explicitly forbid any lane from mutating the tree
(no stash, no checkout, no `mvn clean` on a shared target). If a lane must establish a baseline,
it must do it in a worktree it created itself. Serializing the lanes also works but throws away
the parallelism.

Corollary: when a review lane reports a result that contradicts your own run, **suspect a tree
race before suspecting the code** — and confirm the change was actually present when it measured.
Relatedly, a lane can also observe *your own* in-flight mutation experiment and misattribute it.

See [[subagents-must-write-deliverable-to-a-file]] and
[[idle-review-subagent-is-not-a-passing-review]].

## `cp -a` of a WORKTREE does NOT isolate git state (measured 2026-08-28, SBDEV-3017)

I told a review lane to isolate itself with `cp -a <worktree> <scratch>`. It did — and its
`git checkout <parent> -- src/` still wrote into **my** index, leaving 21 files staged with the
pre-change content while the working tree matched HEAD. `git status` showed `MM` on every file
while `git diff HEAD` was **empty**, which is a state that reads as corruption.

**Why:** in a `git worktree`, `.git` is a **file**, not a directory:

```
$ cat <worktree>/.git
gitdir: /path/to/repo/.git/worktrees/<name>
```

`cp -a` copies that file verbatim, so the copy points at the **original's** worktree metadata —
same index, same HEAD, same reflog. Every git command in the "isolated" copy operates on the
source worktree. Only the file contents are isolated; all git state is shared.

**How to apply:** to isolate a lane, use `git worktree add --detach <path> <ref>` (a real,
independent worktree), or `git clone`. If you must `cp -a`, delete the copy's `.git` first, or
tell the lane to touch files only and never run a git command that writes (`checkout`, `add`,
`stash`, `reset`, `commit`).

**The tell:** `git status` reporting `MM` while `git diff HEAD` is empty means the INDEX is out of
sync with both HEAD and the worktree. `git reset` (mixed) repairs it and loses nothing, but verify
`git diff HEAD` is empty first — if it is not, the worktree itself was written to as well.

## And do not run two `mvn` invocations in ONE worktree — measured twice, 2026-08-28

Same shared-mutable-state rule, applied to myself rather than to a lane. Twice in one session I started
`mvn -o clean test` in the background and then ran another `mvn` in the **same worktree** while it was in
flight. Results:

- **First time:** the suite's log ended mid-run with no `BUILD` line. Nothing was reported from it, but a
  truncated log reads exactly like a result.
- **Second time, worse:** the concurrent `clean` wiped `target/` under the running suite and it reported
  **`Tests run: 5703, Failures: 38, Errors: 544`**. Run alone immediately afterwards, the same tree gave
  **`5704 / 0 / 0 / 67 BUILD SUCCESS`**. A 544-error wall that is 100% artefact.

That is indistinguishable from a catastrophic regression, and the instinct on seeing it is to start
debugging the change — which is exactly the wasted motion this note exists to prevent.

**How to apply:** one `mvn` per worktree at a time. If something must run concurrently, give it its own
`git worktree add --detach`. Before trusting any red, check whether another maven was running: a log with
no `BUILD` line, or errors numbering in the hundreds across unrelated classes, is a collision until proven
otherwise. **Re-run alone before reporting any suite result.**

