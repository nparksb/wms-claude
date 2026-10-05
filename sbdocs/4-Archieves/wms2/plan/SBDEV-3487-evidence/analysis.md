---
title: "SBDEV-3487 analysis bundle"
date: 2026-09-24
source: "executor (opus) analysis phase, T3 wms-bugfix-plan"
---

# SBDEV-3487: analysis evidence bundle

## Findings to read first

1. **The move-unitload path loses the same data. It also moves the shipped pallet back out of Shipped.**
   - `scanUnitLoad` (`GET /v3/moveUnitload/selectSource/{input}`) rejects a pallet standing on the Shipped location: `if (shipped.equals(storageLocation)) throw … "Can not move unit load from "`.
   - `scanDestination` (`POST /v3/moveUnitload/selectDestination`) has no such check. It only checks the destination: `if (shipped.equals(destinationStorageLocation))`.
   - So a direct call to `selectDestination` for a shipped outbound pallet, going to an ordinary location, runs `transferUnitLoadToLocation(sourceUnitLoad, …, false, CODE_TRANSFER, …)` and then `handleTruckOffLoading(label)`.
   - `assertSourceCarrierNotOnTruck` doesn't stop it. Both of its checks start with `if (carrierId == null) return;`, and a pallet has no carrier.
   - `transferUnitLoadToLocation` doesn't stop it either. Its SBDEV-3341 javadoc: "There is deliberately no check on the moved unit load's own lock, on the source location's lock".
   - This comes from reading code only; no IT was run. AC-6 below is the test that would prove it.
   - This is the same "check only in the UI step" pattern as SBDEV-3474.
2. **A guard in the facade alone races with `closeBOL`.** The D0 backstop is the real guarantee, and it is race-free only because it runs after B2 (see §3.3 and §5).
3. **The code has three definitions of "shipped", not two.**
   - `checkPallet`: CLOSED only.
   - `assertParcelCarrierNotShipped`: CLOSED or TRANSFER.
   - `removeBOLPositionIfExists`: CLOSED throws "already shipped!"; TRANSFER falls to `default: throw "Unexpected status="`.
   - Decision 2 stands. This is noted, not changed.
4. **The exposure count has moved.** Hydra PRD now has **44** exposed pallets, not 43. Two pallet positions were created in the last day; the newest is 2026-09-23 19:38 UTC. All 44 are intact.
5. **No evidence contradicts decisions 1–3.** Decision 3(b) closes finding 1, but only if the backstop **throws**.

## §0 Affected sites, by enumeration

**How I enumerated:**
- **I1:** `git grep` of each of the 4 repository methods and both D0 variants.
- **I2:** delete-pattern grep: `delete.*billofladingPosition|deleteBolPosition|delete from billoflading_position|billofladingPositionRepository\.delete|DELETE FROM BillofladingPosition`.
- **I3:** `[bB]ol*Repository.(delete|deleteAll|deleteById|…)`, plus every class that holds the repository (8 of them).
- **I4:** `getBySourceUnitLoadLabelId|findByUnitloadLabelIdList|findBolNumberByUnitLoadLabelId`.
- **I5:** DB check of foreign-key delete actions.

**What these greps can't see:**
- Native SQL built as strings.
- Repository variables whose names don't match the patterns.
- Reflection.
- Direct DB edits.

Spring Data REST routes are ruled out: both repositories are `@RepositoryRestResource(... exported = false)`, so the `@RestResource(path="deleteBolPositionById")` annotations don't route.

