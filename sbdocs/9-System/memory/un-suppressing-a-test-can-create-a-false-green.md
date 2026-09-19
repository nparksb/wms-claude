---
name: un-suppressing-a-test-can-create-a-false-green
description: Re-enabling a @Disabled test can be worse than leaving it disabled — a negative assertion on a fixture that was never written passes unconditionally
metadata:
  type: feedback
---

**Before deleting a `@Disabled` marker, ask which way the missing precondition points.** A test parked
because its fixture was never built does not simply "fail until someone writes the fixture" — it fails
only if its assertion is *positive*. A negative one passes, forever, asserting nothing.

Measured on SBDEV-3241 (2026-09-06). `CustomerorderBatchRepositoryTest` has two tests over the same
query, both carrying `TODO(SBDEV-2164): seed data via JPA` that nobody ever wrote:

- **A9** asserts `.isNotEmpty()` → empty table → **red**. Honest.
- **A10** asserts `.isEmpty()` → empty table → **green**. It would also pass for an inverted predicate,
  or for a query that had been deleted outright.

I removed the class-level marker, disabled A9 on its visible failure, and shipped A10 as live coverage.
A review lane caught it: *"the change diagnosed this exact cause four lines above."* Before the change
A10 was skipped and honest; after it, it was a passing row a reader would count.

**Why:** a skip is legible as "no coverage here". A vacuous green is indistinguishable from real
coverage, and it is what the suite total, the CI badge and the next reader all believe.

**How to apply:** when un-suppressing, run the test AND read its assertion against the state the fixture
actually leaves. Any `isEmpty` / `assertNull` / `hasSize(0)` / `verify(..., never())` on a precondition
that was never set up is presumed vacuous until proven otherwise — the green tells you nothing. Same
family as [[green-tests-that-prove-nothing]] and [[a-zero-scan-needs-a-positive-control]]: a passing
negative assertion and a broken instrument look identical. Related: [[never-audit-check-a-does-not-find-vacuity]].
