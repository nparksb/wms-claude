---
name: address-low-review-findings-too
description: "Nam 2026-08-26: fix Low/nit review findings too, not just High/Medium — and never hand a Low back as an open item, including when its remedy is a ticket note rather than code"
metadata:
  node_type: memory
  type: feedback
---

**Nam, 2026-08-26: "From now on, let's also address low ones too."**

Said after a T1 slice where an independent review returned 1 High / 3 Medium / 4 Low. Three of the
Lows were fixed in the same pass; the fourth's remedy was a **ClickUp note** rather than code, so it
fell out of the commit and got reported back as "still open" for him to chase.

**Why:** the repo's own `wms-plan-executor` severity table used to say Low = *"record in the final
report and the PR body; fix only if it is a one-liner in code you already touched."* That is what
produced the hand-back. Lows here are rarely cosmetic — the four on that slice were a wrong measured
count in a comment, a `.trim()` that would throw inside a computed and blank the whole dialog, a
duplicated assertion, and a deliberate behaviour no AC stated that QA would have filed as a defect.
Each was minutes of work and each would have cost someone else real time.

**How to apply:**
- Fix every Low in the same pass as the Highs and Mediums. A fresh Low does not force another review
  loop — fix it and move on.
- **A Low whose remedy is a note, not code, is not done until the note is posted.** Deliberate
  behaviour no AC states → a QA-facing line on the ticket. A stale citation → correct it in place.
- If a Low genuinely belongs elsewhere (its own ticket, or it disputes something the owner decided),
  **dispatch it and say where it went** — never leave it as an "open item" in the reply.
- Reporting a Low as outstanding is the failure mode, not the fix.

Applied to the tooling directly, per [[verify-script-traps]]
— the severity table in `.claude/skills/wms-plan-executor/SKILL.md` and the `wms-plan-executor` row in
`CLAUDE.md` were both edited so the rule survives this session. Related:
[[subagents-must-write-deliverable-to-a-file]], [[idle-review-subagent-is-not-a-passing-review]].
