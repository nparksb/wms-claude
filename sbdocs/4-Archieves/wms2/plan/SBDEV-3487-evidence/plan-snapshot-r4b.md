---
title: "Truck loading — a shipped pallet's CLOSED BOL positions deleted by the PHASE D0 purge"
ticket: "SBDEV-3487"
ticket_url: "https://app.clickup.com/t/868m8kx8n"
type: "bugfix"
priority: "high"        # data integrity: irreversible delete of shipping records
status: "pending approval"
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-24"
updated: "2026-09-24"
db_verified: true
tier: "T3"              # data integrity + irreversible delete
mode: "DELIBERATE"      # ralplan round 4
base_commit: "682483fe" # red reproduction IT on top of b950c994 (SBDEV-3474 merge)
related:
  - "[[SBDEV-3418-mobile-truck-loading-transaction-boundary]]"   # §4.2 item 4; §3.2 D0 placement
  - "[[SBDEV-3474]]"      # facade-guard precedent + the @MockitoBean trap
  - "[[SBDEV-3244]]"      # first-touch rule
  - "[[SBDEV-3490]]"      # selectDestination can move a shipped unitload out of Shipped (separate ticket)
evidence: "SBDEV-3487-evidence/analysis.md"
tags: [plan, wms2, truck-loading, data-integrity]
---

# SBDEV-3487: a shipped pallet's CLOSED BOL positions deleted by the PHASE D0 purge

