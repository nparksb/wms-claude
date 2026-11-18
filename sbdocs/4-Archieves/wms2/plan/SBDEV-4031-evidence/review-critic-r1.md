---
lane: critic (ralplan round 1, independent of the architect)
snapshot: plan-snapshot-r1.md sha1 00f40453
verified_against: origin/develop d6424491 (05f962b3..d6424491 changes only SecurityConfiguration)
verdict: ITERATE
saved_by: main session, verbatim summary of the lane's reply (critic agents cannot write files)
---
# Critic review, round 1: ITERATE

High: F1. Medium: F2–F7. Low/Low-Med: F8–F15.

- F1 HIGH. The park points in AC-2, AC-6 and AC-11 run only after the fix, so the pre-fix red is a latch timeout or a compile error. Fix: park on existing repo calls that run on both code paths:
  - AC-2: `unitloadRepository.findById` in `checkRemovable`;
  - AC-6: `stockunitRepository.findByUnitloadId` in `refillSingleFixedLocation`;
  - AC-11: `unitloadRepository.findByStoragelocationId` in `move`.
  State each AC's pre-fix red message.
- F2. AC-5 cannot be red before the fix (no FLA lock exists, so there is no cycle). Make it a regression guard proven only by its mutation, and drop it from step 2's red list.
- F3. AC-9 passes before the fix: `deleteById` blocks on the held row and gives the same 55P03/409. Assert the block happens at the `FOR UPDATE` statement (`BlockedBackendReads.confirmedBlockedStatement`), or seed a UL/SU so the pre-fix run writes something. Mark `FixLocationAssignmentControllerIT` and `FixLocationAssignmentMoveIT` as NEW.
- F4. In AC-3, B also hits the spy on `findByStateLessThanAndItemdataId` (via `getActive`), so both threads park; scope the spy to thread A. In AC-1 and AC-11, the first assertion to fail pre-fix is "blocked by A's pid", so either soft-assert that or align the mutation column with it.
- F5. The list of unit tests expected to change is far too short. The new finders return Mockito's default `Optional.empty()`.
  - Affected: `FixLocationAssignmentServiceUnitTest` (59 `findById` + 15 `getActive` stubs), `ReplenishGeneratorServiceUnitTest` (13–15 automatic/refill tests), `ReplenishmentOrderMaintenanceServiceUnitTest` (6 ctx stubs), `FixLocationAssignmentUserDeleteContractUnitTest`, `FixLocationAssignmentServiceIT`, `ManualCutCooldownEndToEndIT`, `DeleteContainerWithStockIT`.
  - Add a rule: re-stub the new finders; never weaken an assertion.
- F6. R3's job catch (`ReplenishOrderJob:907-911`) is optimistic-only. A 3 s pessimistic timeout rolls back every assignment in the R3 run and reaches the per-tenant catch. Add `PessimisticLockingFailureException`, or run each R3 order in its own short tx through a self-proxy (the `recalculateOpenOrders` pattern).
- F7. The v2-constraint table (8 rows) and the completeness checklist (11 rows) must use the skill's rows, each with a verdict and a citation. §8.4 needs the Environment and Pass/Fail columns.
- F8. It is unclear whether `ReplenishorderRepository` gets 2 or 3 new finders. That repo is exported: pin `exported=false` on the new methods.
- F9. The ABBA-5 pin covers only direct call sites. Use `accessTargetWhere` (it covers method references), and pin that `fulfillMultipleUnitLoads` has no `@Transactional`. Otherwise confirm → `recalculateForItem` could lock F inside the confirm tx.
- F10. AC-10b's mutation needs open orders to both L and L′.
- F11. Name Spring Data REST PUT/PATCH on the exported `ReplenishorderRepository` as a blind spot in the "destination never goes back to null" premise.
- F12. Restate the advisory-lock rejection: `pg_blocking_pids` does see advisory waits. The real reasons are the keyspace shared with job locks and the need for an xact-scoped lock in every path.
- F13. Schedule F2 (`refillFixedLocations` dead code + stale javadoc) and F5 (lock_timeout doc fix) in §6.2, or mark them deferred. Add one line on P52's `changeActive` half.
- F14. Add the user-visible `move` changes to §9 and the ADR: the new refusal (HTTP 200 + error map), re-pointing in-flight orders, ≤3 s wait / 409.
- F15. Update `base_commit` to d6424491. `recalculateForItem` has three callers (`ReplenishOrderJob:513`, `ReplenishmentMaintenanceTrigger:187`, `MobileReplenishService:930`), not four.

**Ambiguities**
- Pin where Fix D's outer `lockIdByItemdataId` sits relative to `buildRecalcContext`; AC-4's narrative depends on it.
- Fix E drops today's `locationRepository.findById` existence check. Say so.

**Cuts**
- Keep the DEV counts only in §8.4.
- Drop the "7 sites" and "four callers" counts; cite the grep instead.
- The ADR's Alternatives bullet should reference the §5 table.
- Delete the OMC composition table.
- Collapse §4.2 to verdicts.
- Remove the stale archunit store line numbers.

**Open questions**
- Does wms2-web-ui handle a 409 from the fixedAssignment delete and move endpoints?
- `resolveUpperBound` can read a deleted FLA's bounds during the window. Does any decision depend on them?
- How many PRD open orders have a null destination? The analysis found 21, none of them for an item with an FLA.
