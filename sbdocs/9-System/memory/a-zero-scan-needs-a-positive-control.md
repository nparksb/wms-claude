---
name: a-zero-scan-needs-a-positive-control
description: A scan whose expected answer is zero must include one probe with a known non-zero answer, or a broken instrument and a true zero look identical
metadata:
  type: feedback
---

**Any measurement whose expected answer is ZERO must carry a positive control** — one probe in the *same*
scan whose answer is already known to be non-zero. If the control does not come back, the zero means
nothing.

**Why:** a broken instrument and a true zero are indistinguishable, and the failure is silent in whichever
direction you were already expecting. Worse, the false zero often points at the *same conclusion* as the
true answer, so nothing downstream contradicts it.

**How to apply:** when a decision rests on "there are no X", pick something you know exists, measure it with
the identical command, and report both. On SBDEV-3156 the scan was for five method-security annotations
expected to be absent; `@PreAuthorize` (38 known uses) went into the same scan as the control, and it
returning 0 is what exposed [[grep-is-ugrep-skips-binary-without-dash-a]]. Without it, a wrong zero would
have shipped as the ticket's central evidence.

This is the same principle as the non-vacuity guards on this repo's ArchUnit rules, which assert on the set
**scanned** rather than the set **found** — see [[green-tests-that-prove-nothing]] and
[[never-audit-check-a-does-not-find-vacuity]]. Generalises to empty DB result sets and passing
pure-negative tests, not just grep.

Codified in `.claude/skills/wms-triage/SKILL.md` under Claim discipline, "Corollary 2".