| # | Site (quoted) | Construct | Same root cause? | In scope? | Can it delete a CLOSED position? |
|---|---|---|---|---|---|
| R1 | `findBolIdByUnitLoadLabelId`: `select bp.id … join unitload u on bp.source_id = u.id where u.labelid = :unitLoadLabelId` → `Long` | Finder. Matches label only. Returns a single Long. | yes | yes | Selects it. Throws `IncorrectResultSize` if more than one row. |
| R2 | `findBolCarrierIdListByUnitLoadLabelId`: `where bp.carrier_id = ( SELECT bp2.id … ) union all …` | Finder. The scalar subquery raises PG `21000` if there is more than one pallet row. | yes | yes | Selects it. |
| R3 | `deleteBolPositionByIdNoClear`: `@Modifying(flushAutomatically = true) "DELETE FROM BillofladingPosition bp WHERE bp.id = :bolPositionId"` | Bulk delete | yes | yes | **yes** |
| R4 | `deleteBolPositionsCarrierIdsNoClear`: `… WHERE bp.carrierId IN :carrierIds` (the list is children plus the pallet) | Bulk delete, levels 2 and 3 | yes | yes | **yes** |
| R5 | `deleteBolPositionById` (`clearAutomatically = true`) | Clearing sibling of R3 | yes | yes (3b) | **yes** |
| R6 | `deleteBolPositionsCarrierIds` | Clearing sibling of R4 | yes | yes | **yes** |
| V1 | `handleTruckOffLoadingNoClear` → R1, R2, R4, R3 | D0, no-clear variant | yes | yes | **yes** (reproduced) |
| V2 | `handleTruckOffLoading` → R1, R2, R6, R5 | D0, clearing variant | yes | yes | **yes** (code reading) |
| C1 | `MobileTruckLoadingWriteService.scanGate` D0: `mobileTransferService.handleTruckOffLoadingNoClear(dto.getPalletName());` | Only caller of V1 (I1) | yes | yes | yes |
| C2 | `MobileMoveUnitloadService.scanDestination`, non-flowbin branch: `assertSourceCarrierNotOnTruck(...); transferUnitLoadToLocation(...); handleTruckOffLoading(dto.getUnitLoadLabel());` | Only caller of V2 (I1) | yes | yes | **yes** (§2) |
| D1 | `closeBOL`: `DELETE FROM BillofladingPosition bp WHERE bp.id IN :ids` (garbage rows) | Rows with null operator, carrier, itemdata and source, on a BOL that is not yet closed | no | no | No. The state switch returns before this for CLOSED or CANCELLED. |
| D2 | `removeBOLPositionIfExists`: `case CLOSED: throw …"already shipped!"; default: throw …` then `delete(...)` | Parcel-level palletize path (3 callers) | no | no | **no** |
| D3 | `BillofladingRepository.deleteBolByBolNumber`: `DELETE FROM Billoflading b WHERE b.number = :bolNumber` | Deletes a BOL | no | no | No. It has 0 callers and isn't routed, and the foreign key is NO ACTION, so it would fail rather than cascade. |
| S1 | `checkPallet`: `getBySourceUnitLoadLabelId(palletLabel)` → `case CLOSED: throw new BusinessException("billOfLadingPositionUnxepectedStateFound", palletLabel, …)` | The only check of a pallet's own position state on the truck-loading path (I4). It checks **position** state. | reference | the guard mirrors it | n/a |
| S2 | PHASE C: `switch (bol.getState()) … case CLOSED: throw "billOfLadingUnxepectedStateFound"` | Checks the target BOL only | this is the gap | n/a | n/a |
| S3 | `assertParcelCarrierNotShipped`: `anyMatch(CLOSED \|\| TRANSFER)` | Looks at a parcel's carrier; does nothing for a pallet | no | no | n/a |
| S4 | `assertParcelCarrierNotOnTruck` / `assertPalletNotAssignedToGate` | Any position | no | no | n/a |

**Where the "only" claims come from:**
- "V1 and V2 each have one caller" comes from I1. It can't see reflection or callers outside `src/main`.
- "S1 is the only check" comes from I4. `findBolNumberByUnitLoadLabelId` has 0 callers, and `findByUnitloadLabelIdList` is used only for parcels, in `ParcelMonitorViewService`.

## §2 The move-unitload caller (C2)

**The flow.**
- Controller: `MoveUnitloadController`, `/v3/moveUnitload`, `@RequiresFunction(MOBILE_UI_VIEW_TRANSFER)`.
- Two separate POSTs: `selectSource` calls `scanUnitLoad`, and `selectDestination` calls `scanDestination`.
- `scanDestination` is `@Transactional(tenantTransactionManager, rollbackFor = BusinessException/FacadeException)`.

