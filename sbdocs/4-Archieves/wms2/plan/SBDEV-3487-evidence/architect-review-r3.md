---
title: "SBDEV-3487 architect review r3"
snapshot_sha1: aa81601cac0d252523a090b1f53e194dcbf4e052
---

## Verdict: SOUND-WITH-CHANGES

I walked `scanDestination` top to bottom for all four fixture states, and nothing throws before V2. That closes the Planner's open question. N1–N6 are all resolved correctly. Two Medium findings remain, and both are about how a red gets classified, not about the fix design:
- **M1.** The §5.8 STOP rule counts some destination-side guards as a disproof of §2. The fixture controls the destination, so a throw there is a fixture defect.
- **M2.** The AC-10b spec does not say the NOWAIT query must run inside the `tx()` lambda.

Fixes A–E stand.

## N1–N6 resolution

| # | Status | Evidence |
|---|---|---|
| N1 | **Resolved; the 6a state exactly mirrors closeBOL** | `BillofladingService.java:664-678` writes three things. (1) Every `u.id IN palletIds OR u.carrierunitloadId IN palletIds` row, so pallet and child, gets `storagelocationId`=Shipped, `entityLock`=`:lock`, version+1. (2) Stockunits are updated only `WHERE s.unitloadId IN (children of the pallets)`, so the pallet's own stockunits are not touched. (3) `:lock` is `SHIPPED` (405) for a non-TRANSFER_INTRACOMPANY BOL (`:404-406`). The §6.1 fixture sets exactly those rows and values: pallet and child to Shipped with 405, the child's stockunits to 405. It skips the version bump and the `unitload_record` audit rows, and nothing in `scanDestination` reads either. Shipped is seeded (id 15, `V2.2.00:2476`). |
| N2 | Resolved | §6.2 now expects HTTP 200 with `errors`. The Locale claim holds: `BusinessException.java:50` resolves with `Locale.getDefault()`. |
| N3 | Resolved on content | It uses NO KEY UPDATE, the positive control asserts the id, and it calls `setRollbackOnly`. The ordering gap is M2. |
| N4 | Resolved | §5.7 row. |
| N5 | Resolved | §6 layer attribution. |
| N6 | Resolved | AC-6b javadoc. |

## Q1: walk of `scanDestination` for 6a, 6b, 10a and 10b

All line numbers are in `MobileMoveUnitloadService.java` unless another file is named.

1. **`canonicalUnitLoadLabel` / `canonicalDestinationCode`** (`ScannedCodeResolver:125,168`): there is an exact hit, so the input comes back unchanged. This relies on the override deleting fixed-label residue in `@BeforeEach`, so `findByLabelid` does not see duplicates.
2. **`assertNotNirvanaSentinel`** (`:232`): the Nirwana unitload is seeded (`V2.2.00:3139`), so `getNirvana` does not create a row. `Unitload` has no `equals`, so the comparison is by identity and never matches.
3. **`:310` ON_HOLD check:** lock 0 or 405, never 104. The fixture removes the NPE.
4. **`:314-318` stockunit ON_HOLD sweep:** this reads only the pallet's own stockunits, and the pallet has none (the stockunit sits on the parcel). The loop body never runs, so the child stockunit's null lock (6b, 10a, 10b) is never read.
5. **`checkReservedStock`** (`:259`): it recurses into the parcel. `reservedamount` defaults to `BigDecimal.ZERO` (`Stockunit.java:18`), so it hits `continue` with no NPE.
6. **Damaged / Nirvana / Shipped destination checks:** all three are seeded (ids 6, 0, 15), DEST is none of them, and the source is the gate or Shipped, not Damaged.
7. **Location type:** type 1 is not `flowbin` (flowbin is type 2), so the non-flowbin branch runs. `moveStock` is a primitive defaulting to `false` (`TransferInfoDto:17`). DEST is not EmptyPallets.
8. **`assertSourceCarrierNotOnTruck`:** the pallet's carrier is null, so both guards return early (`BillofladingPositionService:81,100`).
9. **`transferUnitLoadToLocation`** (`UnitloadBusinessService:220-341`):
   - BLOCK_REALIGN pre-walk: `collectStockUnitIdsForUnitloadTree` returns `[parcel stockunit]`. `lockOwningPickingorders` (`PickLineRealignmentService:145`) finds no `pickingorder_position`, so the set of order ids is empty and nothing is locked.
   - DEST is locked `FOR UPDATE` and has lock 0.
   - There is no fix assignment and no `location_constraint` for type 1.
   - The pallet's carrier is null.
   - **The source lock is never checked**, so the 405 pallet moves.
