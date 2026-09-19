---
name: cross-field-setter-silently-unpins-fixtures
description: A setter that mutates a DIFFERENT field can silently un-pin existing tests with no diff to them — assignment order becomes load-bearing and nothing announces it
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 885ee114-3071-4b9e-9b32-e55329684a43
  modified: 2026-09-08T16:14:39.924Z
---

**Measured 2026-09-08, SBDEV-3262.** Enforcing an invariant in `Pickingorder.setOperatorId(Long)` —
"passing null also clears `lockedtooperator`" — **silently un-pinned SBDEV-3205's own regression test**,
with **no diff to that test file** and while the full suite stayed green.

The fixture built the orphan-lock state in the order:
```java
testPickingOrder.setLockedtooperator(true);
testPickingOrder.setOperatorId(null);      // now ALSO clears the flag
```
so it stopped producing `locked=true, operator=NULL` and produced an ordinary unlocked order. The
guard under test then short-circuited on its FIRST conjunct, so deleting the second conjunct — the
entire fix that test exists to protect — no longer NPE'd and the test stayed **green against the
defect**.

**Why mutation testing did NOT catch it:** PIT scoped to the changed class (`Pickingorder`) killed
every mutant, because the new `PickingorderUnitTest` covers the setter directly. The mutant that
mattered lived in a DIFFERENT class (`MobilePickingService`'s guard). Scoping PIT to the class you
changed is still right, but it cannot see coverage you destroyed elsewhere.

**How to apply.** When adding a cross-field side effect to a setter:
1. Grep every construction of the affected field combination in `src/` — production AND fixtures — and
   check the assignment ORDER at each. Order silently becomes load-bearing and nothing announces it.
2. Add a **precondition assertion** to any fixture that builds the now-order-sensitive state, so a
   future reorder fails loudly instead of quietly producing a different object.
3. State the ordering rule in the setter's javadoc; it is invisible at the call site.

**Do not cite same-file precedent as equivalent without checking the KIND.** I justified this with
`Itemdata.setItemNr` (SBDEV-2496), which normalizes *the property it is setting* — idempotent and
invisible to other fields. A cross-field effect is a materially stronger surprise. "There is precedent
for a side-effecting setter here" was true and misleading at once.

Related: [[green-tests-that-prove-nothing]], [[un-suppressing-a-test-can-create-a-false-green]],
[[mutation-harness-traps]], [[a-guard-fences-the-mechanism-you-aimed-at]].