**The guards in `scanDestination`, in order, for a shipped pallet (Shipped location, `entity_lock` 405) going to an ordinary location:**

| Guard | Does it stop the pallet? | Why |
|---|---|---|
| label resolve, `orElseThrow` | no | the pallet exists |
| `assertNotNirvanaSentinel` | no | |
| `ON_HOLD` lock checks | no | 405 is not ON_HOLD. The `UnitloadBusinessService` javadoc: "`MobileMoveUnitloadService` refuses `ON_HOLD` alone and therefore still relocates a SHIPPED … container" |
| `checkReservedStock` | no | only a pick in progress (state < PICKED) blocks |
| damaged / nirvana / shipped checks | no | these check the **destination** |
| `assertSourceCarrierNotOnTruck` (both halves) | **no** | `if (carrierId == null) return;` |
| `transferUnitLoadToLocation(..., ignoreLock=false, …)` | **no** | it checks only the destination's lock |
| `handleTruckOffLoading` | runs | 44 of 44 Hydra shipped pallets match an outbound pattern (Q4) |

**What happens:** in one committed transaction, the pallet moves out of Shipped and keeps its 405 lock, and its CLOSED shipping record is deleted. The handheld UI doesn't hit this, because `selectSource` rejects the pallet first.

**Proposed, not filed (a T3-level data-integrity issue, so Nam should confirm):** a shipped unitload whose label is *not* outbound-shaped can still be moved out of Shipped through a direct `selectDestination` call. No positions are deleted in that case. The fix is one line mirroring `scanUnitLoad:157`, `shipped.equals(sourceLocation)`, plus one unit test, about 30 minutes. It probably belongs on SBDEV-3442, which SBDEV-3418 §4.2(3) says already covers `scanDestination`.

**Persistence-context note:** `assertSourceCarrierNotOnTruck` loads position *entities* (that is why V2 keeps `clearAutomatically`). For a *pallet* source it returns before loading anything. The backstop must still not add an entity load.

## §3 Constraints on the guard's design

**3.1 Why a copy of `checkPallet` can't go inside the write transaction.**
- It loads `BillofladingPosition` entities. D0 then bulk-deletes those rows with the NoClear deletes, which leaves stale managed instances in the persistence context.
- Its CLOSED branch also calls `billofladingRepository.findById`. If that BOL is the target BOL, B1's `findByIdForUpdate` becomes a lock upgrade, which is the SBDEV-3244 defect.
- It breaks the class rule: "PHASE A resolves everything as scalars … creates no `EntityEntry`."

**3.2 Open-session-in-view is off.** `application.properties:85` sets `spring.jpa.open-in-view=false`, so a read in the facade gets its own EntityManager, which closes before the write transaction opens. `checkPallet` already reads repositories from this same non-transactional class, so this isn't new.
- I'd still recommend a **scalar** native query that returns the BOL name directly:

```sql
select coalesce(b.name, bp.number) from billoflading_position bp
join unitload u on u.id = bp.source_id left join billoflading b on b.id = bp.billoflading_id
where u.labelid = :label and bp.state = 'CLOSED' order by bp.id limit 1
```

- `source_id` is indexed on Hydra.
- The error key `billOfLadingPositionUnxepectedStateFound` exists **only** in `messages_en_US.properties:331` (`Pallet %1s already part of BOL %2s`), not in the base `messages.properties`. `checkPallet` has the same gap, so it isn't new.
- Tests should assert `getKey()`.

**3.3 Placement, and the race.**
- **(a) Facade guard.** Put it in `MobileTruckLoadingService.scanGate`, after `outboundPalletLabelGuard.requireOutboundPalletLabel` and before the `try { truckLoadingWriteService.scanGate }`. This follows the SBDEV-3474 architect precedent.
- **(b) In-transaction re-check.** Let the D0 backstop be it, since it runs after B2. **Don't** add a PHASE A re-check: PHASE A runs before B2 and is just as racy as the facade.