10. **`processTransfer`** (`:522`):
    - Per-node pallet: it has no stockunits, and `recordForTransferUnitLoad` finds type 5.
    - Child parcel: `assertNoActivePickFor` and `realignForMovedStockUnit` iterate empty `findByPickfromstockunitId` results. `syncForMovedStockUnit` goes down either branch and returns at `probeId == null` (`ReplenishmentOrderSourceSyncService:72-90`, `ReplenishmentOrderMaintenanceService`). `isReplenishableDestination` is null-safe: `parseBoolean(null)` is false, and it does `findById(area 1)`.
11. **V2 (`:488`):** both patterns are seeded (`V2.2.00:2615,2638`), so `matches(pattern)` does not NPE. `BOUT-9487xx` matches the converted printing pattern. There is exactly one pallet position row, so R1 does not throw `IncorrectResultSize`.

**Conclusion:** nothing on this path throws for these fixtures. The realign and sync services do nothing because the fixture has no picking order and no replenishment order.

## Q2: the purgeByPrefix override and the labels

The ordering is correct: move to location 0, then super, then delete by exact label.
- **Why step 1 comes first:** super deletes the prefixed locations last (`AbstractTruckLoadingPgFixture:381`), and a pallet still on DEST or the gate would fail that delete on the FK. Location 0 is Nirwana, which is seeded and never swept.
- **Child parcel:** it carries the prefix, so super deletes it before the locations.
- **Positions:** super deletes them by name first, so nothing references the pallet by FK when step 3 runs.
- **`unitload_record`:** it has no FK. Super deletes the parcel's rows; step 3 deletes the rows written under the pallet's label.
- **Labels:** `git grep BOUT src/test` finds only 948701 and 948702. No other class sweeps `BOUT-%`, and the base sweep (`TL3465-%`) cannot match these labels. No collision.

## Q3 and Q4: see M1 and M2 below

## New findings

