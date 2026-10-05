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
tier: "T3"              # data integrity + irreversible delete of shipping records
base_commit: "682483fe" # red reproduction IT on top of b950c994 (SBDEV-3474 merge)
related:
  - "[[SBDEV-3418-mobile-truck-loading-transaction-boundary]]"   # §4.2 item 4 proposed this fix; §3.2 D0 placement
  - "[[SBDEV-3474]]"      # facade-guard precedent + the @MockitoBean trap
  - "[[SBDEV-3244]]"      # first-touch rule
  - "[[SBDEV-3442]]"      # scanDestination work (candidate home for the §3.3 proposal)
evidence: "SBDEV-3487-evidence/analysis.md"
tags:
  - plan
  - wms2
  - truck-loading
  - data-integrity
---

# SBDEV-3487 — a shipped pallet's CLOSED BOL positions deleted by the PHASE D0 purge

**Ticket:** [SBDEV-3487](https://app.clickup.com/t/868m8kx8n)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix | **Tier:** T3
**Status:** pending approval | **Date:** 2026-09-24

---

## 0. Affected sites

Enumerated by analysis §0 (I1–I5: `git grep` of each repository method and D0 variant, a delete-pattern
grep, a repository-holder grep, a finder grep, and a DB FK-action query). What those instruments cannot
see: native SQL built as strings, repository variables with non-matching names, reflection, and direct
DB edits. Every row below is visited by §5 or excluded with a reason.

| # | Site (quoted) | Can it delete CLOSED today? | Disposition |
|---|---|---|---|
| R1 | `findBolIdByUnitLoadLabelId` → `Long` (label-only match) | selects it | **Untouched.** Single-row finder, 0 exposure (SBDEV-3418 §4.2(2)). |
| R2 | `findBolCarrierIdListByUnitLoadLabelId` (scalar subquery) | selects it | **Untouched**, same reason. |
| R3 | `deleteBolPositionByIdNoClear`: `"DELETE FROM BillofladingPosition bp WHERE bp.id = :bolPositionId"` | **yes** | Fix D predicate |
| R4 | `deleteBolPositionsCarrierIdsNoClear`: `"… WHERE bp.carrierId IN :carrierIds"` | **yes** | Fix D predicate |
| R5 | `deleteBolPositionById` (`clearAutomatically = true`) | **yes** | Fix D predicate |
| R6 | `deleteBolPositionsCarrierIds` (`clearAutomatically = true`) | **yes** | Fix D predicate |
| V1 | `MobileMoveUnitloadService.handleTruckOffLoadingNoClear` → R1, R2, R4, R3 | **yes (reproduced, `682483fe`)** | Fix B backstop |
| V2 | `MobileMoveUnitloadService.handleTruckOffLoading` → R1, R2, R6, R5 | **yes (code reading)** | Fix C backstop |
| C1 | `MobileTruckLoadingWriteService.scanGate` D0: `mobileTransferService.handleTruckOffLoadingNoClear(dto.getPalletName());`. Only caller of V1 (I1). | yes | Covered by Fix A (facade) + Fix B |
| C2 | `MobileMoveUnitloadService.scanDestination`, non-flowbin branch: `transferUnitLoadToLocation(...); handleTruckOffLoading(dto.getUnitLoadLabel());`. Only caller of V2 (I1). | **yes (analysis §2, not yet run)** | Fix C. AC-6 is written red first. |
| D1 | `closeBOL` garbage delete `… WHERE bp.id IN :ids` | no (null-source rows on a BOL that is not closed) | Excluded |
| D2 | `removeBOLPositionIfExists`: `case CLOSED: throw …"already shipped!"` | no | Excluded (already guards) |
| D3 | `BillofladingRepository.deleteBolByBolNumber` | no (0 callers, not routed, FK NO ACTION) | Excluded |
| S1 | `checkPallet`: `case CLOSED: throw new BusinessException("billOfLadingPositionUnxepectedStateFound", palletLabel, …)` | n/a | **Reference.** Fix A mirrors its key and its CLOSED-only rule. |
| S2 | PHASE C `switch (bol.getState())`: checks the **target** BOL only | n/a | This is the gap |
| S3/S4 | `assertParcelCarrierNotShipped` / `assertParcelCarrierNotOnTruck` / `assertPalletNotAssignedToGate` | n/a | Excluded (parcel-carrier or any-state predicates; no-op for a pallet source) |

Spring Data REST cannot route R3–R6: `@RepositoryRestResource(... exported = false)` on
`BillofladingPositionRepository` (analysis §0).

---

## 1. Problem Statement

`POST /v3/truckLoading/scanGate` for a pallet whose BOL has already **CLOSED** (shipped) runs PHASE D0.
D0 deletes the pallet's `billoflading_position` rows **matched by label alone, with no BOL or state
filter**, and then PHASE D builds a new tree on the target BOL. The shipping record of a pallet that has
already left the building is destroyed in one committed transaction. The handheld UI does not hit this,
because `/scanPallet` (`checkPallet`) rejects the pallet first. A direct `/scanGate` call skips that step.
This is the same "check only in the UI step" pattern as SBDEV-3474.

The same data loss is reachable, by code reading, through `POST /v3/moveUnitload/selectDestination`.
There it also moves the pallet out of Shipped (analysis §2).

**Reproduction (red today):** `MobileTruckLoadingClosedBolPurgeIT.scanGateMustNotDeleteAShippedPalletsClosedBolPositions`
at `682483fe`. Scan onto BOL X, set X and its positions to CLOSED, re-scan onto BOL Y: X's positions are
gone and Y has a tree.

**DB verification (read-only, analysis §8):**

| Q | DB | Result |
|---|---|---|
| Q1 | Hydra PRD `wh01_hydra_v2` | BOL state vs position state: only `CLOSED\|CLOSED`, 756 positions on 40 BOLs. **0 mismatches.** |
| Q3/Q4 | Hydra PRD | **44** shipped pallets, all on `Shipped`, `entity_lock=405`. All 44 labels match `STRING_PATTERN_OUTBOUND_PALLET` / `AOUT-%1$06d`, so **every one is D0-eligible.** |
| Q5/Q6 | Hydra PRD | Tree integrity: 0 orphans, 0 cross-BOL children. 0 of 265 SHIPPING-record labels have a later record. **All 44 are intact; no loss has occurred.** |
| Q7 | Hydra PRD | 8 FKs touch `billoflading_position`, all NO ACTION. No cascade. |
| Q9/Q10 | dev `dev_wh01_om1` | CLOSED/CLOSED 1,804,591; TRANSFER/TRANSFER 3; TRUCK_LOADING/TRUCK_LOADING 25; **0 mismatches**; 0 pallets with more than one pallet position. |

**Exposure:** 44 pallets on Hydra PRD, which is the only v2 PRD client, are one direct API call away from
losing their shipping record. Current loss: none.

---

## 2. Root Cause Analysis

### Bug 1: `scanGate` never checks the pallet's own position state (C1 → V1)
`checkPallet` is the only check of a pallet's own position state on the truck-loading path (I4). It sits
behind `/scanPallet`. `MobileTruckLoadingService.scanGate` runs only
`outboundPalletLabelGuard.requireOutboundPalletLabel(...)`, and the write service's PHASE C checks the
**target** BOL (`switch (bol.getState())`, S2). D0 then runs:

```java
// MobileMoveUnitloadService.handleTruckOffLoadingNoClear
if (matches) {
    Long bolPositionId = billofladingPositionRepository.findBolIdByUnitLoadLabelId(unitLoadLabel);
    ...
        billofladingPositionRepository.deleteBolPositionsCarrierIdsNoClear(carrierIds);
        billofladingPositionRepository.deleteBolPositionByIdNoClear(bolPositionId);
```
Nothing between the label match and the delete looks at `bp.state`.

### Bug 2: the delete statements have no state predicate (R3–R6)
`"DELETE FROM BillofladingPosition bp WHERE bp.id = :bolPositionId"` and its three siblings delete
whatever id they are handed. Any caller holding a CLOSED id destroys a shipping record.

### Bug 3: `scanDestination` reaches V2 for a shipped pallet (C2 → V2), code reading only
`scanUnitLoad` rejects a pallet standing on Shipped (`if (shipped.equals(storageLocation)) throw … "Can not move unit load from "`).
`scanDestination` checks only the **destination** (`if (shipped.equals(destinationStorageLocation))`). For a
pallet source, `assertSourceCarrierNotOnTruck` is a no-op (`if (carrierId == null) return;` in both halves),
and `transferUnitLoadToLocation(..., false, …)` checks only the destination's lock. `handleTruckOffLoading(dto.getUnitLoadLabel())`
then deletes the CLOSED tree and the move out of Shipped commits. **Unproven until AC-6 runs red.**

### Why a facade guard alone is not enough (the race)
The facade check passes while BOL X is TRUCK_LOADING. `closeBOL(X)` then commits CLOSED. The write
transaction's D0 then deletes CLOSED rows. B1 locks the *target* BOL Y, not X, so nothing serialises them
except the pallet row. `closeBOL`'s **measured** lock order (`ClosebolLockOrderProbeIT`) is
`billoflading → unitload_record → unitload → stockunit → flush{billoflading_position, …}`. It locks the
pallet row **before** it writes CLOSED to the positions, and `scanGate` holds that row from B2
(`unitloadRepository.findByLabelidForUpdate`) until commit. So **a check that runs after B2 is race-free
against `closeBOL`**, and a check that runs before B2 (the facade, or PHASE A) is not. That is the whole
reason for the D0 backstop. Caveat: this rests on one measured probe of one path (analysis §3.3).

---

## 3. Scope

**In scope:** Fixes A–E below, covering C1 and C2 (decision 3).

**Out of scope, recorded, not changed:**
- **Three definitions of "shipped"** (analysis finding 3). `checkPallet` uses CLOSED only.
  `assertParcelCarrierNotShipped` uses CLOSED or TRANSFER. `removeBOLPositionIfExists` throws "already
  shipped!" on CLOSED and treats TRANSFER as `default: throw "Unexpected status="`. This plan uses CLOSED
  only (decision 2) and does not reconcile the three.
- **D0 placement** (SBDEV-3418 §3.2: "a choice among unrankable options"). Not moved.
- **R1/R2 non-uniqueness** (SBDEV-3418 §4.2(2), 0 exposure). Not touched.
- The error key `billOfLadingPositionUnxepectedStateFound` exists only in `messages_en_US.properties:331`,
  not in base `messages.properties`. This gap already exists (`checkPallet` has it). Not fixed here.

**3.3 PROPOSED ONLY, for Nam to confirm (T3, data integrity; not filed):** a shipped unitload whose label is
**not** outbound-shaped can still be moved out of Shipped through a direct `selectDestination` call. No
positions are deleted in that case, so this plan's backstop does not fire. The fix is one line in
`scanDestination` mirroring `scanUnitLoad`'s `shipped.equals(storageLocation)` on the source, plus one unit
test, about 30 minutes. Candidate home: SBDEV-3442 (SBDEV-3418 §4.2(3) routes `scanDestination` work
there). If SBDEV-3442 is `on dev` or later, it gets a new ticket. The same check would also close this
plan's C2 residual (§8, R2).

---

## 4. Architecture Overview

```
POST /v3/truckLoading/scanGate
  MobileTruckLoadingService.scanGate            (NOT @Transactional; OSIV off)
    ├─ outboundPalletLabelGuard.requireOutboundPalletLabel(label)     SBDEV-3474
    ├─ billofladingPositionService.assertPalletNotShipped(label)      ← Fix A (no lock; racy by design)
    └─ MobileTruckLoadingWriteService.scanGate  @Transactional(tenantTransactionManager)
         A scalars → B1 BOL(target) FOR UPDATE → B2 pallet FOR UPDATE → B3..B6 → C guards
         D0 handleTruckOffLoadingNoClear(label)
              if (matches) { assertPalletNotShipped(label) ← Fix B (after B2: race-free)
                             R1, R2, R4*, R3* }             ← Fix D (* state predicate)
         D writes

POST /v3/moveUnitload/selectDestination
  MobileMoveUnitloadService.scanDestination     @Transactional(tenantTransactionManager)
    … transferUnitLoadToLocation(source, dest, false, CODE_TRANSFER, …)
    handleTruckOffLoading(label)
         if (matches) { assertPalletNotShipped(label) ← Fix C (throw ⇒ whole move rolls back)
                        R1, R2, R6*, R5* }            ← Fix D
```

| Key file | Role in this fix |
|---|---|
| `repo/jpa/BillofladingPositionRepository.java` | new scalar finder; predicate on R3–R6 |
| `service/BillofladingPositionService.java` | new `assertPalletNotShipped(String)`: the single home of the throw |
| `service/mobile/MobileTruckLoadingService.java` | Fix A call site; +1 constructor parameter |
| `service/mobile/MobileMoveUnitloadService.java` | Fix B (`handleTruckOffLoadingNoClear`), Fix C (`handleTruckOffLoading`) |
| `service/mobile/MobileTruckLoadingWriteService.java` | D0 comment only |
| `service/mobile/OutboundPalletLabelGuard.java` | **deliberately not touched** (see Fix A) |

---

## 5. Fix Design & Implementation

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | Database state | N/A | — | No schema change. Predicate and finder use existing columns (`state`, `source_id`, indexed per Q8). |
| 2 | Feature flags / sysprops | N/A | — | The backstop sits inside the existing `if (matches)`, so the outbound-pattern sysprops keep their current meaning. No new toggle: a flag on a data-loss guard would be a way to switch the guard off. |
| 3 | Config / env | N/A | — | None. |
| 4 | Deploy order | N/A | — | wms2-api only. The error shape is the existing `BusinessException` → `WebserviceBusinessExceptionClientSide` path. |
| 5 | Data migration | N/A | — | 44/44 Hydra pallets are intact (Q5/Q6). Nothing to repair. |
| 6 | External systems | N/A | — | No OMS/printer touch. `closeBOL`'s OMS notification is unchanged. |
| 7 | Access / permissions | N/A | — | No new endpoint or function. Existing gates: `MOBILE_UI_VIEW_TRUCK_LOADING`, `MOBILE_UI_VIEW_TRANSFER`. |
| 8 | Monitoring | none required | — | One `LOG.warn` per rejection (§6.5). No metric: nothing scrapes wms2 Prometheus yet. |
| 9 | Worktree fresh vs `origin/develop` | `git fetch && git log HEAD..origin/develop -- src/main/java/net/aim_ai/wms/service/mobile src/main/java/net/aim_ai/wms/repo/jpa/BillofladingPositionRepository.java` is empty, or rebase first | executor | Worktree base `b950c994`. Run before Step 1. |

### 5.2 Fix A: facade guard in `MobileTruckLoadingService.scanGate`

**Before** (`MobileTruckLoadingService.scanGate`):
```java
outboundPalletLabelGuard.requireOutboundPalletLabel(truckLoadingMobileDTO.getPalletName());

MobileTruckLoadingWriteService.TruckLoadOutcome outcome;
try {
    outcome = truckLoadingWriteService.scanGate(truckLoadingMobileDTO);
```
**After:**
```java
outboundPalletLabelGuard.requireOutboundPalletLabel(truckLoadingMobileDTO.getPalletName());
// SBDEV-3487: a pallet with a CLOSED position is shipped; reject BEFORE the write service locks
// anything, with checkPallet's key. Racy against closeBOL by construction: the guarantee is the
// D0 backstop, which runs after B2's pallet lock. Outside the try: BusinessException, not a lock failure.
billofladingPositionService.assertPalletNotShipped(truckLoadingMobileDTO.getPalletName());

MobileTruckLoadingWriteService.TruckLoadOutcome outcome;
try { ...
```

**New method** (`BillofladingPositionService`, next to `assertPalletNotAssignedToGate`):
```java
/** SBDEV-3487: reject a pallet already shipped on a CLOSED BOL (CLOSED only; TRANSFER stays re-scannable,
 *  matching checkPallet). SCALAR query: loads no BillofladingPosition, so it is safe inside PHASE D0's
 *  bulk-delete boundary and costs the first-touch rule (SBDEV-3244) nothing. */
public void assertPalletNotShipped(String palletLabel) throws BusinessException {
    if (palletLabel == null) return;
    String closedBolName = billofladingPositionRepository.findClosedBolNameBySourceUnitLoadLabel(palletLabel);
    if (closedBolName != null) {
        LOG.warn("assertPalletNotShipped: pallet {} is already shipped on CLOSED BOL {}", palletLabel, closedBolName);
        throw new BusinessException("billOfLadingPositionUnxepectedStateFound", palletLabel, closedBolName);
    }
}
```

**New finder** (`BillofladingPositionRepository`; the analysis §3.2 candidate):
```java
@RestResource(exported = false)
@Query(value = "select coalesce(b.name, bp.number) from billoflading_position bp "
        + "join unitload u on u.id = bp.source_id "
        + "left join billoflading b on b.id = bp.billoflading_id "
        + "where u.labelid = :unitLoadLabelId and bp.state = 'CLOSED' "
        + "order by bp.id limit 1", nativeQuery = true)
String findClosedBolNameBySourceUnitLoadLabel(@Param("unitLoadLabelId") String unitLoadLabelId);
```
`coalesce(b.name, bp.number)` reproduces `checkPallet`'s second argument (`findById(...).getName()`, else
`getNumber()`). Keying on `bp.state` alone needs no BOL-state join, because position state equals BOL
state (analysis §4.1: 0 mismatches on both DBs; `closeBOL` and `finishTransfer` write all levels).