**The race exists.** The facade check passes while BOL X is still TRUCK_LOADING. Then `closeBOL(X)` commits. Then the write transaction's D0 sees CLOSED positions and deletes them. B1 locks the target BOL Y, not X.

**Why the backstop closes it:**
- `closeBOL`'s **measured** lock order (from `ClosebolLockOrderProbeIT`) is `billoflading → unitload_record → unitload → stockunit → flush{billoflading_position, customerorder, customerorder_position}`.
- Its bulk update `UPDATE Unitload u … WHERE u.id IN :palletIds OR …` locks the pallet row before it writes CLOSED to the positions.
- scanGate holds the pallet row from B2 until commit.
- So if `closeBOL` gets the pallet first, B2 waits and D0 then sees CLOSED, and the backstop throws.
- If scanGate gets it first, `closeBOL` can't commit CLOSED until scanGate does. D0 then deletes TRUCK_LOADING rows, which is the intended move. `closeBOL` then fails its version-checked flush and rolls back (a 409). That behaviour already exists today and isn't data loss.
- **Caveat:** this rests on one measured probe of one path.

**⚠ A trap for the TDD gate:** `AbstractTruckLoadingPgFixture` has `@MockitoBean OutboundPalletLabelGuard`. If the new guard lives on that bean, it's a silent no-op in every IT on this fixture, `MobileTruckLoadingClosedBolPurgeIT` included. The red IT would then go green through the backstop alone. Put the guard on a bean the fixture doesn't mock, or prove the facade rejection with a unit test.

## §4 Design of the backstop

**4.1 Position state matches BOL state, in code and in the DB.**
- `closeBOL` sets `bolState` on all three levels it walks (`bolPosPallet`, `bolPosParcel`, `bolPosPosition`).
- `finishTransfer` runs `UPDATE BillofladingPosition bp SET bp.state = :state … WHERE bp.billofladingId = :bolId`.
- Hydra: the only pair is CLOSED/CLOSED (756 positions on 40 BOLs).
- Dev: CLOSED/CLOSED, TRANSFER/TRANSFER and TRUCK_LOADING/TRUCK_LOADING only, with **0** mismatches. Child and parent states differ in 0 rows.
- So keying on `bp.state` is valid and needs no join.

**4.2 Recommendation: the backstop THROWS.** Three reasons:
- Decision 1 is to reject. A silent skip would let PHASE D move the shipped pallet to the gate and build a second tree.
- For C2, only a throw rolls back the move out of Shipped.
- A skip would create a pallet with positions on two BOLs. After that, R1 and R2 throw on every later D0 for that label. Today there are 0 such pallets on either database.

**Shape:**
- **(i)** A scalar pre-check in **both** V1 and V2, inside `if (matches)` and before R1. It throws `billOfLadingPositionUnxepectedStateFound`. The pattern-miss and not-configured exits stay as they are.
- **(ii) Recommended second line:** add `AND bp.state <> 'CLOSED'` to the delete statements R3–R6.
  - Under READ COMMITTED, a DELETE that waits on a lock re-checks its own WHERE clause against the newly committed row. That makes it race-proof without relying on the pallet lock.
  - That matters for C2, which never takes `findByLabelidForUpdate` on the pallet. When its UPDATE of the pallet flushes is Hibernate's choice, and I didn't measure it.
  - A partial skip still fails loudly: the NO ACTION foreign key `billoflading_position → billoflading_position` raises `23503`.
- **Don't** make a finder filter the only backstop. It would be a check-then-act that skips silently.
- **Leave** R1's single Long and R2's scalar subquery as they are. That is SBDEV-3418 §4.2(2), a latent issue with 0 exposure.

## §5 Concurrency

- **Two scans of the same pallet serialise on B2:** `unitloadRepository.findByLabelidForUpdate(dto.getPalletName())`, which is `PESSIMISTIC_WRITE`. If they target the same BOL, they serialise even earlier, on B1. The second scan's D0 then moves the pallet, as intended.
- **`closeBOL(X)` racing `scanGate` of a pallet onto Y:** they serialise on the pallet row. The backstop is race-free against `closeBOL`; the facade guard is not.
  - SBDEV-3418's plan says "closeBOL can hold bolpos and want Unitload" in §3.2. That was read from source order, and the plan says so itself. The measured order puts the position flush after the unitload update.
  - `closeBOL`'s early garbage delete touches only rows with a null source, never the pallet's rows.
