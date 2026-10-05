---
name: check-peer-sessions-before-resuming-a-ticket
description: "Before resuming a ticket's worktree, run ListAgents — a peer Claude session may be actively editing the same worktree"
metadata:
  node_type: memory
  type: feedback
  originSessionId: f501d850-bf8a-4f3d-8ac4-c8fbbf6d77ff
  modified: 2026-09-30T00:18:34.064Z
---

On 2026-09-30 "start 3561" was resumed in session owl-a7 while peer session owl-34 was still actively working SBDEV-3561 in the same `.claude/worktrees/*/SBDEV-3561` worktrees. The two sessions ran concurrent Maven in one worktree. owl-a7's `git checkout -- <file>` also discarded owl-34's uncommitted edit: the script ran the checkout even though its own grep had just shown the diff was no longer owl-a7's.

**Why:** a background Maven or Jest run started before `/clear` keeps running, and it looks exactly like a peer's run. An in-flight log, or a spec file that "changed on disk", is the signal that someone else is writing. Same failure class as [[review-lanes-must-not-share-a-worktree]] and [[concurrent-maven-one-worktree-false-reds]].

**How to apply:**
- Before the first write or Maven/Jest run in a resumed ticket worktree, call `ListAgents`. If a peer is busy, ask it or the user who owns the ticket.
- Never `git checkout`/restore a file on an assumption about whose change it holds. Read the diff first, and make the restore conditional on that check, not just preceded by it.