**Ticket:** [SBDEV-3487](https://app.clickup.com/t/868m8kx8n) | wms2 | v2 | bugfix | **T3** | pending approval | 2026-09-24

## 0. Affected sites

Enumerated in analysis §0 (I1–I5: a `git grep` of each repository method and D0 variant, a delete-pattern grep, a
repository-holder grep, a finder grep, and a DB FK-action query). Blind spots: native SQL built as strings,
repository variables with non-matching names, reflection, and direct DB edits.

| # | Site | Deletes CLOSED today? | Disposition |
|---|---|---|---|
| R1 | `findBolIdByUnitLoadLabelId` → `Long` (label-only) | selects it | Untouched (SBDEV-3418 §4.2(2), 0 exposure) |
| R2 | `findBolCarrierIdListByUnitLoadLabelId` (scalar subquery UNION ALL) | selects it | Untouched, same reason |
| R3 | `deleteBolPositionByIdNoClear` `"… WHERE bp.id = :bolPositionId"` (`flushAutomatically`) | **yes** | Fix D predicate + `int` return |
| R4 | `deleteBolPositionsCarrierIdsNoClear` `"… WHERE bp.carrierId IN :carrierIds"` | **yes** | Fix D predicate |
| R5 | `deleteBolPositionById` (`clearAutomatically = true`) | **yes** | Fix D predicate + `int` return |
| R6 | `deleteBolPositionsCarrierIds` (`clearAutomatically = true`) | **yes** | Fix D predicate |
| V1 | `MobileMoveUnitloadService.handleTruckOffLoadingNoClear` → R1, R2, R4, R3 | **yes (reproduced, `682483fe`)** | Fix B |
| V2 | `MobileMoveUnitloadService.handleTruckOffLoading` → R1, R2, R6, R5 | yes (code reading) | Fix C |
| C1 | `MobileTruckLoadingWriteService.scanGate` D0: only caller of V1 | yes | Fix A (facade) + Fix B |
| C2 | `MobileMoveUnitloadService.scanDestination`, non-flowbin arm: `transferUnitLoadToLocation(...); handleTruckOffLoading(dto.getUnitLoadLabel());`. Only caller of V2 | yes (analysis §2; AC-6 red first) | Fix C |

Excluded, with reasons in analysis §0: D1 (closeBOL garbage delete, null-source rows only), D2 (`removeBOLPositionIfExists`
already throws on CLOSED), D3 (`deleteBolByBolNumber`: 0 callers, not routed), S1 (`checkPallet`, the reference whose
key and CLOSED-only rule Fix A mirrors), S2 (PHASE C checks the **target** BOL only; this is the gap), S3/S4 (parcel-carrier
or any-state predicates, no-ops for a pallet source). Spring Data REST cannot route R3–R6 (`exported = false`).

## 1. Problem statement

`POST /v3/truckLoading/scanGate` for a pallet whose BOL is already **CLOSED** runs PHASE D0. D0 deletes the pallet's
`billoflading_position` rows **matched by label alone, with no BOL or state filter**, and PHASE D then builds a new tree
on the target BOL. The shipping record is destroyed in one committed transaction. The handheld UI never hits this,
because `/scanPallet` (`checkPallet`) rejects the pallet first; a direct `/scanGate` call skips that step (the SBDEV-3474 pattern).
By code reading, `POST /v3/moveUnitload/selectDestination` reaches the same loss and also moves the pallet out of Shipped.

**Reproduction (red at `682483fe`):** `MobileTruckLoadingClosedBolPurgeIT.scanGateMustNotDeleteAShippedPalletsClosedBolPositions`.

**DB (read-only, full queries in analysis §8):**
- Hydra PRD (the only v2 PRD client): position state equals BOL state, with 0 mismatches over 756 CLOSED positions on 40 BOLs. There are 8 FKs on `billoflading_position`, all NO ACTION. Tree integrity is intact, so **no loss has occurred yet**.
- Hydra PRD today: 265 unitloads on Shipped, 44 of them top-level. All 44 carry outbound labels with `entity_lock=405` and 0 non-outbound top-level, so **44 pallets are one direct API call from losing their shipping record**.
- dev `dev_wh01_om1`: 0 state mismatches over 1.8M CLOSED, 3 TRANSFER and 25 TRUCK_LOADING positions.

## 2. Root cause

**Bug 1: `scanGate` never checks the pallet's own position state (C1 → V1).** `checkPallet` is the only such check (I4)
and it runs only behind `/scanPallet`. `MobileTruckLoadingService.scanGate` runs only `requireOutboundPalletLabel`, and PHASE C
checks the target BOL (`switch (bol.getState())`). Inside V1's `if (matches)`, nothing between the label match and R4/R3 reads `bp.state`.

**Bug 2: R3–R6 have no state predicate.** They delete whatever id they are handed.

**Bug 3: `scanDestination` reaches V2 for a shipped pallet (C2 → V2), code reading only.** `scanUnitLoad` rejects a
Shipped source. `scanDestination` checks only the destination (`if (shipped.equals(destinationStorageLocation))`),
`assertSourceCarrierNotOnTruck` is a no-op for a pallet (`carrierId == null`), and `transferUnitLoadToLocation(..., false, …)`
checks only the destination's lock. V2 then deletes the CLOSED tree and the move out of Shipped commits. Unproven until AC-6 runs red.

### 2.1 Races (why the backstop sits in D0, and what actually protects each path)

- **closeBOL vs V1 (scanGate).** `scanGate` holds the pallet row from B2 (`findByLabelidForUpdate`) to commit.
  `closeBOL` locks the pallet with its bulk `UPDATE Unitload … version = version + 1` (`BillofladingService:664-671`) **before** it writes CLOSED to the positions.
  - The unitload step is **measured** (`ClosebolLockOrderProbeIT`).
  - The position flush at `:696` is placed **by code reading**. The probe asserts unitload against customerorder only.
  - Conclusion: the backstop, which runs after B2, cannot be overtaken by `closeBOL`. The facade, which runs before B1, can.
- **closeBOL vs C2 (selectDestination).** Derived from the code, not measured.
  - `processTransfer` dirties the managed pallet (`setStoragelocationId`, `UnitloadBusinessService:526-527`). `Unitload` carries `@Version` (`AbstractBaseEntity:34`).
  - The pallet UPDATE is flushed twice before the backstop reads:
    - `processTransfer` runs the JPQL `findByCarrierunitloadId` on `Unitload` (`:544`), which AUTO-flushes the dirty row.
    - The backstop's native query flushes too: Hibernate 6.6 `NativeQueryImpl.shouldFlush()` under a JPA bootstrap (`TenantDatabaseConfig:70`).
  - Two outcomes follow:
    - If C2's UPDATE goes first, `closeBOL` blocks on the pallet row. After C2 commits, closeBOL's version-checked position flush fails and closeBOL rolls back (unchanged today).
    - If `closeBOL` commits first, C2's UPDATE fails its `@Version` check and the whole move rolls back.
  - No interleaving commits a CLOSED delete, so the risk "a C2 race leaves the pallet moved out of Shipped" is **unreachable**. AC-10 measures the flush.
- **finishTransfer vs V1/C2.** It takes the BOL `FOR UPDATE` (`:1485`), then **immediately** bulk-updates positions to CLOSED (`:1511-1516`), then updates Unitload (`:1590-1597`). That is positions before unitload, the reverse of both callers.
  - On a TRANSFER pallet (re-scannable per decision 2):
    1. The backstop reads the committed TRANSFER and passes.
    2. R4/R6 wait on FT's position locks.
    3. FT waits on the pallet row.
    4. PG raises `40P01` and aborts one side.
  - Neither abort deletes CLOSED: if FT is the victim the rows stay TRANSFER and are purged legitimately, and if the scan is the victim nothing is written.
  - Safety here comes from **deadlock detection, not from the backstop or Fix D**. On scanGate, the facade maps the lock exception to the lock-contention response. This mapping is code-read (it is a `PessimisticLockingFailureException` subtype); the fix adds no lock, so it adds no deadlock.

## 2.5 RALPLAN-DR (mode: DELIBERATE)

**Principles:** P1 no lock before a rejection (SBDEV-3474) · P2 scalar reads only in the write tx (first-touch, SBDEV-3244) ·
P3 test-lane honesty: no guard on a mocked bean · P4 invariant over instance: the delete itself refuses CLOSED · P5 fail loud, not silent.
**Drivers:** D1 no committed CLOSED delete in any interleaving · D2 both D0 callers covered · D3 each layer attributable in the real IT lane.

| Option | One line | Verdict |
|---|---|---|
| **A1** | Facade + throwing backstop in V1/V2 + predicate on R3–R6 + loud 0-row re-check | **Chosen** |
| A2 | Facade + backstop, no predicate | Viable and race-free today (§2.1). Rejected: R3–R6 stay unconditional deletes of shipping records for any future caller, and C2 would rest on two Hibernate flush behaviours with R5/R6's `clearAutomatically` as the failure mode (§5.5) |
| B | Backstop that skips instead of throwing | Violates decision 1; PHASE D builds a second tree, putting the pallet on two BOLs |
| C / D | Backstop only / facade only | Violate decision 3; D is racy (§2.1) |
| E | Filter R1/R2 by state | Silent check-then-act; touches ring-fenced finders |
| F | Guard on `OutboundPalletLabelGuard` | `@MockitoBean` in `AbstractTruckLoadingPgFixture:152` and `MobileTruckLoadingRollbackIT:152`: a silent no-op in ITs |
| G | Copy `checkPallet` into the tx | Loads `BillofladingPosition` entities (stale after the NoClear delete), `billofladingRepository.findById` = lock upgrade on B1's target |
| 0-row: skip / throw / **re-check** | See §5.5 | Re-check chosen |

## 3. Scope

**In:** Fixes A–E, covering C1 and C2 (decision 3). **Out, recorded:**
- Three definitions of "shipped": `checkPallet` CLOSED; `assertParcelCarrierNotShipped` CLOSED|TRANSFER; `removeBOLPositionIfExists` CLOSED. This plan uses CLOSED only (decision 2).
- D0 placement (SBDEV-3418 §3.2), R1/R2 non-uniqueness (SBDEV-3418 §4.2(2)).
- The key `billOfLadingPositionUnxepectedStateFound` exists only in `messages_en_US.properties:331` (a pre-existing gap shared with `checkPallet`).

**3.3 SBDEV-3490 (separate ticket, not folded in):** [Move unitload: a direct selectDestination call can move a shipped unitload out of the Shipped location](https://app.clickup.com/t/868m8t1ag).
Its source-is-Shipped check in `scanDestination` runs **before** `transferUnitLoadToLocation` and does not depend on the label or the sysprops.
- **Coupling:** if SBDEV-3490 lands first, AC-6a is rejected earlier with SBDEV-3490's message, and Fix C becomes a pure backstop for Shipped-source moves.
- AC-6a then gets adapted, not deleted: assert "positions intact + pallet on Shipped", with whichever key lands.
- AC-6b (pallet not on Shipped) is unaffected. It stays Fix C's own IT.
- Whoever merges second reconciles AC-6a.

## 4. Architecture

```
POST /v3/truckLoading/scanGate
  MobileTruckLoadingService.scanGate                 (not @Transactional; OSIV off)
    ├─ outboundPalletLabelGuard.requireOutboundPalletLabel(label)          SBDEV-3474
    ├─ billofladingPositionService.assertPalletNotShipped(label, SCAN_GATE_FACADE)  ← Fix A (no lock; racy)
    └─ MobileTruckLoadingWriteService.scanGate   @Transactional(tenantTransactionManager)
         A → B1 BOL(target) FOR UPDATE → B2 pallet FOR UPDATE → B3..B6 → C
         D0 handleTruckOffLoadingNoClear(label)  throws BusinessException
              if (matches) { assertPalletNotShipped(label, SCAN_GATE_D0)  ← Fix B (after B2)
                             R1, R2, R4*, n=R3*; n==0 → re-check (…_RECHECK) }   ← Fix D (* predicate)
         D writes
POST /v3/moveUnitload/selectDestination
  MobileMoveUnitloadService.scanDestination   @Transactional(tenantTransactionManager, rollbackFor=BusinessException…)
    transferUnitLoadToLocation(...)   ← pallet UPDATE flushed here (§2.1)
    handleTruckOffLoading(label)  throws BusinessException
         if (matches) { assertPalletNotShipped(label, MOVE_UNITLOAD_D0)  ← Fix C (throw ⇒ move rolls back)
                        R1, R2, R6*, n=R5*; n==0 → re-check }
```

## 5. Fix design

**5.1 Prerequisites:** none. No schema, sysprop, config, deploy-order, data-repair, external-system or permission change. The worktree freshness check is Step 1.

### 5.2 Fix A: facade guard + the shared assertion

`MobileTruckLoadingService.scanGate`, directly after `requireOutboundPalletLabel(...)` and **outside** the lock-failure `try`:
```java
// SBDEV-3487: a pallet with a CLOSED position is shipped; reject before the write service locks anything
// (checkPallet's key). Racy against closeBOL by construction; the guarantee is the D0 backstop after B2.
billofladingPositionService.assertPalletNotShipped(dto.getPalletName(), ShippedGuardSite.SCAN_GATE_FACADE);
```
`MobileTruckLoadingService` gains a constructor parameter `BillofladingPositionService`. Hand-built sites: `MobileTruckLoadingServiceUnitTest:85` and `MobileTruckLoadingServiceTest:71`. There is no cycle: the service depends on `ClientService`, the repository, `BasicService` and `UnitloadRepository` only.

`BillofladingPositionService` (next to `assertPalletNotAssignedToGate`). It is already injected into `MobileMoveUnitloadService`, and no IT mocks it (grep of `src/test`):
```java
public enum ShippedGuardSite { SCAN_GATE_FACADE, SCAN_GATE_D0, SCAN_GATE_D0_RECHECK, MOVE_UNITLOAD_D0, MOVE_UNITLOAD_D0_RECHECK }

/** SBDEV-3487: reject a pallet already shipped on a CLOSED BOL (CLOSED only; TRANSFER stays re-scannable, as checkPallet).
 *  SCALAR query: loads no BillofladingPosition, so it is safe inside D0's bulk-delete boundary. The site tag is what
 *  tells the facade from the backstop in logs and in the ITs — do not drop it. */
public void assertPalletNotShipped(String palletLabel, ShippedGuardSite site) throws BusinessException {
    if (palletLabel == null) return;
    String closedBolName = billofladingPositionRepository.findClosedBolNameBySourceUnitLoadLabel(palletLabel);
    if (closedBolName != null) {
        LOG.warn("SBDEV-3487 shipped-pallet guard [{}]: pallet {} is already shipped on CLOSED BOL {}", site, palletLabel, closedBolName);
        throw new BusinessException("billOfLadingPositionUnxepectedStateFound", palletLabel, closedBolName);
    }
}
```
New finder (`BillofladingPositionRepository`):
```java
@RestResource(exported = false)
@Query(value = "select coalesce(b.name, bp.number) from billoflading_position bp join unitload u on u.id = bp.source_id "
        + "left join billoflading b on b.id = bp.billoflading_id "
        + "where u.labelid = :unitLoadLabelId and bp.state = 'CLOSED' order by bp.id limit 1", nativeQuery = true)
String findClosedBolNameBySourceUnitLoadLabel(@Param("unitLoadLabelId") String unitLoadLabelId);
```
It selects the same rows as `checkPallet`'s `getBySourceUnitLoadLabelId`. `coalesce` reproduces its `getName()`-else-`getNumber()` argument; it differs only when the name is null, which is cosmetic.
Keying on `bp.state` alone is enough because position state equals BOL state (0 mismatches), and Fix D protects the child rows independently.

### 5.3 Fix B: V1 backstop (`handleTruckOffLoadingNoClear`)
**Signature becomes `public void handleTruckOffLoadingNoClear(String) throws BusinessException`.** Both callers already declare it and roll back for it
(`MobileTruckLoadingWriteService:249-251`). **Do not wrap it in a RuntimeException and do not use `@SneakyThrows`.** Either would turn the rejection into a 500 and break every `getKey()` AC.
```java
if (matches) {
    // SBDEV-3487 backstop — the guarantee on the scanGate path. A CLOSED position is a shipping record.
    // Runs after B2's pallet lock; closeBOL locks the pallet before it writes CLOSED (per ClosebolLockOrderProbeIT
    // for the unitload step; position flush placement by code reading), so closeBOL cannot overtake this read.
    // finishTransfer writes positions first and deadlocks instead (40P01); neither victim deletes CLOSED.
    billofladingPositionService.assertPalletNotShipped(unitLoadLabel, ShippedGuardSite.SCAN_GATE_D0);
    Long bolPositionId = billofladingPositionRepository.findBolIdByUnitLoadLabelId(unitLoadLabel);
```
- It sits inside `if (matches)`, so the pattern-miss and not-configured exits are unchanged (AC-5).
- It sits before R1, because R1 throws `IncorrectResultSize` on more than one row.
- It is an unlocked indexed SELECT, not `FOR UPDATE`. Nothing is dirty before D0, so its auto-flush does nothing and the table order is unchanged.

### 5.4 Fix C: V2 backstop (`handleTruckOffLoading`)
The same signature change (`throws BusinessException`, no wrapping) and the same call at the same seat, with `MOVE_UNITLOAD_D0`. It runs
**after** `transferUnitLoadToLocation`, so its throw is what rolls back the move out of Shipped (`rollbackFor = {BusinessException…}` at `:287`).
Both variants stay duplicated, per the existing javadoc ("Deliberately NOT refactored into a shared private helper taking a flag").

### 5.5 Fix D: predicate on R3–R6 and a loud 0-row result
```java
@Query("DELETE FROM BillofladingPosition bp WHERE bp.id = :bolPositionId"
        + " AND (bp.state IS NULL OR bp.state <> 'CLOSED')")   // SBDEV-3487: a CLOSED row is a shipping record
int deleteBolPositionByIdNoClear(...);   // R5 likewise returns int; R4/R6 get the predicate, stay void
```
In both variants, after the pallet-row delete (shown for V1; **V2 passes `MOVE_UNITLOAD_D0_RECHECK`** and calls R5):
```java
int deleted = billofladingPositionRepository.deleteBolPositionByIdNoClear(bolPositionId);
if (deleted == 0) {   // R1 saw the row; the delete removed nothing: it is CLOSED now, or a concurrent purge took it
    billofladingPositionService.assertPalletNotShipped(unitLoadLabel, ShippedGuardSite.SCAN_GATE_D0_RECHECK);
    LOG.warn("SBDEV-3487: pallet position {} for {} was already gone at delete time", bolPositionId, unitLoadLabel);
}
```
- **Why Fix D.** It is **not** what saves C2 for today's callers; C2 is race-free by §2.1. It covers two things:
  - **Future callers of R3–R6** that hold no pallet lock. Under READ COMMITTED a DELETE that waited on a row lock re-evaluates its WHERE against the committed row, so the predicate holds whatever the caller locked.
  - **A change in flush order.** R5/R6 are `clearAutomatically = true` with no `flushAutomatically`. If the pallet UPDATE were ever **not** flushed before R6, `clear()` would discard it along with its `@Version` check, and without Fix D the CLOSED rows would be deleted and committed. Two independent flushes prevent this today (§2.1), but both are Hibernate behaviours, not something the code states.
- **Why a re-check, not a plain throw or a skip.**
  - A plain throw needs a key; the re-check produces the correct one when the row is CLOSED.
  - It also tells a CLOSED row apart from a row a lockless concurrent purge already removed. The second case is the purge's intended outcome, so a WARN is enough.
  - A skip is silent, which violates P5.
  - Under READ COMMITTED the re-check's new statement sees what the waiting DELETE saw.
  - The path is unreachable for today's callers (V1 holds B2, and C2's pallet row is locked by its flushed UPDATE). It exists for future callers, and AC-11 pins it.
- **The `IS NULL` arm is required.** `state` is nullable (`V2.2.00:695`), and `NULL <> 'CLOSED'` is unknown, so without the arm null-state rows would stop being purged. The measurements found no null group; AC-9 pins the arm.
- **Mixed tree (children CLOSED, pallet not).** R4/R6 skip the children, the pallet delete then violates the NO ACTION position→position FK, and PG raises `23503` at the end of the statement. This surfaces as `DataIntegrityViolationException`, which the facade's `PessimisticLockingFailureException` catch does not catch, so the result is **a 500 and a full rollback**. This is **intended**: such a tree contradicts the measured invariant (0 mismatches), and refusing loudly beats partially deleting a shipping record. The reverse mix never reaches the deletes, because the backstop throws first.
- **Literal `'CLOSED'`.** There is no JPQL state-literal precedent (`git grep "'CLOSED'" src/main/java` → 0). The value is `WmsConstants.BillOfLadingState.CLOSED` (`:261`), and AC-9 pins it by behaviour.

### 5.6 Fix E: docs and comments

| File | Change |
|---|---|
| `sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md` | **(1)** "`handleTruckOffLoading()` when the **destination** label matches the outbound-pallet regex" is false: the code tests the **source** label. The claim appears in **four** places: line 42 (overview), the flow box ("Destination matches outbound-pallet regex?"), Landmine 3, and the symptom row "destination label didn't match outbound regex". Fix all four. **(2)** Make explicit that the Shipped-**source** check exists only in `scanUnitLoad`, and that `scanDestination` checks only the destination (the flow box and the "`Can not move from shipped` \| 144" row). Link SBDEV-3490. **(3)** Landmine 4: "SBDEV-3487: throws `billOfLadingPositionUnxepectedStateFound` when the label has a CLOSED position; R3–R6 never delete CLOSED rows." Bump `last_verified`. |
| `sbdocs/3-Resources/workflows/wms2-bol-truck-loading-workflow.md` | D0 row: "Throws `billOfLadingPositionUnxepectedStateFound` on a CLOSED position (SBDEV-3487 backstop; the facade rejects the same case before B1). TRANSFER positions are still purged." Bump `last_verified`. |
| `MobileTruckLoadingWriteService` D0 comment | One line naming the backstop and why it lives after B2. |
| `BillofladingPositionService.assertParcelCarrierNotOnTruck` javadoc | "A pallet loses its positions when moved off the truck" → add "unless they are CLOSED (SBDEV-3487)". |
| `BillofladingPositionRepository` R3/R5 javadoc | The predicate's purpose and the `int` contract, stated once; the siblings reference it. |

### 5.7 File changes

| File | Change |
|---|---|
| `repo/jpa/BillofladingPositionRepository.java` | +finder; predicate on R3–R6; R3/R5 `void`→`int`; javadoc |
| `service/BillofladingPositionService.java` | +`ShippedGuardSite`, +`assertPalletNotShipped` |
| `service/mobile/MobileTruckLoadingService.java` | +ctor param/field, +1 call |
| `service/mobile/MobileMoveUnitloadService.java` | V1/V2: `throws BusinessException`, backstop, 0-row re-check |
| `service/mobile/MobileTruckLoadingWriteService.java` | comment |
| `test/.../MobileTruckLoadingWriteServiceUnitTest.java` | `assertNothingWasWritten()` (`:124`) gains `throws BusinessException` (**compile break otherwise**) |
| `test/.../MobileMoveUnitloadServiceUnitTest.java` | happy path `shouldDeleteBolPositionsWhenLabelMatchesPattern` (`:550`, V2 only): stub **only R5** `thenReturn(1)` (stubbing R3 = `UnnecessaryStubbingException`), add `verify(bps, never()).assertPalletNotShipped(any(), eq(MOVE_UNITLOAD_D0_RECHECK))`; new `@Nested` for AC-3u/4/5/11 |
| `test/.../MobileTruckLoadingServiceTest.java` | `@Mock BillofladingPositionService` ctor arg; AC-2 |
| `test/.../MobileTruckLoadingServiceUnitTest.java` | `@Mock BillofladingPositionService` ctor arg only |
| `test/.../BillofladingPositionServiceUnitTest.java` | `@Nested AssertPalletNotShipped` (AC-8) |
| `test/.../AbstractTruckLoadingPgFixture.java` | **`closeBolAsShipped(Long)` moved up from `MobileTruckLoadingClosedBolPurgeIT` as `protected`, body unchanged.** Its `tx()` wrapper gives no atomicity: `jdbcTemplate` autocommits on its own DataSource. Callers' preconditions catch a partial write |
| `test/.../MobileTruckLoadingClosedBolPurgeIT.java` | reorder AC-1; AC-3 IT (`BOUT-948703`), AC-7 (`BOUT-948704`), AC-9; add both labels to its `purgeByPrefix` label list. ⚠ That override builds the list **twice** (two separate `List.of(...)` literals, one per loop): replace both with one `FIXED_PALLET_LABELS` constant so a label cannot land in only one loop (today only 948701/948702); drop the private `closeBolAsShipped` (now inherited) |
| `test/.../MobileMoveUnitloadClosedBolPurgeIT.java` (new, `extends AbstractTruckLoadingPgFixture`) | AC-6a/b, AC-10; `purgeByPrefix` override (§6.1) |
| 2 workflow docs | Fix E |

### 5.8 Steps (test-first)
1. **Freshness and baseline.** `git fetch && git log HEAD..origin/develop -- src/main/java/net/aim_ai/wms/service/mobile src/main/java/net/aim_ai/wms/repo/jpa/BillofladingPositionRepository.java src/main/java/net/aim_ai/wms/service/BillofladingPositionService.java` must be empty; otherwise rebase. Run `pgrep -f maven` (must be empty), then the full `mvn verify` baseline adjacent in time. Record failures and errors, not totals.
2. **Write every test in §6 before any behavioural `src/main` edit.** First make these compile-only changes:
   - `ShippedGuardSite` enum.
   - `assertPalletNotShipped` with an **empty body**.
   - The finder declared **with its final `@Query`**. A bare declaration would fail derived-query parsing at context load.
   - `MobileTruckLoadingService` ctor param and field, with no call.
   - `throws BusinessException` on V1 and V2.
   - R3/R5 return `int`, with **no predicate**.
   - The §5.7 test-file fixes: the `:124` `throws`, the two ctor-arg `@Mock`s, the R5-only stub, and moving `closeBolAsShipped` up to the base class.
   
   After that, every red is behavioural. Required red reasons:
   - AC-1, AC-3 IT, AC-6a, AC-6b: the **positions-deleted** data assertion (all use `catchThrowable` first).
   - AC-9: CLOSED rows deleted.
   - Unit tests: `verify`/`never()` or the missing throw.
   - ⚠ **STOP rule: classify the throwable before concluding anything.** This is the first PG-lane run of `scanDestination` (`git grep "scanDestination(" src/test` finds unit tests only), and `CODE_TRANSFER` takes the BLOCK_REALIGN path (`PickLineActivityCodeClassifier:36`), which this tree has never run. Three buckets, checked in this order:
     - **(1) Disproves analysis §2. This is the ONLY qualifying case.** A pre-fix AC-6a/b red where **all** of the following hold:
       - The throwable is non-null and comes from a guard **whose condition is met by closeBOL's output**: the source's `storagelocation_id` = Shipped, the source's `entity_lock` = 405/`SHIPPED`, or positions in state CLOSED.
       - X's positions are intact.
       - The executor **quotes the guard's condition** (file:line and the boolean expression) in the report. A guard that reads none of those three values cannot disprove §2, whatever it throws.
       
       Then STOP and report: the C2 claim in §1 is withdrawn, and AC-6 becomes a positive control.
     - **(2) Fixture or environment defect. Fix it and re-run; it says nothing about §2:**
       - **Every destination-side guard.** The fixture chose DEST, and the §6.1 DEST preconditions exist to rule these out: `STORAGELOCATION_LOCKED`; the constraint check `MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION`; `CARRIER_NOT_ON_FIXLOC`; `WRONG_ITEMDATA_FIXASSIGNMENT`; "Pallet not empty!"; the nirvana, shipped and damaged destination checks; `isMoveStock`.
       - **Resolution failures:** `scanDestination`'s own `BusinessException` "No unit load found for '…'" (`MobileMoveUnitloadService:304`), `FacadeException("Unitload not found")` (`UnitloadBusinessService:523`), and `ScannedCodeResolver`'s `scanCodeAmbiguous*`.
       - **Any Spring `DataAccessException`:** a lock timeout (for example a concurrent build holding a row; run `pgrep -f maven`), `IncorrectResultSizeDataAccessException` from label residue, `DataIntegrityViolationException`.
       - **NPE and `EntityNotFoundException`**, anywhere on the path, including the realign and sync services.
       - **A failed precondition assertion**, and any failure in `@BeforeEach`, `@AfterEach` or `purgeByPrefix`.
       - **A pre-fix `t == null` with positions intact.** V2 did not reach the delete: its pattern did not match, or R1 missed. Check the label against the seeded sysprops and R1's row.
     - **(3) Anything else: STOP, report the throwable verbatim with its stack, and conclude nothing about §2 or §2.1.**
     - **AC-10a/b red: the same three buckets.** Only a red from the code under test disproves §2.1, and only after the preconditions (pallet and DEST) have passed and no bucket-(2) throwable is involved:
       - **10a:** `scanDestination` returns without a throwable, but the pallet is not on DEST, or its positions remain.
       - **10b:** the in-lambda probe is `null` (the NOWAIT query acquired the row) **and** the positive control returned exactly the pallet id.
       
       Then STOP; Fix D's justification is revisited. A 10b probe that fails with a SQLState other than `55P03`, or a probe throwable that is not an `SQLException`, falls in bucket (3).
   - Commit the reds.
3. **Finder + `assertPalletNotShipped`:** AC-8 goes green.
4. **Fix A:** AC-2 and AC-1 go green.
5. **Fixes B and C:** AC-3, AC-4, AC-5, AC-6a/b go green; AC-7 stays green.
6. **Fix D predicate + re-check:** AC-9 and AC-11 go green. Then Fix E.
7. **Floor:**
   - Mutation-check every row of §6.1 and record each result.
   - Run PIT scoped to `BillofladingPositionService` and `MobileMoveUnitloadService`.
   - Run the full suite against the Step 1 baseline.
   - Run one independent `code-reviewer` lane in its own worktree and fix every finding, including Low.

## 6. Testing

No verify script: every invariant is visible to JUnit or an IT.

**Layer attribution in the ITs.** Without it, the facade, the backstop and the re-check produce identical DB outcomes.
- In `@BeforeEach` (after the context has loaded, because Boot's LoggingSystem resets appenders on context start), attach a logback `ListAppender` to `BillofladingPositionService`'s logger. Detach it in `@AfterEach`.
- Filter events on logger name, level `WARN`, and a message starting with `"SBDEV-3487 shipped-pallet guard"`. The service logs other WARNs (`:89`, `:109`).
- Assert exactly one matching event, with `getArgumentArray()[0] == expectedSite` (enum identity). Do not use a substring match: `SCAN_GATE_D0` is a prefix of `SCAN_GATE_D0_RECHECK`.

### 6.1 Acceptance criteria

**Fixture state for `MobileMoveUnitloadClosedBolPurgeIT` (Architect N1 / Critic H1 / M1).**
- `seedPallet` leaves `entity_lock` NULL (`PgLaneFixtures.unitload` never sets it, and the column has no default), and a scanGate leaves the pallet on the **fixture gate**. After the first scanGate, set the state **via `jdbcTemplate` (it autocommits, on its own DataSource, so there is no atomicity to rely on; the preconditions below catch a partial write)**:
  - **6b, 10a, 10b:** pallet `entity_lock = 0`. The pallet stays on the gate.
  - **6a:** mirror closeBOL `:664-678`. The pallet **and** its child go to `storagelocation_id` = Shipped with `entity_lock` = `BusinessObjectLockState.SHIPPED` (405), and the child's stockunits get `entity_lock` 405. BOL and positions go CLOSED through the inherited `closeBolAsShipped` (§5.7).
- **Preconditions,** asserted before calling the service:
  - **Pallet:** `entity_lock` is not null and equals the value set above. `storagelocation_id` is Shipped (6a) or the gate (6b, 10a, 10b).
  - **DEST** (rules out every destination-side guard in the §5.8 bucket (2)):
    - `select entity_lock, type_id from location where id = DEST` → `0`, `1`.
    - `select count(*) from location_constraint where storagelocationtype_id = 1` → `0`.
    - `select count(*) from fix_location_assignment where assignedlocation_id = DEST` → `0`.
- **Labels:** `BOUT-948710` (6a), `BOUT-948711` (6b), `BOUT-948712` (10a), `BOUT-948713` (10b). `MobileTruckLoadingClosedBolPurgeIT` adds `BOUT-948703` (AC-3 IT) and `BOUT-948704` (AC-7). `git grep 9487 src/test` finds only `948701`/`948702`, so none of the six collide.
- **`purgeByPrefix` override,** mirroring `MobileTruckLoadingClosedBolPurgeIT:143-155`:
  1. Move each fixed-label pallet to `PgLaneFixtures.SEEDED_LOCATION_ID` (id 0, never swept).
  2. Call `super.purgeByPrefix()`.
  3. Delete by exact label: `unitload_record` (`label`/`fromunitload`/`tounitload`) rows, then `unitload` rows.
  
  Use one `FIXED_PALLET_LABELS` constant for both loops (steps 1 and 3), not two list literals.
  
  Without step 1, a pallet left on the prefixed DEST or gate breaks super's location delete on the FK, and the reused container keeps the residue.

| AC | Test | Level | Red pre-fix | Mutation → must turn red |
|---|---|---|---|---|
| AC-1 | `MobileTruckLoadingClosedBolPurgeIT#scanGateMustNotDeleteAShippedPalletsClosedBolPositions`. Order: `Throwable t = catchThrowable(...)`; **then** X's positions `containsExactlyElementsOf(shippedPositions)`, Y empty, pallet `storagelocation_id` unchanged; **then** `t` is a `BusinessException`, `getKey()` = `billOfLadingPositionUnxepectedStateFound`, site `SCAN_GATE_FACADE` | IT (PG) | yes (positions deleted) | Delete Fix A → site becomes `SCAN_GATE_D0` |
| AC-2 | `MobileTruckLoadingServiceTest` (real `OutboundPalletLabelGuard` over `syspropService` stubbed `"WC_\\d{16}\|OUT-\\d{6}\|OUT\\d{6}"` / `"AOUT-%1$06d"`; `@Mock BillofladingPositionService`; existing `@Mock MobileTruckLoadingWriteService`). **(a)** `scanGate_shouldRejectAShippedPalletBeforeTheWriteService`: label `OUT-000001`, `doThrow(new BusinessException(key, label, "BOL-X")).when(bps).assertPalletNotShipped("OUT-000001", SCAN_GATE_FACADE)` → key; `verifyNoInteractions(truckLoadingWriteService, manageOrderService)`. **(b)** Extend `scanGate_shouldRejectANonOutboundLabelBeforeTheWriteService` with `verify(bps, never()).assertPalletNotShipped(any(), any())`. **(c)** Extend `scanGate_shouldDelegateToTheWriteServiceAndMapTheDto` with `verify(bps).assertPalletNotShipped(label, SCAN_GATE_FACADE)` | unit | (a)(c) yes | Delete the call → (a)(c) red; move it after the `try` → (a) red; put it before the label guard → (b) red. *Moving it into the `try` is an **equivalent mutant**: a `BusinessException` is not a `PessimisticLockingFailureException`, so it propagates unchanged* |
| AC-3 | Unit `MobileMoveUnitloadServiceUnitTest.HandleTruckOffLoadingNoClear#closedPositionThrowsAndDeletesNothing` (the service mock throws for `SCAN_GATE_D0`; `never()` on R1–R4). IT `MobileTruckLoadingClosedBolPurgeIT#writeServiceScanGateDirectRejectsShippedPallet`, label **`BOUT-948703`** (added to that class's purge list), calls `MobileTruckLoadingWriteService.scanGate` directly (the ArchUnit rule is `DO_NOT_INCLUDE_TESTS`). Order: `catchThrowable`; **then** X intact, Y empty; **then** key, site `SCAN_GATE_D0` | unit + IT | yes (IT: positions deleted) | Delete Fix B → unit red; IT red on site (`…_RECHECK`) |
| AC-4 | `…HandleTruckOffLoading#closedPositionThrowsAndDeletesNothing`: same, `MOVE_UNITLOAD_D0`, `never()` on R1, R2, R5, R6 | unit | yes | Delete Fix C |
| AC-5 | `…NoClear#patternMissRunsNoPositionQuery`, `#notConfiguredRunsNoPositionQuery`, `…HandleTruckOffLoading#patternMissRunsNoPositionQuery`: `verify(bps, never()).assertPalletNotShipped(any(), any())` | unit | no (placement) | Hoist the backstop above `if (matches)` |
| AC-6a | `MobileMoveUnitloadClosedBolPurgeIT#selectDestinationOfShippedPalletIsRejectedAndRollsBack`: scanGate onto X → 6a fixture state (above) → preconditions (pallet + DEST) → `scanDestination` to **DEST** (`PgLaneFixtures.location(PREFIX+"DEST-"+runKey)`: type 1 `NoRestriction`; not flowbin; not EmptyPallets). Order: `catchThrowable`; **then** X intact, pallet still on Shipped with lock 405; **then** `BusinessException`, key, site `MOVE_UNITLOAD_D0` | IT (PG) | yes (positions deleted) | Delete Fix C → site `…_RECHECK`. **If SBDEV-3490 lands, adapt the key/site assertion (§3.3); keep the data assertions** |
| AC-6b | `#selectDestinationOfNonShippedPalletWithClosedPositionsIsRejected`: scanGate onto X → BOL and positions CLOSED, pallet **stays on the gate** with `entity_lock` set to 0 → preconditions (pallet + DEST) → `scanDestination` to DEST. Same order: X intact, pallet still on the gate; key; site `MOVE_UNITLOAD_D0`. **Javadoc:** neither CLOSED writer leaves a pallet off Shipped (closeBOL `:664-671` and finishTransfer `:1590-1597` both move the whole tree to Shipped with lock 405). This state arises only after a later move that does not purge positions takes the pallet off Shipped. The handheld can reach such a pallet, because `scanUnitLoad` rejects only a Shipped source. It is realistic, and it is the **one case only Fix C protects** (SBDEV-3490 does not), so do not delete it as unrealistic | IT (PG) | yes (positions deleted) | Delete Fix C → site `…_RECHECK` |
| AC-7 | `MobileTruckLoadingClosedBolPurgeIT#transferBolPalletIsStillReScannable`, label **`BOUT-948704`** (added to that class's purge list): close X as TRANSFER, re-scan onto Y → X empty, Y has the tree. `reScanFromAnOpenBolMovesThePallet` stays green | IT (PG) | no | Finder or predicate → `IN ('CLOSED','TRANSFER')` |
| AC-8 | `BillofladingPositionServiceUnitTest.AssertPalletNotShipped`: (a) null finder → no throw, no WARN; (b) `"BOL-X"` → key + args `(label, "BOL-X")`; (c) `verify(repo).findClosedBolNameBySourceUnitLoadLabel(label); verifyNoMoreInteractions(repo)`; (d) reflection: the finder returns `String.class` | unit | new | Swap in the entity finder → (c)/(d) red |
| AC-9 | `MobileTruckLoadingClosedBolPurgeIT#repositoryDeletesNeverRemoveClosedRows`: **one fixture per query**, each row saved through `BillofladingPositionRepository` **without presetting an id** (`AbstractBaseEntity` uses a sequence-generated id with `@Version`, so `save()` persists and assigns it) and with `name = PREFIX + …` (so the sweep removes it); each call inside `tx()`. **R3, R5:** a childless CLOSED row → returns 0, count 1. **R4, R6:** a CLOSED child under parent P, called with `[P]` → child count 1. **Controls:** the same shapes in TRUCK_LOADING are deleted (R3/R5 return 1), plus one null-state childless row deleted by R3 | IT (PG) | yes | Drop the predicate from any one query → the count named for that query fails; drop the `IS NULL` arm → the null-state control fails |
| AC-10 | Measurement for §2.1, in `MobileMoveUnitloadClosedBolPurgeIT`, fixture state lock 0, pallet + DEST preconditions asserted. **(a)** `#truckLoadingPalletMoveReallyRelocates`: a TRUCK_LOADING outbound pallet → `scanDestination` to DEST → `storagelocation_id` = DEST and its positions deleted (an unflushed UPDATE would be discarded by R5/R6's clear). **(b)** `#palletRowIsLockedBeforeTheBackstopReads`. **Everything up to `setRollbackOnly` runs inside one `tx().execute(status -> …)` lambda:** load `pallet` with `unitloadRepository.findById(palletId)`; call `transferUnitLoadToLocation(pallet, DEST, false, CODE_TRANSFER, null, null)`; then, **still inside the lambda**, `Throwable probe = catchThrowable(() -> jdbcTemplate.queryForList("SELECT id FROM unitload WHERE id=? FOR NO KEY UPDATE NOWAIT", Long.class, palletId))` (`jdbcTemplate` is a separate `DriverManagerDataSource` connection that the tenant tx manager does not bind, `PostgresTestSupportConfig:98-105`); then `status.setRollbackOnly()`. **Outside the lambda:** assert `NestedExceptionUtils.getMostSpecificCause(probe)` is an `SQLException` whose `getSQLState()` is `55P03`. Assert the SQLState, not the Spring exception class, whose mapping can change between versions. `NO KEY` avoids a false `55P03` from a future FK's `FOR KEY SHARE`. **Positive control** `#nowaitProbeSeesAnUnlockedPallet`: the same in-lambda shape **without** the transfer; the probe returns exactly `[palletId]` and no throwable, so a 0-row vacuous pass is impossible | IT (PG) | no (green pre-fix; red → the §5.8 classification) | — (instrument) |
| AC-11 | `…NoClear#zeroRowDeleteRechecksAndThrowsWhenClosed` and `…HandleTruckOffLoading#…`: the first `assertPalletNotShipped` passes, R3/R5 → 0, the `…_RECHECK` call throws → key. Plus `#zeroRowDeleteWithRowGoneWarnsAndContinues`: the re-check passes → no throw | unit | yes | Delete the re-check → throw test red |

**Regression:** `MobileTruckLoadingWriteServiceUnitTest`, `MobileTruckLoadingRollbackIT`, `MobilePalletizeRepalletizeIT`,
`MobileMoveUnitloadServiceUnitTest`/`MobileMoveUnitloadServiceTest`, `BillofladingPositionRepositoryTest` (H2),
`TruckLoadingWriteEntryPointArchTest`, then the full `mvn verify` against the baseline.

### 6.2 Manual (dev, after the merge to `develop`; confirm the SHA at `/api/public/version` first)

Both controllers catch `BusinessException` and return **HTTP 200** with `{"errors":[…]}` (`TruckLoadingController:119-133`, `MoveUnitloadController:67-90`).
The message is resolved with `Locale.getDefault()` (`BusinessException:50`), so no request header changes it: expect "Pallet … already part of BOL …" on an en_US JVM and the raw key `billOfLadingPositionUnxepectedStateFound` otherwise.

**Order:** run scenario 1 first. Run scenario 3 **only after** scenario 1 has shown the fix is live, meaning the rejection and a `SCAN_GATE_FACADE` WARN. Without the fix, scenario 3 would move the pallet and its children off Shipped and delete X.

| Scenario | Steps | Expected |
|---|---|---|
| 1. Direct scanGate of a shipped pallet is rejected before any lock | On wms2-wineco-dev (`dev_wh01_om1`), read both outbound sysprops from `los_sysprop`. Pick a pallet: `select u.labelid, bp.billoflading_id from billoflading_position bp join unitload u on u.id=bp.source_id where bp.state='CLOSED' and u.labelid ~ '^(<pattern>)$' limit 1` (**anchored**: `~` matches substrings, Java `matches()` the whole string). **Snapshot** X's position rows (`select * from billoflading_position where billoflading_id = X`) **and the `unitload` rows of the pallet and its children** (`select * from unitload where labelid = <pallet> or carrierunitload_id = <pallet id>`) in case the deployed SHA lacks the fix. Pick an OPEN/TRUCK_LOADING BOL Y and its gate. Before and after, record `xmax` of Y's `billoflading` row and the pallet's `unitload` row, plus X's position count. Then `POST /v3/truckLoading/scanGate` | HTTP 200, `errors[0]` holds the message or key; **xmax unchanged on both rows** (a `FOR UPDATE` stamps xmax even on rollback); X unchanged; Y gains nothing; WARN site `SCAN_GATE_FACADE` |
| 2. Control: a TRUCK_LOADING or TRANSFER pallet still moves | Re-scan onto another BOL | 200 with no `errors`; old tree purged, new tree on the target |
| 3. selectDestination of a shipped pallet (**only after scenario 1 passes**) | Take fresh snapshots as in scenario 1 (positions plus the pallet's and children's `unitload` rows). `POST /v3/moveUnitload/selectDestination` to an ordinary location | HTTP 200, `errors[0]` holds the same message or key (success would be the body `true`); pallet and children still on Shipped, lock 405; positions intact |
| 4. Handheld happy path | scanPallet → scanGate for a fresh outbound pallet | Unchanged |

If the deployed SHA turns out to lack the fix and X was purged or the tree moved, restore the positions and `unitload` rows from the snapshots and report.

## 7. Horizontal scalability
No in-JVM state, cache, async boundary or new lock. The change adds one indexed scalar SELECT (`index_billoflading_position_source_id`) per scan inside the existing boundaries; the facade read uses its own short EntityManager before the write tx opens.

## 8. Risks, observability, pre-mortem

| # | Risk | Mitigation |
|---|---|---|
| R1 | A legitimate workflow re-loads or moves a pallet with a CLOSED position | Hydra: 0 labels with any record after SHIPPING; 0 state mismatches. The only **bulk** writer of position state is `finishTransfer` (`BillofladingService:1512`, grep `UPDATE BillofladingPosition` in `src/main`), and it writes CLOSED. Entity-level writers were not enumerated. The rejection names the BOL, and the WARN quantifies it. |
| R3 | The key renders raw on a non-`en_US` JVM locale | Pre-existing, shared with `checkPallet`; tests assert `getKey()` only. |
| R4 | Signature ripple (the ctor param, two `throws` clauses, R3/R5 `int`) | Every affected test is listed in §5.7 and fixed in Step 2; wrapping is forbidden (§5.3). |
| R5 | closeBOL racing a scanGate that won the pallet lock 409s | Unchanged from today (analysis §5). No new lock, no order change. |
| R6 | First PG-lane run of `scanDestination` + BLOCK_REALIGN surfaces fixture gaps | The §5.8 three-bucket classification (disproof only from a guard met by closeBOL's output, with the condition quoted) routes them to fixture repair or a neutral STOP, never to a design conclusion; the DEST preconditions rule out destination-side guards up front. |

**Observability:** the WARN `SBDEV-3487 shipped-pallet guard [<site>]` fires at every rejection.
- `SCAN_GATE_D0`: the scanGate backstop fired after the facade passed (the closeBOL race), or someone called the write service directly.
- `MOVE_UNITLOAD_D0` (selectDestination only): either a direct `selectDestination` call for a shipped pallet, **or** a handheld move of a pallet that is not on Shipped but has CLOSED positions (`scanUnitLoad` rejects only a Shipped source). The second case points to data drift upstream: investigate how the pallet left Shipped.
- Any `…_RECHECK` line means a future-caller or flush-order problem: escalate.
- After the PRD release, re-run Hydra Q3/Q5/Q6 (every pallet with a CLOSED position keeps its full tree; 0 labels with a record after SHIPPING) and record the result on the ticket.
- Watch WARN volume for a week. There is no metric, because nothing scrapes wms2 Prometheus.

**Pre-mortem:**
1. **SBDEV-3490 lands and intercepts AC-6.** AC-6a goes red with a different message, someone deletes it, and Fix C is left with no IT coverage. **Mitigation:** AC-6b does not depend on Shipped, so SBDEV-3490 cannot intercept it, and its javadoc says why the state is realistic. AC-6a's javadoc names the coupling and says "adapt the key, keep the data assertions" (§3.3).
2. **The backstop is deleted as dead code.** In production only `SCAN_GATE_FACADE` WARNs ever appear, because the race is rare, so a cleanup removes Fixes B and C as "never fires". **Mitigation:** AC-3 IT and AC-6b are cases where the backstop is the **only** protection (a direct write-service call, and a C2 source that is not on Shipped), and both assert the site. The javadoc on each layer names its job: facade = no-lock rejection; backstop = the guarantee after the pallet lock; predicate + re-check = protection for future callers.
3. **It blocks a real operation on PRD.** Hydra may have a practice that 30 days of data does not show, for example re-shipping a pallet whose BOL was closed in error. **Mitigation:** the rejection names the BOL, and the WARN plus the re-query detect it within days. The remedy is a data correction to the BOL, not a code rollback, because deleting a CLOSED record is what this fix exists to prevent. Escalate to Nam on a non-zero rate.

## 9. ADR
- **Decision:** reject shipped (CLOSED) pallets at three layers, all through one scalar `BillofladingPositionService.assertPalletNotShipped` with a site tag:
  - a no-lock facade guard in `MobileTruckLoadingService.scanGate`;
  - a throwing backstop inside both D0 variants;
  - a `(state IS NULL OR state <> 'CLOSED')` predicate on R3–R6, where a 0-row pallet delete re-runs the assertion.
- **Drivers:** D1–D3 (§2.5).
- **Alternatives considered:** §2.5 (A2, B–G, and the 0-row options).
- **Why chosen:**
  - The facade gives a rejection with no lock (P1).
  - The backstop is the guarantee on scanGate, because it runs after B2 and closeBOL locks the pallet first (measured for unitload, code-read for positions).
  - `finishTransfer` resolves by `40P01` without a CLOSED delete.
  - C2 is race-free through its flushed, version-checked pallet UPDATE (derived; AC-10 measures it).
  - Fix D makes "never deletes CLOSED" true for future callers and for a flush-order change under `clearAutomatically`, at the cost of four one-clause edits.
  - Only a throw rolls back C2's move out of Shipped.
- **Decisions:**
  1. Reject before any lock, with `billOfLadingPositionUnxepectedStateFound` (Nam).
  2. CLOSED only; TRANSFER stays re-scannable (Nam).
  3. Facade + backstop in both D0 variants (Nam).
  4. The backstop throws, placed inside `if (matches)` before R1 (planner).
  5. Fix D adopted, with an `int` return + re-check on 0 rows (planner, §5.5).
  6. Guard home is `BillofladingPositionService`, not `OutboundPalletLabelGuard` (planner).
  7. No PHASE A re-check, D0 not moved, R1/R2 untouched (planner).
  8. No verify script, no metric (planner).
  9. The §3.3 finding is SBDEV-3490, not folded in (Nam).
- **Consequences:**
  - One extra indexed SELECT per scan.
  - `/scanGate` and `/selectDestination` now return a new rejection for CLOSED pallets: **HTTP 200 with an `errors` entry** (the controllers' existing `BusinessException` contract), not a 4xx. The message follows the server JVM's default locale.
  - Three signature changes (the ctor, two `throws`, R3/R5 `int`).
  - A mixed-state tree now fails as a 500 with a full rollback (intended).
  - The three definitions of "shipped" remain inconsistent.
- **Follow-ups:**
  - (a) SBDEV-3490 lands; whoever merges second reconciles AC-6a.
  - (b) Extend `ClosebolLockOrderProbeIT` to record `billoflading_position` lock acquisitions, turning the code-read position placement into a measurement.
  - (c) Reconcile the three definitions of "shipped" if a ticket is opened.
  - (d) Add the key to base `messages.properties`.
  - (e) Run the post-release Hydra re-query and record it on the ticket.