**Why here, and not the alternatives:**
- **Not on `OutboundPalletLabelGuard`.** `AbstractTruckLoadingPgFixture:152` and
  `MobileTruckLoadingRollbackIT:152` both declare `@MockitoBean private OutboundPalletLabelGuard`. A guard
  there would be a silent no-op in every IT on those classes, and the red IT would go green through the
  backstop alone.
- **On `BillofladingPositionService`.** It is not mocked in either PG class: the only `@MockitoBean`s are
  `ManageOrderService`, `OutboundPalletLabelGuard` and `ItemdataService` (grep of both files). It already
  holds the sibling predicates (`assertPalletNotAssignedToGate`, `assertParcelCarrierNotShipped`). It is
  already injected into `MobileMoveUnitloadService`, so Fixes B and C reuse the same method with no new
  wiring. One throw, one message, three call sites.
- **Not a new `@Component`.** That would duplicate an existing home for no gain.
- **Not inline in the facade** via its existing `billofladingPositionRepository`. That would mean three
  copies of the throw.
- **Cost:** `MobileTruckLoadingService` gains a constructor parameter. The only `new MobileTruckLoadingService(`
  sites are `MobileTruckLoadingServiceUnitTest:85` and `MobileTruckLoadingServiceTest:71` (grep of
  `src/test`). `TruckLoadingControllerUnitTest` mocks the class. Spring wiring is constructor-based, and
  there is no cycle: `BillofladingPositionService` depends on `ClientService`, `BillofladingPositionRepository`,
  `BasicService` and `UnitloadRepository` only.

