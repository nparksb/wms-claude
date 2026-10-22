---
name: wms2-ungated-handler-check-tranche-map-first
description: "Before gating an \"ungated\" wms2 handler, grep Sbdev3017TrancheGateContextTest's intended-gate map — deliberate carve-outs are recorded there, not above the handler"
metadata:
  node_type: memory
  type: project
  originSessionId: c5c15c81-1480-4a5c-994f-8e6a30eaa25c
  modified: 2026-10-11T01:16:21.134Z
---

An unannotated wms2-api handler is not necessarily undecided. Deliberate carve-outs are recorded in
`src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java`, in its intended-gate map
(rows of the form `row("Class", "/v3/...")` with an empty expected set) and the comments next to them.
There is often no comment above the handler itself.

**Why:** SBDEV-3243 was filed on the premise that "nothing in the code records a decision" to leave
`AdminActionController.triggerUpdateStock` open. In fact the tranche test records it as deliberate
(Nam, 2026-09-02): its `/rest/stockcount/triggerStockCount` twin is `permitAll()`, and the ungated row
is what detects a class-level `@RequiresFunction`. A gating attempt went red there in the full suite.
The ticket was closed 2026-10-10 as superseded by SBDEV-3124.

**How to apply:** at triage, before treating any ungated handler as a defect:
- `git grep` the route in that test on origin/develop.
- Check whether the same service has a `/rest/**` twin (that surface is permitAll; see [[wms2-rest-surface-internal-only-jwt-deferred]]).

Related: [[wms2-function-gate-anti-drift-only-covers-guarded-classes]], [[gate-tests-need-ungated-rows-and-full-varargs]].