- **`finishTransfer`:** it locks the BOL, then positions (its bulk update runs immediately), then unitloads. scanGate locks unitload before positions, so under contention you get a deadlock (`40P01`) and one side aborts. No interleaving deletes CLOSED rows, and the fix adds or removes no deadlock.
- **Locking impact of the fix:** the facade guard takes no locks. The backstop is one indexed SELECT with no lock, after B2, so the table order is unchanged. It must **not** be a `FOR UPDATE` on position rows.
- **I didn't run a tracer pass; I judged it unnecessary.** The answer comes from a measured lock order plus the code, and no competing hypotheses remain. The one leftover (C2 takes no explicit pallet lock) is closed by §4.2(ii) by construction. A more useful follow-up, out of scope here, is to extend `ClosebolLockOrderProbeIT` to record `billoflading_position` lock acquisitions. SBDEV-3418 already named that as the next probe.

## §6 Docs and prior plans

- **Function-to-docs map, §9 rows 215–216:**
  - `MobileMoveUnitloadService` → the move-stock/unitload workflow doc.
  - `BillofladingPositionService` and `MobileTruckLoadingWriteService` → `wms2-bol-truck-loading-workflow.md`.
- **Truck-loading workflow doc:** the D0 row says "`handleTruckOffLoadingNoClear` — ahead of every pending write" with no state caveat. It needs a line added after the fix.
- **⚠ The move-unitload workflow doc is wrong in two places, and that is what hides finding 1:**
  - Its flow box says `handleTruckOffLoading` runs when the **destination** matches the outbound regex. The code tests the **source** label.
  - It lists "not Shipped" / "Can not move from shipped (144)" under `scanDestination`. That check is only in `scanUnitLoad`.
- **Transaction/OSIV boundary map:** confirms OSIV is off. No other constraint.
- **State-machine catalog §4.9:** position and BOL share `BillOfLadingState`. Its writer names are stale, and it says itself that §4.3 onward wasn't audited. It notes that string states have no DB constraint. No constraint on this fix.
- **SBDEV-3418 plan:**
  - **§4.2 item 4 already proposed this fix:** "Re-evaluating checkPallet's BOL-position state guard inside scanGate (C5, proposed) … Proposing, not filing."
  - Item 2 covers the non-unique finders (0 exposure).
  - Item 3 routes `scanDestination` work to SBDEV-3442.
  - §3.2 says D0's placement is "a choice among unrankable options". **Don't move D0.**
- **SBDEV-3474 architect consult:** it sets the facade placement and the `@MockitoBean` pattern (see the trap in §3.3).

## §7 Acceptance-criteria candidates

| AC | Test | Level | Red today? | Mutation check |
|---|---|---|---|---|
| AC-1 | Change the red IT from `catchThrowable` to `assertThatThrownBy` with `getKey()` = `billOfLadingPositionUnxepectedStateFound`. The closed BOL's positions stay `containsExactlyElementsOf(shippedPositions)`, the other BOL stays empty, and the pallet's location is unchanged. | IT | yes | Removing both guard and backstop turns it red. Removing only one keeps it green, which is why AC-2 and AC-3 exist. |
| AC-2 | The facade guard fires before any lock: assert the key, `verifyNoInteractions(truckLoadingWriteService)`, and `InOrder` (label guard first, then the position guard). | unit | yes | Remove the call → red. |
| AC-3 | V1 backstop: the pre-check finds a CLOSED position → it throws and `never()` calls either NoClear delete. Also an IT that calls the write service's `scanGate` directly. | unit + IT | yes | Remove V1's pre-check → red. |
| AC-4 | V2 backstop: same as AC-3, with the clearing deletes. | unit | yes | Remove V2's pre-check → red. Scope PIT to `MobileMoveUnitloadService`. |
| AC-5 | A label that doesn't match the pattern runs no position query. The existing `HandleTruckOffLoading` tests stay green. | unit | no | Move the pre-check above `matches` → red. |
| AC-6 | Move-unitload IT: scanGate, close the BOL, put the pallet on Shipped with lock 405, call `scanDestination` to an ordinary location. Expect the key, positions intact, and the **pallet still on Shipped**. Write it red first; that also confirms §2. | IT | expected yes (not run) | Remove V2's pre-check → red. |
| AC-7 | The control stays green. Add a TRANSFER sibling that closes as TRANSFER, then re-scans, and the pallet **moves** (decision 2). | IT | no | A guard of CLOSED or TRANSFER turns the TRANSFER sibling red. |
| AC-8 | The guard and backstop query returns a scalar (String or boolean), not an entity. | unit | n/a | An entity-returning finder → red. |
| AC-9 | Only if §4.2(ii) is adopted: a direct repository delete on CLOSED rows affects 0 rows. | IT | yes | Drop the predicate → red. |

