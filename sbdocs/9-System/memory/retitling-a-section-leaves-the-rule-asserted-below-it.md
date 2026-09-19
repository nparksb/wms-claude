---
name: retitling-a-section-leaves-the-rule-asserted-below-it
description: Changing a doc/skill section HEADING leaves the old rule asserted in paragraphs below it — grep the rule, never edit by section
metadata:
  type: feedback
---

2026-08-22, extracting the tier router into the `wms-triage` skill. I rewrote the heading
`## Verification script (MANDATORY companion to every plan)` → `## Verification script — T3 OPT-IN
ONLY` and considered the rule changed. An independent review lane found the same section, 30 lines
lower, still saying *"a verify script is required at **T2**"*, *"a T2/T3 plan delivered without one is
not review-ready"*, and — in the post-implementation gate — *"Run the verify script first AND last"*
unqualified. Three more files asserted the old rule too: `wms-feature-plan` kept the whole MANDATORY
section verbatim, `wms-plan-executor`'s preflight said *"Author it, then continue"* (so executing a
correct T2 plan would manufacture the artifact the router abolished), and
`sbdocs/9-System/templates/wms-plan-template.md` re-instantiated it into every new plan.

**Why:** a rule is asserted in the imperative sentences, not in the heading. The heading is what I
search for when editing and the sentences are what an agent obeys — and of the two, the gate-phrased
sentence ("not review-ready") wins every time.

**How to apply:** when changing a rule, grep for the RULE's vocabulary across every file
(`MANDATORY`, `required at`, `must`, `not review-ready`, `always`, `mandatory for ALL`), not for the
section that owns it. Then re-grep after editing and read each hit. Templates and
`plan-state.sh`-style probes count: they outlive the skill edit because plans are instantiated from
them. Related: [[verify-script-traps]],
[[wms-fix-effort-tiers-and-the-floor]].
