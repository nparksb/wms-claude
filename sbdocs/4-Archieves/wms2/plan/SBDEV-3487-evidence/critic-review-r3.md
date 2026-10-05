---
title: "SBDEV-3487 critic review r3"
snapshot_sha1: aa81601cac0d252523a090b1f53e194dcbf4e052
verdict: ITERATE
---

**Verdict: ITERATE**

r3 resolves all ten of my r2 findings. What remains is small: two Medium findings, and both are about the same thing that blocked r2, which is whether the STOP rule reaches the right conclusion. Finding 1 is a set of rule examples that point the wrong way plus a gap in the classification. Finding 2 is one ambiguous sentence in AC-10b. Neither touches the fix design (Fixes A–E). The corrected text, together with the Low fixes listed below, is enough; a short confirmation pass would do rather than a full fourth round.

## Resolution of r2 findings

| # | Status | Checked against the code |
|---|---|---|
| H1 | Resolved in form, but the new classification has flaws (Finding 1) | The lock is set explicitly: 405 for 6a, 0 for 6b/10a/10b, so `:310` (`== ON_HOLD`, 104) can no longer unbox a null. 6a mirrors `BillofladingService:664-678`. Preconditions are asserted before the call. AC-6b now says the pallet is on the gate. The first-PG-run and BLOCK_REALIGN note is recorded. |
| M1 | Resolved | The override mirrors `ClosedBolPurgeIT:143-155`. `BOUT-94871[0-3]` collides with nothing (`git grep 9487.. src/test` finds only 948701/948702). AC-10b calls `setRollbackOnly()`. |
| M2 | Resolved | Both controllers catch `BusinessException` and return `ok(errorMap)`: `TruckLoadingController:121-133`, `MoveUnitloadController:76-90`. selectDestination returns `ok(true)` at `:87`. The message is resolved with `Locale.getDefault()` (`BusinessException:50`). The ADR consequence is correct. |
| M3 | Resolved | AC-1 and the AC-3 IT both use `catchThrowable`, then the data assertions, then key and site. |
| L1 | Resolved | The "into the try" mutant is marked equivalent. |
| L2 | Resolved | The filter checks logger name, WARN and the prefix, then `getArgumentArray()[0] == site`. The "already gone" WARN in §5.5 doesn't carry the prefix, so it is correctly excluded. |
| L3 | Resolved | The compile-only list is now complete. |
| L4 | Resolved | |
| L5 | Resolved, but r3 added an error ("explicit id", L-a below) | |
| L6 | Resolved for positions only (L-e below) | |

## New findings

**Finding 1 (Medium). §5.8 STOP rule: both "disproof" examples are guards on the destination, which the fixture sets up. Some throwables also fit neither bucket.**
- **`STORAGELOCATION_LOCKED`** (`UnitloadBusinessService:251-252`) reads `destinationLocation.getEntityLock()`, meaning DEST's lock. `PgLaneFixtures.location` sets that to 0.
- **The constraint check** (`:275-324`) reads DEST's type. It also throws a `BusinessException` (`MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION`, `:322`), not a `FacadeException` as the rule says.
- **Other destination-side throws with the same problem:** `CARRIER_NOT_ON_FIXLOC` (`:262`), `WRONG_ITEMDATA_FIXASSIGNMENT` (`:269`), "Pallet not empty!", the nirvana/shipped/damaged destination checks, and `isMoveStock()`, which is a DTO field.
- **Why it matters:** a mis-built DEST would therefore read as "C2 claim withdrawn, AC-6 becomes a positive control". That is the r2 failure mode again, now triggered by the destination instead of the source.
- **The source-side guards are fixture-controlled too:**
  - `checkReservedStock` depends on reservations.
  - `assertNoActivePickFor`/`realignForMovedStockUnit` depend on pick lines.
  - `syncForMovedStockUnit` depends on replenishment orders.
  - None of them reads anything closeBOL writes: Shipped, 405, or CLOSED.
- **Throwables that fit neither bucket:**
  - `FacadeException("Unitload not found")` (`:523`). By the rule's wording it counts as a disproof, but it is a fixture defect.
  - `scanCodeAmbiguousUnitLoad` from `ScannedCodeResolver:129`.
  - Spring `DataAccessException`s: lock timeout from a concurrent Maven run, `IncorrectResultSize` from leftover labels, `DataIntegrityViolation`.
  - A pre-fix result with `t == null` and positions intact. This happens if V2's pattern or R1 misses; the rule is silent on it.
- **Fix:**
  - Invert the rule. A disproof requires a guard whose condition is met by closeBOL's output (`storagelocation_id` = Shipped, `entity_lock` = 405, positions CLOSED). The executor must quote the guard's condition. **Everything else is fixture or environment**, including every destination guard, resolution failure, `DataAccessException`, and a pre-fix `t == null` with positions intact.
  - Add DEST preconditions before the call: `entity_lock` = 0, `type_id` = 1, 0 `location_constraint` rows for type 1, and 0 `fix_location_assignment` rows for DEST.

