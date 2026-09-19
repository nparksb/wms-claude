---
name: v1-is-reference-only-v2-is-the-only-target
description: As of 2026-08-20 no more v1 fixes — v1/* is read-only reference; all fix and feature work targets v2 only
metadata: 
  node_type: memory
  type: project
  originSessionId: 4c28a059-d7ee-4f6d-b720-9e64c9c85a7e
  modified: 2026-08-20T12:57:17.825Z
---

As of **2026-08-20**, Nam Park's direction: **v2 is the default and only target for volunteered work**
(`v2/wms2-api`, `v2/wms2-web-ui`, `v2/wms2-mobile-ui`, `v2/oms-laravel-api`, `v2/omsv2-UI`).
**v1 work happens ONLY when Nam explicitly asks for it** — it is not forbidden, it is
never *self-initiated*. Absent an explicit request, `v1/wms-api`, `v1/wms-web-ui`, `v1/wms-mobile-ui`
and `v1/oms` are **read-only reference**: consult them for how a behaviour used to work or to recover
detail v2 lacks.

When Nam does ask for v1 work, do it normally — full plan/TDD/verify treatment, no hedging about the
policy. The rule governs what I *propose*, not what I am *capable* of being asked.

**Why:** stated as a scope decision, not derived from the code. Nothing in the repo signals it — the v1
repos are live, `sbdocs/1-Projects/wms1/plan/` holds active plans, and `.claude/skills/` still ships
`wms-v1-sync-sweep`, so the filesystem reads as if v1 work were ongoing.

**How to apply:**
- Never open v1 plans, worktrees, or PRs on my own initiative, and never propose a v1 half of a fix
  "for parity" or offer it as a next step.
- When a defect exists in both versions, fix v2 and **state as a fact** that v1 still carries it —
  that is reporting, not a proposal. Do not attach an offer to fix it.
- If Nam asks for v1 work, that request overrides everything above for that task.
- Reading v1 is still encouraged where it's cheaper than re-deriving: v1 often holds the original
  intent behind a v2 behaviour. Cite it as evidence, not as a change target.
- **The weekly `wms-v1-sync-sweep` STILL RUNS** (confirmed by Nam Park 2026-08-20). It is not an
  exception to the rule — it *is* v2 work: others (Arden) keep committing to v1, and the sweep ports
  those commits forward into v2. Reads v1 git history, writes only to v2 repos (plus `sync-log.md`
  under `sbdocs/2-Areas/wms-v1-v2-sync/`). So "don't fix v1" and "run the sweep" coexist: the sweep
  never lands a commit *on* v1.
- v1-specific memories stay valid as reference, e.g. [[run-v1-wms-api-testcontainers-its-locally]],
  [[v1-its-blocked-roid-view-drift]], [[wms1-web-palletize-check-gap-double-ship]],
  [[lane-a-git-cherry-false-positives]] — treat their "how to fix" halves as historical.
