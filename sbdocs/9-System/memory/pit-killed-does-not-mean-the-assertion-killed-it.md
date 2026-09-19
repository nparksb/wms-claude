---
name: pit-killed-does-not-mean-the-assertion-killed-it
description: PIT reports KILLED when an unstubbed mock throws mid-method — the assertion never ran; check the failure message names the mutant
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 9852c2e4-0668-4f20-ba3b-56ab5830f9fa
  modified: 2026-09-15T14:26:11.581Z
---

**PIT's `KILLED` only proves the test went red, not that your assertion did it.** A mutant that makes
execution reach an unstubbed mock gets killed by the resulting `EntityNotFoundException` /
`Optional.empty().orElseThrow()` / NPE — and every `verify(..., never())` after that point is never
evaluated. PIT cannot tell the difference; it reports a clean `KILLED`.

Measured on SBDEV-3332 (2026-09-15). PIT reported all four mutants on a new guard in
`PickingorderBusinessService.cleanUpCancelledOrder` as KILLED. Hand-applying the mutant showed the
kill was `EntityNotFound CustomerOrderBatch not found with id: null` — the fixture had
`orderbatchId = null` and no stubs, so with the guard removed the test died before a single
`never()` ran. Two of three `never()`s were vacuous and the third never executed. An independent
review lane derived the same defect from the source.

**Why:** this is the same trap as [[green-tests-that-prove-nothing]] and
[[never-audit-check-a-does-not-find-vacuity]], but it defeats the tool that is supposed to catch
them — so the usual "I ran PIT" is not a defence.

**How to apply:**
- After PIT says KILLED on a mutant you care about, **hand-apply it once and read the failure
  message**. It must name the thing you broke, per the attributable-kill rule in `wms-triage`.
- A `never()`-heavy test needs its trap **armed**: stub enough that the mutant path runs to
  completion. In `PickingorderBusinessServiceUnitTest` the documented convention is `lenient()`
  stubs, and its class javadoc says so explicitly ("in a NEGATIVE test a dead stub is often
  load-bearing because it is dead: it arms the trap").
- **Order the assertions so the strongest reports first.** With `verify(repo).save(x)` before the
  `never()`s, the kill arrived as `TooManyActualInvocations` on the save and JUnit stopped there —
  attributable, but it left the `never()`s unproven. Moving them first made the kill
  `NeverWantedButInvoked: cancellationLogService.recordCancellation(...)`.
- Related: [[mutation-harness-traps]] (use PIT, not a script) is still right — this narrows it, it
  does not reverse it.