| # | Sev | Location | Finding | Concrete change |
|---|---|---|---|---|
| **M1** | Medium | §5.8 "Disproves analysis §2" bullet | Its examples, `STORAGELOCATION_LOCKED` and "a constraint `FacadeException`", both read **destination** state: `UnitloadBusinessService:249` checks the DEST lock, `:280-326` the DEST type constraint. The fixture chose DEST, so either one firing means DEST is set up wrong. The same holds for the Nirvana/Shipped/Damaged checks, the flowbin branch and EmptyPallets. §2's claim is "nothing checks the source's shipped state", and only a guard that reads the **source** can disprove it. As written, the rule would withdraw C2 over a fixture defect. | (1) Add DEST preconditions to §6.1, asserted before the call: `entity_lock=0`, `type_id=1`, `select count(*) from location_constraint where storagelocationtype_id=1` is 0, and no `fixlocationassignment` row on DEST. (2) Rewrite the disproof bucket as "a `BusinessException`/`FacadeException` from a **source-side** guard: `:310`, the `:315` stockunit loop, `checkReservedStock`, `assertNotNirvanaSentinel`, `assertSourceCarrierNotOnTruck`, or `processTransfer`'s `ACTIVE_PICK_MESSAGE` / replenishment block, with positions intact". A destination-side throw becomes a fixture defect. |
| **M2** | Medium | AC-10b | Keeping the query inside the lambda is possible: `jdbcTemplate` is a separate `DriverManagerDataSource` that the tenant tx manager does not bind (`PostgresTestSupportConfig:98-105`). But the spec says "inside `tx()` … **Then**, from `jdbcTemplate`". Read literally, the query runs after `execute` returns. By then the rollback has released the lock, the query returns the pallet id, and §5.8 would classify that as "10b: the lock is acquired", then STOP and revisit Fix D. That is a test-authoring slip misread as a design disproof. | Spell it out: "Inside the same lambda, after `transferUnitLoadToLocation` returns: `Throwable nowait = catchThrowable(() -> jdbcTemplate.queryForList(\"SELECT id … FOR NO KEY UPDATE NOWAIT\", Long.class, palletId))`; `status.setRollbackOnly()`. Outside, assert `((SQLException) NestedExceptionUtils.getMostSpecificCause(nowait)).getSQLState()` is `55P03`." Assert on the SQLState, not the exception class: Spring translates 55P03 to `CannotAcquireLockException`, and that mapping can change between versions. The positive control should use the same in-lambda shape. |
| L1 | Low | §5.8 classification | Two buckets leave some throwables in neither: `ObjectOptimisticLockingFailureException`, the 5 s `lock_timeout` (`QueryTimeout`/`CannotAcquireLock`, for example a peer build holding a row; see the concurrent-Maven memory), `DataIntegrityViolationException`, and `ScannedCodeResolver`'s ambiguity `BusinessException`. That last one is raised inside `scanDestination` but has nothing to do with shipped state. | Add a third bucket: "anything else: STOP and report the throwable; conclude nothing about §2 or §2.1". Put the resolver's ambiguity keys (`scanCodeAmbiguous*`) in the fixture-defect bucket explicitly. |
| L2 | Low | §5.5 re-check snippet | The snippet hard-codes `SCAN_GATE_D0_RECHECK` and says "in both variants". The AC-6a/6b mutation column ("→ `…_RECHECK`") and the §5.7 `never()` verify depend on V2 passing `MOVE_UNITLOAD_D0_RECHECK`. | Add one line: "V2 passes `MOVE_UNITLOAD_D0_RECHECK`." |
| Nit | — | §6.1 "set the state with jdbc inside `tx()`" | `jdbcTemplate` is not bound to `tx()`, so each UPDATE autocommits on its own. The existing `closeBolAsShipped` does the same, so this is harmless, and the preconditions catch a partial write. | Say "via `jdbcTemplate` (autocommit)" so nobody relies on atomicity that isn't there. |

No new steelman argument or tradeoff tension came up. The M1 and M2 changes only touch how reds are classified. Fixes A–E stay as they are.

## References
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/BillofladingService.java:399-406,663-679`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java:232-280,287-378,483-529`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java:220-341,522-560`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/PickLineRealignmentService.java:116-189`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/ReplenishmentOrderSourceSyncService.java:72-90` (plus `isReplenishableDestination`)
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/ScannedCodeResolver.java:125-176`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/UnitloadRecordService.java` (`createRecord`)
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/model/Stockunit.java:12-18`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:2461,2467,2476,2615,2638,3139`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/java/net/aim_ai/wms/integration/service/mobile/AbstractTruckLoadingPgFixture.java:170-290,368-382`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/java/net/aim_ai/wms/integration/service/mobile/MobileTruckLoadingClosedBolPurgeIT.java:143-155`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/java/net/aim_ai/wms/common/config/PostgresTestSupportConfig.java:98-105`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/java/net/aim_ai/wms/common/fixtures/PgLaneFixtures.java:80,112-130,197-219`
- Snapshot reviewed unmodified: `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3487-evidence/plan-snapshot-r3.md` (sha1 `aa81601cac0d252523a090b1f53e194dcbf4e052`)