**Not a copy of `checkPallet`** (analysis §3.1). That approach loads `BillofladingPosition` entities (stale
managed instances after the NoClear bulk delete), calls `billofladingRepository.findById` (a lock upgrade
if that BOL is B1's target), and breaks PHASE A's "scalars only" rule.

### 5.3 Fix B: V1 backstop in `handleTruckOffLoadingNoClear`

**Before:**
```java
if (matches) {
    Long bolPositionId = billofladingPositionRepository.findBolIdByUnitLoadLabelId(unitLoadLabel);
```
**After:**
```java
if (matches) {
    // SBDEV-3487 backstop — THE guarantee on the scanGate path. A CLOSED position is a shipping
    // record, never a stale one. Runs after B2's pallet lock, and closeBOL locks the pallet before it
    // writes CLOSED (ClosebolLockOrderProbeIT), so this read cannot be overtaken by a close.
    // Throws rather than skips: a skip lets PHASE D build a second tree (pallet on two BOLs).
    billofladingPositionService.assertPalletNotShipped(unitLoadLabel);
    Long bolPositionId = billofladingPositionRepository.findBolIdByUnitLoadLabelId(unitLoadLabel);
```
- **Inside `if (matches)`:** the pattern-miss and not-configured exits stay exactly as they are (AC-5).
- **Before R1:** R1 throws `IncorrectResultSize` if more than one row exists, and the backstop must fail
  first with the right key.
- **Persistence context:** PHASE C is predicate-only, so no writes are pending and the native query's
  auto-flush is a no-op, the same as R1's today. It creates no `EntityEntry`. It is an unlocked indexed
  SELECT, **not** `FOR UPDATE`, so the table lock order is unchanged.

### 5.4 Fix C: V2 backstop in `handleTruckOffLoading`

The same two lines at the same seat (`if (unitLoadLabel.matches(pattern) || …) {`, before
`findBolIdByUnitLoadLabelId`). The javadoc names this variant's difference: it runs **after**
`transferUnitLoadToLocation` in `scanDestination`, so its throw is what rolls the move out of Shipped back
(`rollbackFor = {BusinessException.class, …}` on `scanDestination`).

**Race note for C2:** `scanDestination` takes no `findByLabelidForUpdate` on the pallet. Whether the pallet
row is locked when the backstop reads depends on when Hibernate flushes `transferUnitLoadToLocation`'s
UPDATE. The native query will likely auto-flush it first, as R1's native query already does today, but
this is **unmeasured**. Fix D removes the dependency.

The two variants stay duplicated, per the existing javadoc: "Deliberately NOT refactored into a shared
private helper taking a flag". Both variants get the identical call.

### 5.5 Fix D: state predicate on R3–R6 (ADOPTED)

**Before** (R3; R4–R6 follow the same shape):
```java
@Query("DELETE FROM BillofladingPosition bp WHERE bp.id = :bolPositionId")
```
**After:**
```java
@Query("DELETE FROM BillofladingPosition bp WHERE bp.id = :bolPositionId"
        + " AND (bp.state IS NULL OR bp.state <> 'CLOSED')")   // SBDEV-3487: a CLOSED row is a shipping record
```
- **The `IS NULL` arm keeps today's behaviour for a null-state row.** Without it, `NULL <> 'CLOSED'` is
  unknown and such a row would stop being purged. Q1/Q9 grouped by state found no null group, so the arm
  costs nothing and guards a row class that no measurement has ruled out forever.
- **Literal `'CLOSED'`:** `src/main` has no precedent for a state literal in JPQL
  (`git grep "'CLOSED'" src/main/java` → 0 hits). `WmsConstants.BillOfLadingState.CLOSED = "CLOSED"`
  (`WmsConstants:261`). AC-9 pins the value by behaviour, so a constant drift fails a test.

**Decision reasoning:**
- **For:** Under READ COMMITTED, a DELETE that waits on a row lock re-evaluates its WHERE against the newly
  committed row version. The predicate therefore holds regardless of which locks the caller took. That is
  the only construct that makes decision 3's "neither can delete CLOSED positions" true for C2, which takes
  no pallet lock, and for any future caller of R3–R6.
- **Cost:** four one-clause string edits. No signature change. The callers of R3–R6 in `src/main` are only
  V1 and V2 (grep of all four names).
- **Residual:** in a race window the predicate turns a would-be delete into a silent 0-row skip. For V1 the
  window is empty (Fix B runs after B2). For C2 the outcome is non-destructive: positions intact, pallet
  moved; see §8 R2.
- **Rejected refinement:** returning `int` from the pallet-row delete and throwing on 0. It would falsely
  fail a legitimate second concurrent move of the same pallet (its row is already gone, so it gets 0 rows).
- **Why not skip Fix D:** covered in the RALPLAN option A2.

### 5.6 Fix E: docs and comments

| File | Change |
|---|---|
| `sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md` | **(1)** "`handleTruckOffLoading()` when the **destination** label matches the outbound-pallet regex" is false: the code tests the **source** label (`handleTruckOffLoading(dto.getUnitLoadLabel())`). ⚠ The claim appears in **four** places, not the two analysis §6 names: line 42 (overview), the flow box ("Destination matches outbound-pallet regex?"), Landmine 3, and the symptom table row "destination label didn't match outbound regex". Fix all four. **(2)** The flow box lists "not Shipped" under `scanDestination` and the guard table lists "`Can not move from shipped` \| 144" without naming a step. Make both explicit: the Shipped **source** check is only in `scanUnitLoad` (`if (shipped.equals(storageLocation))`), and `scanDestination` checks only the destination. **(3)** Add to Landmine 4: "SBDEV-3487: refuses (throws `billOfLadingPositionUnxepectedStateFound`) when the label has a CLOSED position; R3–R6 never delete CLOSED rows." Bump `last_verified`. |
| `sbdocs/3-Resources/workflows/wms2-bol-truck-loading-workflow.md` | D0 row (`handleTruckOffLoadingNoClear(palletName) — ahead of every pending write`): append "Throws `billOfLadingPositionUnxepectedStateFound` if the pallet has a CLOSED position (SBDEV-3487 backstop; the facade rejects the same case before B1). TRANSFER positions are still purged." Bump `last_verified` (currently 2026-08-03). |
| `MobileTruckLoadingWriteService` D0 comment | One line naming the backstop and why it lives after B2. |
| `BillofladingPositionService.assertParcelCarrierNotOnTruck` javadoc | "A pallet loses its positions when it is moved off the truck …" → add "unless they are CLOSED (SBDEV-3487)". |
| `BillofladingPositionRepository` javadoc on R3/R5 | State the predicate's purpose once. The siblings reference it. |

### 5.7 File Change Summary

| File | Kind | Est. lines |
|---|---|---|
| `repo/jpa/BillofladingPositionRepository.java` | +1 finder, 4 predicates, javadoc | ~20 |
| `service/BillofladingPositionService.java` | +1 method | ~15 |
| `service/mobile/MobileTruckLoadingService.java` | +1 ctor param/field, +1 call | ~6 |
| `service/mobile/MobileMoveUnitloadService.java` | +1 call in each of V1 and V2, javadoc | ~12 |
| `service/mobile/MobileTruckLoadingWriteService.java` | comment | ~3 |
| `test/.../MobileTruckLoadingClosedBolPurgeIT.java` | tighten AC-1; add AC-3 IT, AC-7, AC-9 | ~120 |
| `test/.../MobileMoveUnitloadClosedBolPurgeIT.java` (new, `extends AbstractTruckLoadingPgFixture`) | AC-6 | ~90 |
| `test/.../MobileTruckLoadingServiceUnitTest.java`, `MobileTruckLoadingServiceTest.java` | ctor arg; AC-2 in the former | ~50 |
| `test/.../MobileMoveUnitloadServiceUnitTest.java` | new `@Nested` classes for AC-3u, AC-4, AC-5 | ~100 |
| `test/.../BillofladingPositionServiceUnitTest.java` | new `@Nested AssertPalletNotShipped` (AC-8) | ~50 |
| 2 workflow docs | Fix E | — |

### 5.8 Implementation Steps (test-first)

1. **Baseline and freshness.** Run §5.1 row 9. Run the full `mvn verify` baseline adjacent in time
   (no concurrent Maven on the machine; `pgrep -f maven` first). Record failures and errors, not totals.
2. **Write every red test (§6) before any `src/main` edit.** Confirm each fails **for the right reason**:
   - AC-1: positions deleted / no exception.
   - AC-6: positions deleted **and** the pallet has left Shipped.
   - Unit tests: compile or `never()` failures only where a missing method forces it. Stub the method in a
     first commit if needed so the reds are behavioural.
   - ⚠ **If AC-6 is GREEN on pre-fix code, STOP and report.** Analysis §2 would be wrong. Fix C still ships
     (decision 3), but AC-6 is rewritten as a positive control, the C2 exposure claim is withdrawn from §1,
     and the §3.3 proposal is re-examined.
   - Commit the reds.
3. **Finder + `assertPalletNotShipped`** (§5.2 new method and finder). AC-8 goes green.
4. **Fix A.** AC-2 and AC-1 go green (AC-1 passes through the facade, because `BillofladingPositionService`
   is real in the fixture).
5. **Fixes B and C.** AC-3 (unit + IT), AC-4, AC-5 and AC-6 go green. AC-7 stays green.
6. **Fix D.** AC-9 goes green. Then Fix E (docs and comments).
7. **Floor:**
   - Mutation-check every new assertion per §6.2's "Mutation" column: break the protected line, see red,
     restore. Record each in the implementation report.
   - Run PIT scoped to `BillofladingPositionService` and `MobileMoveUnitloadService` for AC-4/AC-5.
   - Run the full suite against the Step 1 baseline.
   - Run one independent `code-reviewer` pass in a separate worktree lane, and fix every finding including
     Low.

---

## 6. Testing Plan

### 6.1 No verify script
Every invariant here is behavioural and visible to a JUnit or IT assertion. No cross-file invariant needs a
grep row.

### 6.2 Acceptance criteria → tests

| AC | Test class#method | Level | Red today | Mutation (must turn red) |
|---|---|---|---|---|
| AC-1 | `MobileTruckLoadingClosedBolPurgeIT#scanGateMustNotDeleteAShippedPalletsClosedBolPositions`: replace `catchThrowable` with `assertThatThrownBy(...).isInstanceOf(BusinessException.class)` and `getKey()` = `billOfLadingPositionUnxepectedStateFound`. X's positions `containsExactlyElementsOf(shippedPositions)`, Y empty, pallet `storagelocation_id` unchanged. | IT (PG) | yes | Remove Fix A **and** Fix B → red on the key and on Y-empty (Fix D alone keeps X intact but lets PHASE D build Y's tree). Removing one layer only stays green, by design; AC-2/AC-3 cover each layer. |
| AC-2 | `MobileTruckLoadingServiceUnitTest#scanGateRejectsShippedPalletBeforeWriteService`: stub the finder → `"BOL-X"`; assert the key and `verifyNoInteractions(truckLoadingWriteService)` (pass a mock for it in this test). Plus `#labelGuardRunsBeforeShippedGuard`: a non-outbound label with the finder stubbed CLOSED → `noValidString`, and `verify(repo, never()).findClosedBolNameBySourceUnitLoadLabel(any())`. | unit | yes | Delete the Fix A call → red. Swap order → second test red. |
| AC-3 | Unit: `MobileMoveUnitloadServiceUnitTest.HandleTruckOffLoadingNoClear#closedPositionThrowsAndDeletesNothing`: `billofladingPositionService.assertPalletNotShipped` stubbed to throw; `never()` on R1, R2, R3, R4. IT: `MobileTruckLoadingClosedBolPurgeIT#writeServiceScanGateDirectRejectsShippedPallet` calls `MobileTruckLoadingWriteService.scanGate` directly (the ArchUnit entry-point rule uses `DO_NOT_INCLUDE_TESTS`, so a test caller is allowed). Assert the key, X intact, Y empty. | unit + IT | yes | Delete Fix B → both red (the IT on the key and Y-empty, even with Fix D present). |
| AC-4 | `MobileMoveUnitloadServiceUnitTest.HandleTruckOffLoading#closedPositionThrowsAndDeletesNothing`: same as AC-3u, with `never()` on R5/R6. | unit | yes | Delete Fix C → red. PIT scoped to `MobileMoveUnitloadService`. |
| AC-5 | `…HandleTruckOffLoadingNoClear#patternMissRunsNoPositionQuery` and `#notConfiguredRunsNoPositionQuery`, `…HandleTruckOffLoading#patternMissRunsNoPositionQuery`: `verify(billofladingPositionService, never()).assertPalletNotShipped(any())`. The existing `HandleTruckOffLoading` tests stay green. | unit | no (it guards placement) | Hoist the backstop above `if (matches)` → red. |
| AC-6 | `MobileMoveUnitloadClosedBolPurgeIT#selectDestinationOfShippedPalletIsRejectedAndRollsBack`: scanGate → close X as CLOSED (jdbc, as `closeBolAsShipped`) → set pallet `storagelocation_id` = Shipped, `entity_lock = 405` → `mobileMoveUnitloadService.scanDestination` to an ordinary non-flowbin location. Assert the key, X intact, **pallet still on Shipped with lock 405**. Use a fixed `BOUT-9487xx` label and exact-label cleanup as in the existing IT. | IT (PG) | **expected yes, not run.** Step 2 STOP rule applies. | Delete Fix C → red on the key and the location (Fix D keeps the positions). |
| AC-7 | `MobileTruckLoadingClosedBolPurgeIT#transferBolPalletIsStillReScannable`: close X as **TRANSFER**, re-scan onto Y. X empty, Y has the tree. The existing `reScanFromAnOpenBolMovesThePallet` stays green. | IT (PG) | no | Change the finder or predicate to `IN ('CLOSED','TRANSFER')` → red. |
| AC-8 | `BillofladingPositionServiceUnitTest.AssertPalletNotShipped`: (a) a null finder result → no throw; (b) `"BOL-X"` → key + args `(label, "BOL-X")`; (c) `verify(repo).findClosedBolNameBySourceUnitLoadLabel(label); verifyNoMoreInteractions(repo)` (in particular never `getBySourceUnitLoadLabelId`); (d) reflection: that method's return type `== String.class`. | unit | n/a (new) | Replace with the entity finder → (c)/(d) red. |
| AC-9 | `MobileTruckLoadingClosedBolPurgeIT#repositoryDeletesNeverRemoveClosedRows`: seed a CLOSED tree; inside `tx()`, call R3, R4, R5 and R6 directly with its ids; `count(*)` on X unchanged. Plus a TRUCK_LOADING control tree that **is** deleted. | IT (PG) | yes | Drop the predicate from any one of the four → red. One mutant per query. |

