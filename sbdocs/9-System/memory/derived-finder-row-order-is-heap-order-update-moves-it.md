---
name: derived-finder-row-order-is-heap-order-update-moves-it
description: "A derived finder with no ORDER BY returns rows in heap order, and a fixture UPDATE moves the updated row to the end — flips loop order in ITs"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 8ba50089-49fb-4127-9271-10ab67b75ecb
  modified: 2026-10-11T23:20:16.074Z
---

Spring Data derived finders (e.g. `PickingorderPositionRepository.findByCustomerorderpositionId`) declare no `ORDER BY`, so PostgreSQL returns rows in heap (TID) order. A fixture `UPDATE` writes a new tuple version at the end of the heap, so updating row A after inserting B puts A AFTER B.

On SBDEV-3729 this silently disarmed a re-aimed race IT. `canOrderPositionBeCancelled` returns at the first PACKED line, so the order of the lines decided whether the raced picking order was ever read plain. The test passed under a mutant until the updates were reordered.

**Why:** the test still went green; only a mutation run showed it no longer exercised the hazard.

**How to apply:** when an IT depends on the order a loop sees rows from an unordered finder, (1) issue the fixture UPDATEs in the order you want the rows read back, and (2) add a precondition that runs the finder's own unordered SQL and asserts that order (`containsExactly`), labelled as a fixture check, not a regression. Related: [[a-test-can-pass-for-the-wrong-reason-vary-the-fixture]], [[green-tests-that-prove-nothing]].