## §8 DB verification (read-only)

Hydra is `wh01_hydra_v2`; dev is `dev_wh01_om1`. The first dev query dropped the connection and succeeded on retry.

- **Q1 (Hydra), BOL state vs position state:** `select b.state, bp.state, count(*), count(distinct b.id) … group by 1,2` → `CLOSED|CLOSED|756|40`. No mismatch.
- **Q2 (Hydra), totals:** 41 BOLs, all CLOSED (one has no positions). 756 positions. 0 positions with a null BOL.
- **Q3 (Hydra), pallets:** 44 pallet positions and 44 pallets; **0** labels with more than one pallet position.
  - ⚠ My first `at_shipped_loc` count used `name='SHIPPED'` and returned a **false zero**. The constant is `"Shipped"`; Q4 has the correct count.
- **Q4 (Hydra), patterns and locations:**
  - `STRING_PATTERN_OUTBOUND_PALLET = WC_\d{16}|OUT-\d{6}|OUT\d{6}`
  - `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL = AOUT-%1$06d`
  - `pallets: Shipped, lock=405, 44 (AOUT-000001..OUT-999001)`
  - With anchored regex, all 44 labels match an outbound pattern.
  - "43 vs 44": 42 positions are older than one day; the newest was created 2026-09-23 19:38 UTC.
- **Q5 (Hydra), tree integrity:** orphan children 0, children on a different BOL from their carrier 0, level-4 rows 0.
- **Q6 (Hydra):** of 265 labels with a SHIPPING record, **0** have any later record. The positive control shows the codes exist: TRUCKLOADING 270, TRANSFER 98, SHIPPING 265.
- **Q7 (Hydra), foreign keys:** 8 FKs touch `billoflading_position`, all `confdeltype = a` (NO ACTION). That includes `fke0jllerfkjayb6pao7xqfaypy` (position → position, the carrier) and `fkfby2cbs1eg0l2s22i3arb5cut` (position → billoflading). No cascade. In the repo, `on delete cascade` has 3 hits, none on billoflading; those hits are the grep's own positive control.
- **Q8 (Hydra), indexes:** `index_billoflading_position_source_id`, plus indexes on `carrier_id` and `billoflading_id`.
- **Q9 (dev), BOL state vs position state:** CLOSED/CLOSED 1,804,591 on 2,334 BOLs; TRANSFER/TRANSFER 3 on 1; TRUCK_LOADING/TRUCK_LOADING 25 on 4. **0** mismatches.
- **Q10 (dev):** 15,892 pallet positions. Pallets with more than one pallet position: 0. Cross-BOL children: 0. Child state different from parent: 0.
- **Q11 (dev), labels moved after shipping:** 1,448 of 411,895 shipped labels have a later record. **This isn't evidence of loss.**
  - The sample is mostly 2025-04-22 replay data and parcels, and every sampled label still has its CLOSED position.
  - `PM-000764` has a 2026-09-22 TRUCKLOADING record and still has its CLOSED position.
  - I didn't pursue this further. Q6 on PRD is the authoritative measure.