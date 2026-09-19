---
name: prose-enumerations-rot-state-the-rule
description: On SBDEV-3250 I stated a population by enumerating it in prose four times and was short every time — the fix is to derive the set mechanically and state the rule, not the list
metadata:
  type: feedback
---

**Measured on one ticket, four times in a row.** Every time I described a population by listing it in
a comment, the list was incomplete — and the incompleteness survived my own review, two peer audits
and a code-review lane before something caught it:

1. The ADR said the lock hint bounded the wait. It bounded nothing.
2. "Six `repo.jpa` methods escape the bound" — they don't; the mechanism was never run.
3. "Two multi-row lock sites" / "13 of the 15" — arithmetically impossible; the real figures are
   11 single-row + 4 multi-row + 2 native + ~31 bulk `@Modifying`.
4. The doc sweep was file-complete but not assertion-complete: one banner per file left a literal
   config recipe 400 lines downstream.

**Why:** *"and there are two of them"* is a completeness claim, and completeness claims require
proving a negative. Counting is cheap and checkable; closing a set is not. This is
[[advertised-capability-is-not-exploitable-capability]] and
[[a-guard-fences-the-mechanism-you-aimed-at]] applied to documentation.

**How to apply:**
- **Derive the set with a script, print it, and paste the derivation** — never write a count from
  memory or from a reviewer's message. A ten-line Python classifier over the sources caught all four.
- **State the RULE where the reader is, and the LIST only where it is checkable.** "The bound is per
  lock acquisition, so anything matching N rows waits up to N × it" cannot rot. "There are two such
  sites" rots the moment someone adds a third.
- **When a list must exist, make it a rail** — an explicitly pinned set that fails when it changes,
  the way `TestClassTransactionManagerArchTest`'s `EXEMPT_NON_TRANSACTIONAL` does. A prose list is
  documentation; a pinned set is a test.
- **For a document sweep, put the withdrawal at the TOP of the file.** Assertion-completeness by
  construction beats hunting occurrences.
- **A peer's enumeration is a hypothesis.** Two of the four errors above came from trusting a review
  lane's list; one lane also corrected its own requester's count. Re-derive before acting.

Related: [[green-tests-that-prove-nothing]], [[a-zero-scan-needs-a-positive-control]],
[[wms2-lock-timeouts-are-inert-on-postgres]].