### 6.3 Regression
- `MobileTruckLoadingWriteServiceUnitTest` (D0 ordering, `inOrder.verify(mobileTransferService).handleTruckOffLoadingNoClear(PALLET)`)
- `MobileTruckLoadingRollbackIT`
- `MobilePalletizeRepalletizeIT`
- `MobileMoveUnitloadServiceUnitTest` / `MobileMoveUnitloadServiceTest` (existing `HandleTruckOffLoading` and `Sbdev3452MoveTruckBoundary`)
- `BillofladingPositionRepositoryTest` (H2)
- `TruckLoadingWriteEntryPointArchTest`
- Then the full `mvn verify` against the baseline.

### 6.4 Manual test plan (dev, after the merge to `develop` = the dev deploy; confirm the build SHA at `/api/public/version` first)

| Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Direct scanGate of a shipped pallet, rejected before any lock | wms2-wineco-dev (`dev_wh01_om1`) | 1. Pick an outbound-labelled pallet with a CLOSED pallet position: `select u.labelid, bp.billoflading_id from billoflading_position bp join unitload u on u.id=bp.source_id where bp.state='CLOSED' and u.labelid ~ '<outbound regex>' limit 1`. 2. Pick an OPEN/TRUCK_LOADING BOL Y and its gate. 3. **Before:** `select xmax from billoflading where id=:Y; select xmax from unitload where labelid=:pallet;` and `count(*)` of X's positions. 4. `POST /v3/truckLoading/scanGate` with `{palletName, selectedBOLName: Y, scannedGateName}` (Accept-Language `en-US`). 5. **After:** re-run step 3. | 4xx with "Pallet … already part of BOL …". **xmax unchanged on both rows** (a `FOR UPDATE` stamps xmax even when the transaction rolls back). X's count unchanged. Y has no new positions. | |
| Control: TRANSFER / TRUCK_LOADING pallet still moves | dev | Re-scan a pallet whose positions are TRUCK_LOADING (or TRANSFER) onto another BOL | 200; old positions purged, new tree on the target | |
| Move-unitload of a shipped pallet | dev | `POST /v3/moveUnitload/selectDestination` `{unitLoadLabel: <shipped pallet>, destinationLabel: <ordinary location>}` | 4xx with the same key; pallet still on `Shipped`, lock 405; positions intact | |
| Handheld happy path is unchanged | dev handheld | scanPallet → scanGate for a fresh outbound pallet | Loads as before | |

