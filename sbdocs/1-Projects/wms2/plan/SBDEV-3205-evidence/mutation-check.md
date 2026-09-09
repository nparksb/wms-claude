# SBDEV-3205 — hand-mutation of the native query (PIT cannot see SQL strings)

Run 2026-09-02 in .claude/worktrees/wms2-api/SBDEV-3205 @ origin/develop 951b854c + fix, after the review-lane fixes (ORPHAN_LOCKED row added; M7 added because the review found `operator_id IS NOT NULL` unpinned).
Each mutant: patch PickingorderRepository.java → mvn -o test -Dtest=ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest → restore.
Attributable = the red test NAMES the predicate mutated. All 7 killed; the exact-set pin also reds on every mutant.

Full unit suite in the same worktree (mvn -o clean test): 6173 run, 0 failures, 0 errors, 67 skipped — BUILD SUCCESS (surefire excludes *IntegrationTest; the new test runs via -Dtest or failsafe).

```
== BASELINE (fixed) ==
Tests run: 9, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 4.711 s -- in net.aim_ai.wms.integration.ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest

== M1_polarity_back_to_is_null ==
<         " AND po.operator_id IS NOT NULL " +
>         " AND po.operator_id is null " +
  RED: releaseSetIsExactlyTheHeldExpiredOrder <<< FAILURE!
  RED: heldExpiredOrderIsSelected <<< FAILURE!
  RED: orphanLockIsNotSelected <<< FAILURE!

== M2_drop_pickinginprogress_guard ==
<         " AND po.pickinginprogress = false " +
>         
  RED: releaseSetIsExactlyTheHeldExpiredOrder <<< FAILURE!
  RED: inProgressOrderIsNotSelected <<< FAILURE!

== M3_widen_section_type ==
<         " AND s.sectionpickingtype = :pickingType ", nativeQuery = true)
>         " AND (s.sectionpickingtype = :pickingType OR s.sectionpickingtype = 'TOTES_ON_CART') ", nativeQuery = true)
  RED: releaseSetIsExactlyTheHeldExpiredOrder <<< FAILURE!
  RED: totesOnCartOrderIsNotSelected <<< FAILURE!

== M4_ignore_timeout ==
<         " AND po.modified < :timeOut " +
>         " AND (po.modified < :timeOut OR TRUE) " +
  RED: releaseSetIsExactlyTheHeldExpiredOrder <<< FAILURE!
  RED: freshHoldIsNotSelected <<< FAILURE!

== M5_state_lte ==
<         " AND po.state < :state " +
>         " AND po.state <= :state " +
  RED: releaseSetIsExactlyTheHeldExpiredOrder <<< FAILURE!
  RED: pickedOrderIsNotSelected <<< FAILURE!

== M7_drop_operator_not_null ==
<         " AND po.operator_id IS NOT NULL " +
>         
  RED: releaseSetIsExactlyTheHeldExpiredOrder <<< FAILURE!
  RED: orphanLockIsNotSelected <<< FAILURE!

== M6_drop_lockedtooperator ==
<         " WHERE po.lockedtooperator = true " +
>         " WHERE TRUE " +
  RED: releaseSetIsExactlyTheHeldExpiredOrder <<< FAILURE!
  RED: reservedButNotLockedOrderIsNotSelected <<< FAILURE!

== RESTORED? ==
repo file restored to fixed version

== FINAL GREEN CHECK ==
Tests run: 9, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 4.697 s -- in net.aim_ai.wms.integration.ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest
```
