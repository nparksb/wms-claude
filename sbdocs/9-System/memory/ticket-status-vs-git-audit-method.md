---
name: ticket-status-vs-git-audit-method
description: How to audit ClickUp status against git without the two traps — a free-text grep matches other tickets' commit bodies, and a merge existing does not mean the ticket's scope shipped
metadata:
  type: feedback
---

Auditing whether a ticket's status matches git. Two traps, both hit on 2026-09-02:

**1. `git log --grep=SBDEV-XXXX` over commit BODIES produces false positives.** Tickets cite each other, so
SBDEV-3183 "matched" a SBDEV-3156 commit that merely mentioned it. Match the **merge commit's branch name**
(`--merges` + `from SiteBossInc/<type>/SBDEV-XXXX`) as the primary signal.

**⚠ But some branches carry NO ticket ID.** SBDEV-3186 merged as PR #266 from
`chore/wms2-mobile-misattributed-loggers` — a branch-name match finds nothing and the ticket reads as
unmerged. **Use both instruments**: branch name AND body, and reconcile the disagreement rather than
trusting either.

**2. A merge existing does NOT mean the ticket's scope shipped.** SBDEV-3183 had 5 merged commits and looked
done; it closed **2 of 9 ACs** (AC-3, AC-6 — its commit says so). AC-2 and AC-5 were untouched, and AC-5 is
the one that matters: every tenant is still `OFF`, so the rules enforce nothing. Moving it to `on dev` would
have asserted "the gate is live" when it is not — and that ticket exists **because** SBDEV-3169 sat at
`on qa` with 8 unticked ACs.

**The method:** for each candidate, (a) confirm the merge two ways, (b) read the ACs, (c) verify a sample of
them against `origin/develop` rather than the PR description, (d) move the status **and** tick/strike the ACs
in the same action. If most ACs are unmet, the answer is a comment recording what shipped — not a status
move.

**Deployment rung needs tags, not branches.** SBDEV-3174 is on `main` and in `v0.0.22`, but prd runs
`v0.0.21` — so it is past `on dev` and not `on prod`. Check membership in the tag the environment is
actually running (`/api/public/version`), not just in `main`. Which rung that maps to is a process judgment
— flag it, do not infer it. See [[wms2-deployed-image-differs-from-branch-head]].

Related: [[consolidate-tickets-dont-file-one-per-finding]] (the ladder IS the tracker),
[[plan-state-probe-beats-reading-plan-status]] (the same "derive, don't read the label" principle for plans).