### 6.5 Expanded test plan (deliberate mode)

| Layer | What | Where |
|---|---|---|
| **Unit** | Each layer pinned alone: AC-2 (facade), AC-3u (V1), AC-4 (V2), AC-5 (placement), AC-8 (scalar and no entity). Mutation-checked, with PIT on the two classes. | §6.2 |
| **Integration (PG Testcontainers)** | End-to-end through real repositories and real `BillofladingPositionService`: AC-1, AC-3 IT, AC-6, AC-7, AC-9. The fixture's `@MockitoBean OutboundPalletLabelGuard` is intentionally left in place: it proves Fix A does not depend on it. | `MobileTruckLoadingClosedBolPurgeIT`, new `MobileMoveUnitloadClosedBolPurgeIT` |
| **Concurrency** | Not added as a test. The facade race and its closure by B2 rest on the measured `ClosebolLockOrderProbeIT` order. Extending that probe to record `billoflading_position` lock acquisitions is a follow-up (ADR). Fix D makes C2's safety independent of lock order, and AC-9 proves it. | — |
| **E2E (manual dev)** | §6.4, including the xmax no-lock proof. | dev |
| **Observability** | `LOG.warn("assertPalletNotShipped: pallet {} is already shipped on CLOSED BOL {}")` on every rejection, from all three sites. After the PRD release, re-run Hydra Q3/Q5/Q6. Expected: every pallet with a CLOSED position still has its full tree, and 0 labels with a record after SHIPPING. Watch WARN volume for a week: a non-zero rate means someone is calling `/scanGate` or `/selectDestination` directly for shipped pallets. | logs + read-only SQL |

