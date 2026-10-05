---
title: "SBDEV-3487 critic confirmation r4b"
snapshot_sha1: 60989a1f26b76f3574d27b5b7a3c7517ffbabaae
verdict: APPROVE
---

**Verdict: APPROVE**

All eight r3 items are fixed correctly, and the edits add no Critical, High or Medium defect. I checked the snapshot hash (`60989a1f…`, matches) and diffed r4 against r4b: only the three stated lines changed. I then checked the code claims against the worktree at `682483fe`.

**Status per item**
- **Finding 1, the inverted §5.8 STOP rule: resolved.**
  - **Can a real disproof be misrouted?** No, not into bucket (2). There is no source-side guard in the path today whose condition reads Shipped, 405 or CLOSED. The source checks in `scanDestination` compare `== ON_HOLD` (104). The shipped, nirvana and damaged checks there compare against `destinationStorageLocation`, and `UnitloadBusinessService:252` and `:257-275` read DEST only. So bucket (1) can only be reached by a guard that genuinely reads closeBOL's output.
  - **Can a fixture defect reach bucket (1)?** Only through a guard that reads one of those three values, and none exist, so no.
  - Bucket (3) catches everything else conservatively.
- **Finding 1, the DEST preconditions: resolved.**
  - The names match V2.2.00: `location.entity_lock` / `type_id` (`:963`/`:973`), `location_constraint.storagelocationtype_id` (`:1282`), `fix_location_assignment.assignedlocation_id` (`:917`).
  - They are the right things to check. The code reads the lock after `entityManager.refresh`, so the DB value is what it sees. It looks up constraints by `findByStoragelocationtypeId(dest.typeId)` and the fix assignment by `findByAssignedlocationId(dest.id)`.
- **Finding 2, AC-10b's in-lambda probe: resolved.**
  - The probe now runs while the transaction is open.
  - The lock it detects is the flushed pallet UPDATE: `processTransfer` sets `storagelocationId`, then runs the JPQL `findByCarrierunitloadId` on `Unitload`, which auto-flushes it.
  - The SQLState assertion, the other-SQLState rule (bucket 3) and the positive control all hold.
- **L-a, AC-9 without preset ids: resolved.** The `name = PREFIX + …` sweep path is kept.
- **L-b, the new labels BOUT-948703/948704: resolved.**
  - `git grep 9487 src/test` finds only 948701/948702 (`MobileTruckLoadingClosedBolPurgeIT:39-40`).
  - The duplicated `List.of` in the purge override is real (`:145` and `:150`), so the `FIXED_PALLET_LABELS` change is warranted.
- **L-c, the jdbcTemplate autocommit wording: resolved.**
- **L-d, the `closeBolAsShipped` move: resolved.**
  - Today it is private at `:117`. Moving it up works because the base class already exposes `protected JdbcTemplate` (`:138`) and uses `tx()`.
  - The new IT is declared `extends AbstractTruckLoadingPgFixture` (§5.7).
- **L-e, the manual §6.2 ordering and snapshots: resolved.** Scenario 1 runs first, the `unitload` rows of the pallet and its children are snapshotted, and scenario 3 is gated on scenario 1 passing.
- **L-f, the controller citation: resolved** (`:67-90`).

**New findings, all Low, for the executor**
1. **Dead-code citation in bucket (2).** The "No unit load found" throw at `MobileMoveUnitloadService:304` can never fire. The `findByLabelid(...).orElseThrow(EntityNotFoundException)` at `:302` fires first. Nothing is misrouted, because `EntityNotFoundException` is already in bucket (2). Change the citation to `:302`.
2. **AC-10b: `probe` can't be read outside the lambda as written.** It is assigned inside the lambda but asserted outside it. Return it from `tx().execute(status -> …)`, or hold it in an `AtomicReference`. The positive control needs the same treatment for its returned list.
3. **Bucket (1) names only the pallet's own values.** It lists the source's own `storagelocation_id` and `entity_lock`. In 6a, closeBOL output also includes the child on Shipped and the child's stockunits at 405. A guard reading those would land in bucket (3) (STOP, conclude nothing), not bucket (1). That errs on the safe side and no such guard exists today, so no change is needed. Optionally widen the wording to "the source or its carrier tree".

Plan: `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3487-evidence/plan-snapshot-r4b.md`. Code checked in `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/`: `service/mobile/MobileMoveUnitloadService.java` (`:295-380`), `service/UnitloadBusinessService.java` (`:221-345`, `:518-548`), `integration/service/mobile/MobileTruckLoadingClosedBolPurgeIT.java` (`:39-40`, `:117-155`), `integration/service/mobile/AbstractTruckLoadingPgFixture.java`, `db/migration/V2.2.00__base_v2_schema.sql`.

**Ralplan summary**
- **Principle/option consistency:** Pass.
- **Alternatives:** Pass.
- **Risk/verification rigor:** Pass. The r3 failure is closed.
- **Deliberate additions:** Pass.