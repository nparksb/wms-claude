---
title: "SBDEV-3487 architect confirmation r4"
snapshot_sha1: 0d55a640cf3211686df389fea3cd01793eb01ce7
verdict: SOUND
note: "L-new and nit applied by the coordinator as snapshot r4b (60989a1f), 3-line wording diff"
---

## Verdict: SOUND

The r4 text resolves M1, M2, L1, L2 and the nit correctly. I checked the snapshot's sha1 and it matches `0d55a640cf3211686df389fea3cd01793eb01ce7`. None of the ten edits adds a defect that would misclassify a red or break the design. I found one new Low and one nit, both about wording. They are optional.

## Status per item

| Item | Status |
|---|---|
| **M1** (destination-side guards counted as a disproof) | **Resolved.** Bucket (1) now requires a guard whose condition reads the source's `storagelocation_id` = Shipped, the source's `entity_lock` = 405, or CLOSED positions, and the executor must quote the guard's condition. Every destination guard in `UnitloadBusinessService.java:250-313` reads DEST state, so none can reach bucket (1). They are listed in bucket (2). |
| **L1** (throwables that fit neither bucket) | **Resolved.** Bucket (3) catches everything else and concludes nothing. Two throwables are not named in bucket (2) and fall to (3): `"No unit load found for"` (`MobileMoveUnitloadService.java:304`) and the source-Damaged permission check (`:333`). Falling to (3) is the safe direction. |
| **§5.8 misrouting check** | **Clean.** Bucket (1) is checked first, so a real disproof of any exception type is captured before bucket (2)'s catch-all for `DataAccessException` or NPE. The one risky bucket-(2) entry is "pre-fix `t == null` with positions intact", because a silent shipped-skip would look the same. Current code has no such path: `scanDestination` has no silent return (`:288-378`), and R1/R2 do not filter on state (`BillofladingPositionRepository.java:88-107`). A fixture defect cannot reach bucket (1) either, because the pallet preconditions must pass before the service runs. |
| **DEST precondition SQL** | **Correct against V2.2.00.** `location.entity_lock` and `location.type_id` exist (`:959-979`). `location_constraint.storagelocationtype_id` exists (`:1273-1283`). `fix_location_assignment.assignedlocation_id` exists (`:906-919`). The later migrations do not change these columns. The three queries match what the code actually checks: `NOT_LOCKED = 0` (`WmsConstants.java:1556`), `findByAssignedlocationId`, and `findByStoragelocationtypeId(dest.typeId)`. |
| **M2 / AC-10b** (probe must run inside the lambda) | **Resolved.** The lambda now loads the pallet, calls the transfer, runs `catchThrowable` on the NOWAIT query, then calls `setRollbackOnly()`. The SQLState `55P03` is asserted outside. If the probe comes back null, the outside assertion fails cleanly rather than with an NPE. The positive control uses the same in-lambda shape. |
| **L2** (§5.5 re-check snippet) | **Resolved.** "V2 passes `MOVE_UNITLOAD_D0_RECHECK`" is at plan line 227. |
| **Nit** ("jdbc inside `tx()`") | **Resolved.** §6.1 and the §5.7 row both say `jdbcTemplate` autocommits and gives no atomicity. |
| **`closeBolAsShipped` moved to the base class** | **No clash.** The only other subclasses are `MobileTruckLoadingLockOrderProbeIT` and `MobileTruckLoadingRaceIT`, and neither declares that name (`git grep closeBolAsShipped src/test` returns only `MobileTruckLoadingClosedBolPurgeIT.java:64,117`). The base class already imports `WmsConstants` (`AbstractTruckLoadingPgFixture.java:25`) and declares `protected jdbcTemplate` (`:138`), so the unchanged body compiles there. |
| **Labels `BOUT-948703` / `BOUT-948704`** | **No collision.** `git grep 9487 src/test` finds only `948701`/`948702` (`MobileTruckLoadingClosedBolPurgeIT.java:39-40`). See L-new for the purge-list wording. |

## New findings

| # | Sev | Where | Finding | Change |
|---|---|---|---|---|
| L-new | Low | §5.7 row for `MobileTruckLoadingClosedBolPurgeIT`, and §6.1 | That class's `purgeByPrefix` builds the label list **twice**, as separate `List.of(...)` literals (`MobileTruckLoadingClosedBolPurgeIT.java:146` and `:151`). "Add both labels to its purge label list" could get applied to only one loop. If only the first loop has them, the pallet rows are left behind. If only the second, the pallet stays on a prefixed gate and super's location delete fails on the FK. That failure lands in bucket (2), so it cannot misclassify anything, but it costs a debugging round. | Say "add to both loops", or pull the list into one `FIXED_PALLET_LABELS` constant. The new class's override should use the same single-constant shape. |
| Nit | — | §5.8 bucket (2), "Resolution failures" | The example `FacadeException("Unitload not found")` comes from `UnitloadBusinessService:523`. The resolution failure that `scanDestination` itself throws is the `BusinessException` `"No unit load found for '…'"` at `:304`. | Add the `:304` message to that bullet. As written it lands in bucket (3), which is safe but costs a STOP. |

Fixes A–E still stand.

## References
- `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3487-evidence/plan-snapshot-r4.md:227,272-273,292-311,334-344,364`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:906-919,959-979,1273-1283`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java:250-313,523`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java:288-378,488-506`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/repo/jpa/BillofladingPositionRepository.java:88-107`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/WmsConstants.java:1556`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/java/net/aim_ai/wms/integration/service/mobile/MobileTruckLoadingClosedBolPurgeIT.java:39-40,117-124,144-156`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/java/net/aim_ai/wms/integration/service/mobile/AbstractTruckLoadingPgFixture.java:25,138`