---

## 7. Horizontal Scalability Validation

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | No | No fields, caches or static state added. |
| 2 | Connection pool math | No | The facade guard is one short read on its own EntityManager (OSIV off), finished before the write transaction opens. The backstop reuses the open transaction's connection. |
| 3 | Scheduled jobs | N/A | None touched. |
| 4 | Long transactions | No | +1 indexed scalar SELECT (`index_billoflading_position_source_id`, Q8) inside the existing boundaries. |
| 5 | Request affinity | No | Stateless. |
| 6 | Retry / idempotency | No | A retry of a rejected scan is rejected again. A retry of an accepted scan behaves as today. |
| 7 | Tenant context | No | No async boundary. The request thread's `TenantContext` routes both reads. |
| 8 | Distributed lock correctness | No change | No new lock. The backstop relies on the existing B2 `PESSIMISTIC_WRITE` inside `@Transactional(tenantTransactionManager)`. Fix D relies on PG READ COMMITTED re-check, which holds on every replica. |
| 9 | Cache invalidation | N/A | `billoflading_position` is not cached. |
| 10 | External notifications | No | None added. A rejected scan never reaches the facade's `ManageOrderService` call. |

---

## 8. Risks & Mitigations

| # | Risk | Mitigation |
|---|---|---|
| R1 | A legitimate workflow re-loads or moves a pallet that has a CLOSED position | Measured: Hydra has 0 labels with any record after SHIPPING (Q6). Position state equals BOL state, 0 mismatches (Q1/Q9). No reopen-BOL path writes positions back from CLOSED. The rejection names the BOL, and the WARN log quantifies it. |
| R2 | **C2 residual:** `closeBOL(X)` commits between the backstop read and R6/R5 (only possible if the pallet UPDATE was not yet flushed). Fix D skips the CLOSED rows silently: **no data loss**, but the pallet ends up moved out of Shipped with its CLOSED positions intact. | Requires a concurrent close plus a direct API call on the same pallet. The §3.3 proposal (source-is-Shipped check) closes it. Stated here instead of implied safe. |
| R3 | The facade key renders raw on a non-`en_US` locale | This gap already exists and is shared with `checkPallet` (§3). Tests assert `getKey()`, never message text. |
| R4 | `MobileTruckLoadingService` constructor change breaks a hand-built test | Both sites are listed in §5.2 and updated in Step 2. The compile fails loudly otherwise. |
| R5 | `closeBOL` racing a scanGate that wins the pallet lock now 409s more often | Unchanged from today (analysis §3.3). D0 deletes TRUCK_LOADING rows, and `closeBOL`'s version-checked flush fails and rolls back. The fix adds no lock and does not change the table order. |

