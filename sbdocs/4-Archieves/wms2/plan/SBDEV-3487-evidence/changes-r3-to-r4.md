## Changes from r3

1. **§5.8 STOP rule inverted (Architect M1 + L1, Critic Finding 1).** A red now counts as a disproof of §2 only if three things hold: the pre-fix throwable comes from a guard whose condition is met by closeBOL's output (source on Shipped, `entity_lock` 405, or positions CLOSED); the positions are intact; and the executor quotes the guard's condition. Everything else is a fixture or environment problem and says nothing about §2. That covers every destination-side guard, resolution failures, `DataAccessException`, NPE / EntityNotFound, setup and teardown failures, and a pre-fix `t == null` with positions intact. A third bucket covers anything else: STOP, report the throwable, conclude nothing. AC-10 uses the same rule.
2. **DEST preconditions added to §6.1**, using the real V2.2.00 names:
   - `location.entity_lock = 0` and `location.type_id = 1`
   - 0 rows in `location_constraint` where `storagelocationtype_id = 1`
   - 0 rows in `fix_location_assignment` where `assignedlocation_id = DEST`
3. **AC-10b probe runs inside the `tx()` lambda.** The lambda loads the pallet with `findById`, calls the transfer, runs `catchThrowable` on the NOWAIT query, then calls `setRollbackOnly()`. Outside the lambda, the test asserts that the most specific cause is an `SQLException` with SQLState `55P03`. The positive control uses the same shape without the transfer and asserts exactly the pallet id.
4. **§5.5:** added "V2 passes `MOVE_UNITLOAD_D0_RECHECK`" to the re-check snippet.
5. **§6.1:** "set the state with jdbc inside `tx()`" is now "via `jdbcTemplate` (autocommits, its own DataSource)", with a note that the preconditions catch a partial write.
6. **AC-9:** dropped "explicit id" (sequence-generated id plus `@Version`). `name = PREFIX + …` stays.
7. **AC-3 IT** now uses `BOUT-948703` and **AC-7** uses `BOUT-948704`. Both are added to `MobileTruckLoadingClosedBolPurgeIT`'s purge list. `git grep 9487 src/test` finds only 948701/948702, so neither label collides with those or with the planned 948710–948713.
8. **`closeBolAsShipped`** moves up to `AbstractTruckLoadingPgFixture` as `protected`. §5.7 has a new row for it.
9. **§6.2 scenario 1** also snapshots the `unitload` rows of the pallet and its children. **Scenario 3** runs only after scenario 1 has shown the fix is live.
10. **§6.2:** the `MoveUnitloadController` citation is now `:67-90`.

