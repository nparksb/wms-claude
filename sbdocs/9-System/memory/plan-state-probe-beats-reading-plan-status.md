---
name: plan-state-probe-beats-reading-plan-status
description: "Never answer \"what's the status of plan X\" from its status frontmatter — run sbdocs/9-System/scripts/plan-state.sh TICKET"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8697cde7-bbc9-40aa-8186-f1423187edab
  modified: 2026-08-21T00:39:56.193Z
---

To answer "what's the state of plan X", run **`sbdocs/9-System/scripts/plan-state.sh <TICKET>`**
(`--fetch` for live base staleness, `--tests` to run the suites). Added 2026-08-20.

**Why:** a plan's `status:` frontmatter is hand-written prose that nothing validates. SBDEV-2968's was
6,775 characters and said "implementation NOT started, working trees are now EMPTY" while both worktrees
held 46 dirty paths carrying the finished implementation — the field was written at 12:19 and was wrong by
12:22. Reconstructing the truth by hand cost about an hour, and every fact in that hour was derivable.

**How to apply:** run the probe first, then read the plan body for *decisions*, never for state. The six
sources each lie in their own direction and the probe prints them side by side: frontmatter (stale prose) ·
git (says "nothing happened" while work is uncommitted) · verify on the mono root (grades the main
checkouts, which sit on other branches) · verify on the shadow root (rows go stale or pre-pass) · suites
(green is meaningless without the known-failure baseline and a mutation check) · ClickUp (one status spans
"plan written" through "code done, uncommitted").

Two traps it encodes, both producing credible-looking reds: the split `PROJECT_ROOT` convention
([[verify-script-traps]]) and mvn-off-PATH phantom failures. It also names
which root is **authoritative** — for a merged plan the worktree is a stale snapshot and its low score is
not evidence, which inverts the usual "shadow is the truth" rule.

Validation: it independently reproduced SBDEV-3011's recorded `54 pass, 0 fail, 1 skip`.

If work is sitting uncommitted, commit it before anything else — uncommitted work is invisible to git, CI
and review, and one `git checkout` from gone. Related: [[feedback_plan_status_after_implementation]].