### 8.1 Pre-mortem (the fix ships and still fails or harms)

1. **"Green ITs, dead guard."** A later refactor adds `@MockitoBean BillofladingPositionService` to
   `AbstractTruckLoadingPgFixture`, the exact SBDEV-3474 trap. Every IT goes green through a mock, and the
   facade and both backstops are gone in the IT lane.
   **Mitigation:** AC-8, AC-3u and AC-4 run against the real method or real call sites in unit tests.
   AC-9 exercises Fix D against the repository directly, which no service mock can hide. A javadoc on
   `assertPalletNotShipped` names the trap.
2. **"Someone tidies the duplication."** A reviewer collapses V1 and V2 into a flagged helper, or hoists
   the backstop above `if (matches)` "for clarity", or deletes Fix D as "redundant with the pre-check".
   Result: the NoClear/clear distinction is lost, unconfigured tenants now run a position query, or C2
   loses its race-proofness.
   **Mitigation:** AC-5 pins placement. AC-9 pins each predicate with one mutant per query. The javadoc on
   each layer names its distinct job: facade = no-lock rejection; backstop = race-free after B2;
   predicate = caller-independent.
3. **"Blocks a real operation on PRD."** Hydra operations have a practice not visible in 30 days of data,
   for example re-shipping a pallet whose BOL was closed in error. After deploy those scans are refused,
   and the operators have no remedy.
   **Mitigation:** the rejection names the BOL, so support can see which one. The WARN log and the
   post-release Hydra re-query (§6.5) detect it within days. The remedy is a data correction to the BOL,
   not a code rollback, because deleting a CLOSED record is exactly what this fix exists to prevent.
   Escalate to Nam if the WARN rate is non-zero.

---

## 9. Checklists

### 9.1 v2 constraint checklist

