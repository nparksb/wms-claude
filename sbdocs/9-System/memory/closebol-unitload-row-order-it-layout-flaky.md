---
name: closebol-unitload-row-order-it-layout-flaky
description: ClosebolUnitloadRowOrderIT can error on its ctid layout precondition in CI (heap free-space reuse); rerun the failed job first
metadata:
  node_type: memory
  type: reference
  originSessionId: 73044a3b-94bc-4eac-81f7-0e33353ba62c
  modified: 2026-11-03T12:44:48.953Z
---

`ClosebolUnitloadRowOrderIT.closeBOL_shouldLockChildrenInIdOrder_whenBlockedOnTheLowerParcel` (SBDEV-3440) seeds two parcels and
**checks, never repairs** that the second is stored physically after the first (`assertStoredAfter`, compares `unitload` ctids).
On 2026-10-29, CI run 40860958584 (wms2-api PR #584, SBDEV-3947, head e8aebe8f) failed with
`IllegalState fixture precondition: unitload 2587 (ctid (0,57)) is not stored after unitload 2591 (ctid (1,55))`:
the later row landed in free space on page 0 left by earlier tests' deletes. The PR wrote no `unitload` rows; the same
merge passed locally (1101 IT / 0), develop's own run passed, and `gh run rerun --failed` went green.

**Second occurrence 2026-11-03:** CI run 41634554343 (PR #612, SBDEV-4000, head cb49c295), `unitload 2693 (ctid (0,38)) is
not stored after unitload 2697 (ctid (0,55))`; the PR wrote no `unitload` rows and its local full verify on the same merge
was green. Twice in a week is a pattern: a fixture that forces the layout (e.g. VACUUM FULL / a fresh table before seeding,
or seeding into an empty heap) would retire it — candidate proposal, not filed.

**How to apply:** an ERROR (not a FAILURE) from this IT whose message is the ctid precondition is layout luck, not a
regression — rerun the failed job before investigating. A FAILURE on the lock-order assertion itself is real.
Related: [[hub-flaky-its]], [[hub-it-shared-state-crosstalk]].
