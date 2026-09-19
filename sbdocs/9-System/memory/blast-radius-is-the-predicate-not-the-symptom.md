---
name: blast-radius-is-the-predicate-not-the-symptom
description: "Census the condition you are changing, not the symptom that led you there — a symptom-shaped filter under-reports the affected population"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 0a3c8a18-078e-4915-af56-c67bd7a21d3d
  modified: 2026-09-15T16:51:00.516Z
---

When measuring what a guard/predicate change will affect, filter on **the condition the predicate
actually tests**, never on the symptom that brought you to it.

Measured on SBDEV-3363 (2026-09-15). The ticket is about `markedforcancellation`, so my census filtered
`WHERE co.markedforcancellation IS TRUE` and found the 2 stranded orders the ticket names. A tracer lane
filtered on the *structural* condition the guard tests — `co.state <> 800 AND EXISTS (a customerorder_position
at 800)` — and found **a third affected order carrying no flag at all** (`585000351`, `pickingconfirmationsent
= true`). That order takes a *different arm that works today*, and the proposed fix would have rerouted it
onto a throwing path. A fix graded only on the flagged pair would not have noticed.

**Why:** a guard admits an input *class*. The symptom is one member of it. Filtering by the symptom measures
the members you already knew about and silently drops the ones reachable by another route — which are exactly
the regressions, because they are the ones that work today.

**How to apply:** before changing a predicate, write the census query *from the predicate's own terms*. If the
ticket's framing and the predicate's terms differ, run both and reconcile — the difference is the finding.
Same family as [[ac2-role-count-is-not-the-unit-user-population-is]] and
[[a-guard-fences-the-mechanism-you-aimed-at]].