| # | Constraint | Verdict | Where |
|---|---|---|---|
| 1 | OSIV disabled | Yes, respected | The facade read opens and closes its own EntityManager before the write transaction (analysis §3.2). It is scalar, so there is no lazy-load risk. |
| 2 | Transaction manager | Yes, unchanged | The backstops run inside the existing `@Transactional(value = "tenantTransactionManager", rollbackFor = …)` of `MobileTruckLoadingWriteService.scanGate` and `MobileMoveUnitloadService.scanDestination`. |
| 3 | `readOnly=true` | N/A | No new transactional service method. `assertPalletNotShipped` is non-transactional and joins the caller's boundary. |
| 4 | Caffeine cache | N/A | `billoflading_position` is not cached. |
| 5 | Jakarta namespace | N/A | No new imports beyond existing Spring Data annotations. |
| 6 | H2-compatible test SQL | Yes | The new native query is exercised only in the PG lane (AC-6/AC-9). `coalesce`/`limit` are also H2-legal, so `BillofladingPositionRepositoryTest` (H2) is unaffected. |
| 7 | Controller test | N/A | No controller change. The error still flows through `WebserviceBusinessExceptionClientSide`. |
| 8 | Micrometer | No | Low-frequency rejection path. A WARN log instead, because nothing scrapes wms2 metrics yet. |

### 9.2 Completeness checklist (wms-bugfix-plan Layer 2)

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1 (Q1–Q10, Hydra PRD + dev); `db_verified: true` |
| 1 | All callsites enumerated | ✓ §0: R1–R6, V1/V2, C1/C2 visited; D1–D3 and S1–S4 excluded with reasons (I1–I5 plus their blind spots) |
| 2 | Adjacent bugs | ✓ §3.3 (non-outbound shipped unitload moved out of Shipped, PROPOSED); §3 three definitions of shipped (recorded) |
| 3 | Backward compatibility | ✓ No API or schema change. New 4xx only for CLOSED pallets, with an existing key and shape. TRANSFER behaviour is unchanged (AC-7). |
| 4 | Concurrency | ✓ §2 race; §5.3 after B2; §5.5 READ COMMITTED re-check; §8 R2/R5 residuals; no new lock and no table-order change |
| 5 | Multi-tenant | ✓ §7 row 7: request-thread routing, no async |
| 6 | Error handling | ✓ The `BusinessException` is covered by the existing `rollbackFor` on both boundaries. The facade throws outside the lock-failure `try`. |
| 7 | Observability | ✓ §6.5 WARN log + post-release Hydra re-query |
| 8 | Rollback / migration | ✓ No Flyway or sysprop. A revert is a plain code revert. §5.1 is all N/A with rationale. |
| 9 | Test coverage | ✓ §6.2 AC-1 to AC-9 with named classes and methods, §6.4 manual, §6.5 expanded |
| 10 | Cross-version (v1↔v2) | no: v1 is reference-only and v2 is the only target (standing rule). v1 exposure is not assessed here. |

---

## 10. Resolved Decisions

| # | Decision | By |
|---|---|---|
| 1 | A direct scanGate of a pallet already on a CLOSED BOL is REJECTED before any lock, with `billOfLadingPositionUnxepectedStateFound`. | Nam |
| 2 | "Shipped" = CLOSED only; TRANSFER stays re-scannable (matches `checkPallet`). | Nam |
| 3 | Defence in depth: facade guard + backstop in BOTH D0 variants. | Nam |
| 4 | The backstop **throws** (it does not skip), via a scalar pre-check inside `if (matches)` before R1, in V1 and V2. | Planner default (analysis §4.2) |
| 5 | Fix D **adopted**: `AND (bp.state IS NULL OR bp.state <> 'CLOSED')` on R3–R6. | Planner default (§5.5) |
| 6 | Guard home: `BillofladingPositionService.assertPalletNotShipped`, **not** `OutboundPalletLabelGuard`. | Planner default (§5.2) |
| 7 | No PHASE A re-check (as racy as the facade). D0 is not moved. R1/R2 are not touched. | Planner default (analysis §3.3, SBDEV-3418) |
| 8 | No verify script; no metric. | Planner default (§6.1, §9.1 row 8) |
| 9 | §3.3 finding is PROPOSED only; Nam confirms the home. | Ticket policy (T3) |

---

## 11. ADR

- **Decision:** reject shipped (CLOSED) pallets at three layers: a no-lock facade guard in
  `MobileTruckLoadingService.scanGate`, a throwing scalar backstop inside both D0 variants, and a
  `state <> 'CLOSED'` predicate on the four purge deletes. All three layers share one scalar assertion on
  `BillofladingPositionService`.
- **Drivers:** (1) race-proofness against `closeBOL`; (2) coverage of both D0 callers, including C2 with no
  pallet lock; (3) test-lane honesty given the fixture's `@MockitoBean OutboundPalletLabelGuard`.
- **Alternatives considered:**
  - Guard + throwing backstop without the predicate (A2): viable. Rejected because C2's safety would rest
    on unmeasured flush timing.
  - Skipping backstop (B): violates decision 1; creates two-BOL pallets.
  - Backstop only (C) and guard only (D): violate decision 3; D is racy and misses C2.
  - Finder filter on R1/R2 (E): a silent check-then-act; touches ring-fenced finders.
  - Guard on `OutboundPalletLabelGuard`: mocked in ITs.
  - A copy of `checkPallet` in the transaction: entity loads, lock upgrade (SBDEV-3244).
- **Why chosen:**
  - The facade gives the operator a rejection that takes no lock (SBDEV-3474).
  - The backstop is the real guarantee on the scanGate path, because it runs after B2 and `closeBOL` locks
    the pallet before writing CLOSED (measured).
  - The predicate makes "never deletes CLOSED" true for every caller by construction, for four one-clause
    edits.
  - A throw (not a skip) is the only outcome that rolls back C2's move out of Shipped.
- **Consequences:**
  - One extra indexed scalar SELECT per scan.
  - A new 4xx for shipped pallets on `/scanGate` and `/selectDestination`.
  - `MobileTruckLoadingService` gains a constructor dependency.
  - A narrow C2 race is left non-destructive rather than rejected (§8 R2).
  - The three definitions of shipped remain inconsistent.
- **Follow-ups:**
  - (a) Nam confirms the §3.3 proposal and its home (SBDEV-3442 or new).
  - (b) Extend `ClosebolLockOrderProbeIT` to record `billoflading_position` acquisitions (already named by
    SBDEV-3418), turning §2's single-probe caveat into two instruments.
  - (c) Reconcile the three definitions of "shipped" if a ticket is opened.
  - (d) Add `billOfLadingPositionUnxepectedStateFound` to base `messages.properties` (shared with
    `checkPallet`).
  - (e) After the PRD release, re-run Hydra Q3/Q5/Q6 and record the result on the ticket.