**Finding 2 (Medium). AC-10b doesn't say that the NOWAIT probe must run while the transaction is still open.** The spec says: `inside tx() call status.setRollbackOnly() and transferUnitLoadToLocation(...). Then, from jdbcTemplate ... run SELECT ... NOWAIT → 55P03`. "Then" reads naturally as "after `tx()` returns".
- `jdbcTemplate` really is a separate connection: it wraps its own `DriverManagerDataSource` (`PostgresTestSupportConfig:98-105`), not the tenant routing DataSource. So the probe run inside the lambda does see the lock.
- Run after the lambda, the rollback has already released the lock. The probe returns the id, and the STOP rule records "10b: the lock is acquired", i.e. a disproof of §2.1. That red is spurious, and the rule would reopen Fix D's justification on a false basis.
- The positive control doesn't catch this, because it also returns the id.
- **Fix:** "Still inside the `tx()` lambda, after `transferUnitLoadToLocation` returns and before the lambda exits: `Throwable probe = catchThrowable(() -> jdbcTemplate.queryForList(...NOWAIT...))`. Assert `CannotAcquireLockException` with root-cause SQLState `55P03`. Assert on `probe` after the template returns. Load `pallet` with `unitloadRepository.findById` inside the lambda."

## Walk of each AC's test path

**AC-6a/6b/10a:**
- With the r3 fixture state, `scanDestination` gets through the nirvana sentinel, `:310` and `:316` (the pallet has no direct stock units), and `checkReservedStock` (`reservedamount` defaults to `ZERO`, `Stockunit:18`).
- The DAMAGED, nirvana and shipped lookups all resolve against seeded locations.
- `assertSourceCarrierNotOnTruck` does nothing, because `carrierId` is null.
- The BLOCK_REALIGN path is also clean. `lockOwningPickingorders` and `assertNoActivePickFor`/`realign` loop over nothing, since there is no pick line. `syncForMovedStockUnit` returns at a null probe, since there is no replenishment order.
- V2 runs against the real seeded sysprops and matches `BOUT-%1$06d`.
- Teardown works: the prefixed parcel on DEST is removed before `location`.
- This answers my r2 open question: the realign path is safe for this fixture.

**AC-1, AC-3 IT, AC-7, AC-9:** the red reasons and the kills of the site-tagged mutants hold. Deleting Fix A leaves `SCAN_GATE_D0`. Deleting Fix B or Fix C leaves `…_RECHECK`, because R4/R6 skip the CLOSED children and R3/R5 return 0. The AC-7 predicate mutant leaves X non-empty.

**Unit tests:** AC-2 and AC-11 are fine under strict stubs. MockitoExtension doesn't report unnecessary stubbing on a test that already failed, so the pre-fix red is the assertion failure.

## Low findings, for the executor

- **L-a:** AC-9 says to save "with an explicit id". `AbstractBaseEntity:19-26` is `@GeneratedValue(SEQUENCE, seqentities)`, and `@Version Integer` makes `save()` call `persist`. A preset id is either overwritten or rejected. Drop it; the "no default" fact applies only to raw jdbc inserts.
- **L-b:** AC-3 IT and AC-7 in `ClosedBolPurgeIT` need outbound labels, but that class's override purges only 948701/948702. Either reuse those labels (per-test purge makes that safe) or add the new ones to its list.
- **L-c:** "set the state with jdbc inside `tx()`" has no effect: `jdbcTemplate` autocommits on its own DataSource. Say "via `jdbcTemplate` (autocommits)" so it doesn't contradict what 10b relies on.
- **L-d:** 6a says "as in `closeBolAsShipped`", but that helper is private to the other class. Copy it or move it up to the base class.
- **L-e:** In §6.2 scenario 3, if the fix is missing from the deployed build, the move takes the pallet and its children off Shipped, and the snapshot only covers X's positions. Snapshot the pallet's and children's `unitload` rows as well, and run scenario 3 only after scenario 1 shows the fix is live.
- **L-f:** The `MoveUnitloadController:73-79` citation should be `:67-90`.

## What must change for APPROVE

1. Rewrite the §5.8 classification as in Finding 1: disproof only for a guard whose condition is met by closeBOL's output, with the condition quoted; everything else is fixture or environment. Add the DEST preconditions.
2. Pin AC-10b's probe inside the lambda, using `catchThrowable`, as in Finding 2.

Fold in L-a to L-f at the same time.

**How I reviewed:** I stayed in thorough mode, with no Critical findings and no systemic pattern. On the realist check, both findings stay Medium. Each can only fire on a mistake the plan's own specification makes unlikely (a mis-built DEST, or reading "Then" as "after"). But either one would draw the wrong design conclusion, which the rule exists to prevent, and each costs one or two sentences to fix.

**Ralplan summary:**
- **Principle/option consistency: Pass.**
- **Alternatives: Pass.**
- **Risk/verification rigor: Fail.** Only narrowly: Findings 1 and 2.
- **Deliberate additions: Pass.**

Files:
- Plan: `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3487-evidence/plan-snapshot-r3.md`
- Code, all under `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/`:
  - `src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java` (lines 221-341, 522-560)
  - `src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java` (lines 259-378)
  - `src/test/java/net/aim_ai/wms/common/config/PostgresTestSupportConfig.java` (lines 98-105)
  - `src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java` (lines 19-35)