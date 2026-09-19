---
name: wms-fix-effort-tiers-and-the-floor
description: Nam 2026-08-20 — the full plan/consensus/gate/execute path is the T3 path only; route on execution risk, scale artifacts, never scale the 5-item floor
metadata:
  type: feedback
---

**Nam, 2026-08-20: "Following wms-bugfix-plan and wms-plan-executor takes too much time, and you are generating more tickets than I can handle."** Both correct. A **tier router** is now at the top of `.claude/skills/wms-bugfix-plan/SKILL.md`, referenced from the other three plan/execute skills and summarised in the monorepo `CLAUDE.md`.

**Route on execution risk, NOT ClickUp priority** (that tracks business urgency, a different axis). Three questions: reversible? · fix predictable from the symptom? · how many files/repos?

- **T0** one-liner → no plan, 1 review, 15 min
- **T1** one file, obvious, reversible → 3 bullets on the ticket, 1 review, ~1 hr
- **T2** multi-file or a contract change → ≤200-line doc (a **cap**), one `architect` *consult* instead of ralplan, 2 lanes, ~½ day
- **T3** authz · data integrity · migration · multi-repo · irreversible → the full path

Features skew one tier higher than a bug fix of the same size. When in doubt go one tier **DOWN** — over-tiering is the failure mode; under-tiering self-corrects via the escalation triggers (DB query contradicts the ticket · fix needs an unanticipated repository/service method · a review disputes the *design*).

**Why:** measured on SBDEV-3011 — 1142-line plan + 483-line verify script + 10 subagent passes for **under 100 lines of real logic**, and the plan then generated its own churn (correcting over-specified counts and citations that were only wrong because they were stated). Meanwhile **every defect came from something cheap**: two SQL queries, mutation-testing, and one independent review. See [[sbdev-3011-delete-role-join-table-cascade]].

**How to apply — THE FLOOR NEVER SCALES**, at every tier including T0: one DB query confirming the symptom · one failing test first, failing for the *right* reason · **mutation-check every new assertion** · one independent review, never self-approve · full suite vs the KNOWN baseline. ~20 min total. A tier decides how much *documentation* you produce, never whether you do these. Related: [[negative-test-verify-scripts-before-trusting-them]], [[green-tests-that-prove-nothing]], [[idle-review-subagent-is-not-a-passing-review]].

**Ticket policy:** record in the plan by default. File only if distinct AND you would accept a standalone PR AND it is `high` or blocks work in flight. **Hard cap one new ticket per fix** — ask first beyond that. Prefer widening an existing ticket. Discovery already outruns implementation (43 plans in flight, 12 unimplemented on 2026-08-20), so an unactionable backlog is worse than a note because it looks tracked.
