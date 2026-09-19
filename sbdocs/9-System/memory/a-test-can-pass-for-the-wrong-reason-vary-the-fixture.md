---
name: a-test-can-pass-for-the-wrong-reason-vary-the-fixture
description: A guard-clause test whose fixture leaves a second reason for the same outcome passes with the guard deleted; the fixture must make the guard the ONLY thing producing the result
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 747961e4-09fa-4a57-8b4a-65c25e6617aa
  modified: 2026-09-15T14:01:08.777Z
---

Measured on SBDEV-3323 (`wms2-mobile-ui`, 2026-09-15). A test pinned *"do not navigate away when the
post-loop re-read fails"* — the guard being `if (!refreshed) return` before a
`SET_PROCESS(sourceFlow)` navigate.

The fixture used a **two-position** order and completed one. So the floor-committed state still held
a pending sibling, `stillPending` was true, and the navigate did not fire **whether or not the guard
existed**. The test passed, and deleting `if (!refreshed) return` survived a mutation sweep.

It needs a **single-position** order: then the floor commit says nothing is pending, and the guard is
the only thing between a failed re-read and navigating on unconfirmed state. With that fixture the
mutant dies.

**Why:** the assertion was on an *outcome* (`process === '2_action'`) that the fixture could reach by
two independent routes. Mutation-checking finds this and nothing else does — the test looks correct,
reads correctly, and is about the right behaviour.

**How to apply:** for any test of a guard/early-return, ask *"what else in this fixture produces the
same outcome?"* and remove it. Prefer the smallest fixture that still exercises the path — extra rows,
extra positions and extra collaborators are each another way for the assertion to be satisfied for
the wrong reason. Then mutation-check the guard specifically; a sweep that only mutates the *happy
path* never touches these.

Same session, same shape at the harness level: the sweep script itself never asserted its baseline was
green and counted any red as a kill — see [[mutation-harness-traps]] for that half.

Related: [[green-tests-that-prove-nothing]], [[un-suppressing-a-test-can-create-a-false-green]],
[[vue-mount-with-value-present-does-not-test-reactivity]],
[[mutation-fixture-needs-a-row-in-the-dominant-value-band]].
