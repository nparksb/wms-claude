---
title: "SBDEV-3862 — Damaged permission skipped for a pallet destination"
ticket: "SBDEV-3862"
ticket_url: "https://app.clickup.com/t/868mky6fm"
type: "bugfix"
priority: "high"
status: "archived"
project: [wms2]
version: "v2"
target_version: "v2"
tier: T3
db_verified: true   # dev dev_wh01_om1 only (analysis §3). PRD NOT measured: MCPs down 2026-10-23/24. PRD Q1+Q3+Q4 is a MERGE GATE (§5.1 #5).
requester: "Nam Park"
created: "2026-10-23"
updated: "2026-10-25"
related:
  - "[[wms2-move-stock-unitload-workflow]]"
  - ".omc/research/SBDEV-3862-architect-consult.md"
  - ".omc/research/SBDEV-3862-analysis.md"
  - ".omc/research/SBDEV-3862-review-dispositions.md"
tags:
  - plan
---

# SBDEV-3862 — Damaged permission skipped for a pallet destination

**Ticket:** [Damaged permission skipped for a pallet destination](https://app.clickup.com/t/868mky6fm) · **Tier:** T3 (authz + stock-state integrity) · **Status:** r3 (D1 + D2 applied; round-2 text fixes applied)
**Evidence:** consult / analysis / reviews r1-r2 in `.omc/research/SBDEV-3862-*.md` · handoff `.omc/handoffs/SBDEV-3862.md`
**Code base:** worktree `.claude/worktrees/wms2-api/SBDEV-3862` = `e47fe816` + gate `012e75f5`; develop now `55a3604a` (no overlap; `e47fe816` is its ancestor). MMUS = `service/mobile/MobileMoveUnitloadService.java`, SUBS = `service/StockunitBusinessService.java`, ULBS = `service/UnitloadBusinessService.java`, DES = `service/DestinationEligibilityService.java`.

## RALPLAN-DR summary (mode: SHORT, round 3)
**Principles**
1. One effective destination location drives every destination rule: Damaged, Shipped and Nirvana.
2. Authz/Nirvana/Shipped/Damaged-stock-arm refusals run before any write; later refusals roll back the whole tenant transaction (MMUS:318 `rollbackFor`), and OMS messages are sent only after commit (`MessageService:171-174` → `StockChangeNotificationService.sendAfterCommit`; `OmsNotificationService:90-91` drops the send on `STATUS_ROLLED_BACK`).
3. Invariant over instance: after a move, a stock unit is 103 iff its final location is Damaged, and the OMS delta equals the amount whose lock state changed. Only whole-UL `setStockDamaged`/`removeStockDamaged` write the lock.
4. UL(source) stays the first row lock (MMUS:367); the destination is read plain and re-checked under the lock SUBS already takes (SUBS:319). No new lock partner.
5. Minimal surface: no signature change, no new lock-mutation helper; `setStockDamaged`/`removeStockDamaged` textually untouched.
**Decision drivers:** (1) close the permission bypass on every arm; (2) keep the lock state and the OMS damaged count true; (3) add no lock-order partner and no feature nobody uses.
**Viable options**
| Option | Pros | Cons |
|---|---|---|
| A. Re-run today's block on the effective location | ~5 lines | A UL-destination stock arm (moveStock :538, FLA-UL :553) locks the whole source before the transfer, so SUBS refuses it at :358 `"is locked="`; over-locks the stock that stays behind |
| **B′. Narrow refusal (CHOSEN, D2)**: effective location; stock arms onto an effective-Damaged destination refused before any write and re-checked under the SUBS destination lock; whole-UL arms get set/remove/KEEP | One refusal closes authz on the stock arms; no helper, no signature change, no OMS-amount rule, no rail edit | Turns a latent capability (moving loose stock into a container on Damaged) into an explicit refusal; carrier-arm and child-destination windows recorded, not closed (§3.4) |
| B. Effective location + `lockOne` on the landed SU (round-1 choice) | Moving stock into Damaged becomes supported | **Rejected:** no shipped client sends `moveStock` (MMUS:514 comment; neither v2 UI's origin/develop sends the flag); merge path undercounts OMS (Critic H1 / Arch F2); needs a rail edit and a signature change |
| C. Refuse stock arms whose effective source OR destination is Damaged | Smallest diff | Removes moving stock OFF Damaged by moveStock / flow bin, which works today |
| D. Lock the destination UL `FOR UPDATE` in `scanDestination` | Closes the read windows | Takes UL(dst) before the PO lock SUBS Hook B takes first, and adds a dest lock to the carrier arm, which has none. Stock arms already get UL(dst) after UL(src) from SUBS:309 → :319 |

## 1. Problem Statement
`scanDestination` checks `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` and sets 103 only when the scanned label is the Damaged **Location**. MMUS:408 `findByName(label).orElse(null)` is null for a UL label, so `location_damaged.equals(destinationStorageLocation)` (MMUS:411) is false: stock lands on a UL standing on Damaged with no permission check and no lock. The same null makes the Nirvana/Shipped checks (MMUS:423, :427) miss a UL on those locations. Since `e1b93713` (2025-03-15). Gate `012e75f5`: 4 red, 1 green control.

## 2. Root Cause Analysis
The destination rules key on the scanned Location; three arms land stock on the destination UL's location (analysis §0).

| # | File:line | Description |
|---|---|---|
| 1 | MMUS:408-421 | Damaged block keyed on `destinationStorageLocation` only; its `else if` strips 103 on a Damaged→UL-on-Damaged move |
| 2 | MMUS:423-428 | Nirvana/Shipped keyed on the Location only |
| 3 | MMUS:488, :538, :553 | `transferStock` (stock) arms: flow-bin Location, moveStock onto a UL, FLA UL. :488/:553 run with `isMoveStock=false` |
| 4 | MMUS:548 | carrier arm, whole-UL; dest must be `unitloadallowed` (Pallet/Cart, ULBS:494) and source `onotherunitloadallowed` (Package/Case, ULBS:490) |
| 5 | MMUS:747-823 `transferStock` | Moves `stockUnits.get(0)` only (:757-759), then relocates the source container (:794-822) |
| 6 | SUBS:283-285 | Stock-arm destinations are any `stockunitallowed` type: Default, PickLocation, Tote, Package, Case (`V2.2.00:3153-3159`); Pallet/Cart are `false` |
| 7 | wms2-mobile-ui `components/moveUnitload/scanDestination.vue:114-118` | `isDamagedDestination` compares the label (analysis b8) |
| 8 | workflow doc §3 :88, §6 :290-296, §10.9 :424 | Location-only wording, stale pins |

**D1 (ACCEPTED, Nam 2026-10-24):** the source side keeps whole-UL `setStockDamaged`/`removeStockDamaged`: after `transferStock` the source container always leaves Damaged (Tote→EmptyTotes, Pallet/Cart→EmptyPallets, Default→Clearing; Case/PickLocation→`sendToNirvana`, which throws `"has stock!"` at ULBS:566 if anything stayed).
**D2 (ACCEPTED, Nam 2026-10-24):** Architect synthesis for the stock arms — option B′.

## 3. Design (option B′)
### 3.1 Resolve once, classify once (F4)
Reads hoisted (not added) out of the fork, all plain, computed once above the damaged block:
- `destinationStorageLocation` (MMUS:408, unchanged);
- `peek = unitloadRepository.findByLabelid(label).orElse(null)` only when the Location is null — hoisted from :492 and **reused there**; never `…ForUpdate`;
- `fla = findByAssignedunitloadId(peek.getId())` **only when `peek != null`** — hoisted from :533 and reused there. `NO_UL` (inbound create or "No destination found", resolved in the fork as today) never reaches this read.

`effDestLocId` = the Location's id, else `peek.getStoragelocationId()`, else `null` (`NO_UL`); `null` means not Damaged/Shipped/Nirvana. Compare with `location_damaged.getId().equals(effDestLocId)` (boxed-Long trap).
After §3.2 step 1, read the Location's `LocationType` (moved from MMUS:431-433, still one read) and classify a private `enum DestArm { LOCATION_WHOLE, FLOWBIN_STOCK, CARRIER_WHOLE, UL_STOCK, FLA_STOCK, NO_UL }` from it, `peek`, `fla` and `dto.isMoveStock()`. Reading the type after step 1 keeps `shouldThrowExceptionWhenDestinationIsNirvana` (unit test :688) and `…IsShipped` (:726) green: they stub a Location with a null `typeId` and no `locationTypeRepository`. Step 1 needs only `effDestLocId`; a Nirvana/Shipped/Damaged Location is never a flow bin.
`isStockArm = FLOWBIN_STOCK | UL_STOCK | FLA_STOCK`. The fork `switch`es on the same value, so the damaged block and the fork cannot drift.
### 3.2 Order (replaces MMUS:408-428)
1. Nirvana / Shipped on `effDestLocId`, messages of MMUS:424/:428.
2. Read `LocationType`, classify `DestArm` (§3.1). **Stock-arm refusal:** `isStockArm && destDamaged` → `BusinessException("Moving stock onto a unit load on Damaged is not allowed! Move the whole unit load to Damaged instead!")` — style of MMUS:439. Runs before the permission check, so it fires with or without the function and makes no access call.
3. Permission once, if `destDamaged || srcDamaged`.
4. Lock writes (whole-UL, D1): §3.3.
5. Fork on `DestArm`.
### 3.3 Lock transitions by arm
| Arm | dest Damaged | src Damaged only | both (KEEP) |
|---|---|---|---|
| Whole-UL (`LOCATION_WHOLE` :457, `CARRIER_WHOLE` :548) | `setStockDamaged(source)` | `removeStockDamaged(source)` | `setStockDamaged(source)`: idempotent on 103 (MMUS:871), sends an empty list. The `else if` no longer strips the lock |
| Stock (`FLOWBIN_STOCK`, `UL_STOCK`, `FLA_STOCK`) | **refused** (§3.2 step 2) | `removeStockDamaged(source)` before the transfer (today, D1) | **refused** |
### 3.4 Post-lock re-check and the residual windows (M3, Arch N1, Critic N2)
- **Stock arms — closed for a concurrent move of the destination UL itself.** In `transferStock`, right after `stockunitBusinessService.transferStockToUnitLoad(...)` (MMUS:782) and before the source re-read and relocation (:794-822), re-check `assignedUnitLoad.getStoragelocationId()` — the passed reference, not a re-query by label — against Damaged and throw `BusinessException("Destination unit load " + assignedUnitLoad.getLabelid() + " was moved onto Damaged during this move! Scan the destination again!")`. Its own message, so the step-2 refusal and the re-check are separately killable (AC-12, IT case 1). SUBS:319 has by then taken UL(dst) `FOR UPDATE` and refreshed that managed instance in place (`LockReads:45-50`; SUBS joins the tenant tx, SUBS:193-194), and a mover of the destination takes UL(dst) at MMUS:367, so the two serialize. Cost: one plain `findByName(Damaged)`. A refusal rolls everything back (principle 2). Compares location ids only — no `getEntityLock()`, so the rail is unaffected.
- **Child destination — residual, shares the carrier window.** If the destination C is a carrier's child and P is moved onto Damaged concurrently, that mover locks only P; its `setStockDamaged(P)` child walk is a plain read (MMUS:859) that cannot see our uncommitted SU, and its `processTransfer` updates C (ULBS:525-526, :557) after our commit. Our re-check sees the pre-move location. Result: our SU NOT_LOCKED on Damaged → Q4. Closing it means locking the carrier chain = option D.
- **Carrier arm — residual, recorded.** `transferUnitLoadToCarrierCore` takes no destination lock: no `LockReads`/`ForUpdate` in ULBS:408-512 (source read is a plain `findById` at :412, destination location at :500). Window between the peek and commit, with a concurrent whole move of P:
  - **onto Damaged:** C lands unlocked on Damaged. Same wrong outcome as today — not a regression. Detector **Q4**.
  - **off Damaged:** we set C to 103; the other mover's `removeStockDamaged(P)` walks `findByCarrierunitloadId` (MMUS:896) without seeing C. C ends 103 off Damaged, where today it ends correctly unlocked — **a narrow regression**, ms-wide, needing two operators on the same pallet, smaller than the authz hole it closes. Detector **Q3**.
  Recorded in the MMUS:339-366 comment block. Propose D only if PRD Q3/Q4 ever go non-zero after merge.
- **Inbound find-or-create — residual, predates SBDEV-3862 (added 2026-10-24, review r3/r4).** `createUnitload(String, …)` returns an EXISTING unit load if one with the label was committed after the plain lookup. That pallet then skips the fixed-assignment and Damaged checks (as before this ticket). The gate check (`assertPalletNotAssignedToGate`) is re-run after the create when `!moveStock`, so the truck case stays covered. Accepted: needs a same-label pallet created within milliseconds.
### 3.5 Out of scope
- **DES not reused:** its Shipped refusal is behind default-OFF `enforcing()` (DES:206) and also refuses any locked destination (DES:185-197).
- **UI (scope 6), follow-up:** `git grep '\$axios' store/moveUnitload.js` on wms2-mobile-ui origin/develop shows only `GET /moveUnitload/selectSource/{label}` and `POST /moveUnitload/selectDestination` (:35, :56); blind spot: components calling `$axios` directly. Neither returns a destination UL's location, so `isDamagedDestination` needs a new read endpoint. Authz is server-side.
- **Message change (F7/L10):** a stock-arm move onto the Nirvana sentinel UL now gets `"Can not move unit load to nirvana location: <id>"` (step 1) instead of `"Can not move stock to <label>"` (MMUS:754). No test pins the old text (`grep -rn "Can not move stock to" src/test` → 0). Note in the PR.
- **Message change (critic r3 L3-3):** Nirvana/Shipped (step 1) now runs before the permission check, so a user without the function moving off Damaged onto Shipped gets the Shipped message instead of `"No permission to alter damaged stock"`. Only the permission text is pinned (unit test :1229). Note in the PR.

## 4. V1/V2 Applicability
v2 only (v1 is reference-only).

## 5. Prerequisites & Implementation Plan
### 5.1 Prerequisites
| # | Prerequisite | Value / action | Notes |
|---|---|---|---|
| 1-4 | DB state · flags · config · deploy order | N/A | No schema change; inline checks; UI follow-up independent |
| 5 | **MERGE GATE: exposure** | PRD Q1 + Q3 + Q4 below, per tenant (Hydra, ShipItEZ ×2, WineCo). Dev (`dev_wh01_om1`, Damaged id 51627): Q1=0, Q3=7, Q4=6 | Blocks merge until run, **or Nam waives it in writing**. Remediating existing rows is NOT decided here (§9) |
| 6 | External systems | OMS stock-change | Same `(0,±N)` shape; after-commit; empty list skipped (`StockChangeNotificationService:35`) |
| 7 | Access | `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` | No new function |
| 8 | Monitoring | Q4 (unlocked on Damaged) + Q3 (103 off Damaged) are the detector pair for the §3.4 windows | No new metric |

"On Damaged" = the SU's **own** UL's `storagelocation_id` (child locations are propagated, ULBS:525-526), so all tenants are measured the same way. Damaged's id differs per tenant, so resolve it by name:
```sql
-- Q1: carriers on Damaged (Pallet or Cart type, or any UL with children)
select count(*) from unitload u where u.storagelocation_id = (select id from location where name='Damaged')
  and (u.type_id in (select id from unitload_type where name in ('Pallet','Cart')) or exists (select 1 from unitload c where c.carrierunitload_id = u.id));
-- Q3: stock units at 103 OFF Damaged
select count(*) from stockunit s join unitload u on u.id = s.unitload_id
 where s.entity_lock = 103 and u.storagelocation_id is distinct from (select id from location where name='Damaged');
-- Q4: stock units ON Damaged not at 103
select count(*) from stockunit s join unitload u on u.id = s.unitload_id
 where u.storagelocation_id = (select id from location where name='Damaged') and s.entity_lock is distinct from 103;
```
### 5.2 Implementation Checklist
1. [ ] **Resolution + classifier + refusals (§3.1-3.2).** AC: G1, G2 (renamed, message updated), AC-7..AC-9, AC-13..AC-20 pass; `shouldThrowExceptionWhenDestinationIsNirvana` and `…IsShipped` stay green; other controls stay green.
2. [ ] **Whole-UL transitions + stock-arm post-lock re-check (§3.3-3.4).** AC: G3, G4, AC-1..AC-5, AC-10, AC-11, AC-12 pass; `MoveSourceLockComparisonRailTest` green unedited.
3. [ ] **IT `MoveUnitloadDamagedPalletIT`** (§6). AC: 4 cases green against real SUBS/ULBS and the real grant chain. Mutation: delete step 2 of §3.2 → case 1 red (the re-check fires instead, with its own message); delete the §3.4 re-check → AC-12 red.
4. [ ] **Full suite vs baseline (M5).** First rebase the branch onto `55a3604a` so both runs share one develop. Then with JDK 21, `mvn clean verify -Pci` on `55a3604a` and on the branch, adjacent in time, one Maven at a time (`pgrep -f maven` first). Diff failures; rerun `OutboxConcurrentEnqueueIT` and `ReplenishDupConcurrencySliceIT` before calling either a regression.
5. [ ] **PIT** (§6) + hand mutation of each new assertion. AC: mutations > 0; no surviving mutant on changed lines, or each justified in the PR.
6. [ ] **Docs + bookkeeping:** workflow doc §3 :88, §6 :290-296 ("the Location or the destination UL's location"; stock-arm refusal; post-lock re-check), §10.9 :424, §12 log row; `verify-docs`. Propose UI follow-up; record D1/D2; run §5.1 #5 or get Nam's waiver.

## 6. Test Plan
Gate tests `012e75f5` stay. G1 carrier refusal, G3 carrier-with-function lock, G4 Damaged→Damaged keep and G5 control remain valid unchanged. **G2** (unit test :1349, `scanDestination_shouldRefuseMoveStock_whenThePalletIsOnDamagedAndTheUserLacksTheFunction`): the TDD-gate step **renames** it `…whenTheUnitLoadIsOnDamaged…` (a Pallet cannot receive stock, Arch N6) and makes it expect the §3.2 stock-arm message and `verifyNoInteractions(accessService, stockunitBusinessService)`; it can no longer use `assertRefusedWithoutTouchingStock` (that helper pins the permission message and an access call). New tests go in nested `ScanDestinationDamagedPermission` (:1132). RED = red on today's code; CONTROL = green today, named mutant it kills.

| AC | Test (new unless G#) | Asserts | RED / CONTROL (mutant killed) |
|---|---|---|---|
| 1 | G3 + `carrierArm_sendsPlusNPerStockUnit_whenLockingOntoAPalletOnDamaged` | 103; one `(0,+N)` per SU | RED |
| 2 | G1 | refused; no save, no transfer | RED |
| 3 | `carrierArm_unlocks_whenLeavingDamagedForAnOrdinaryPallet` | NOT_LOCKED; `(0,−N)` | CONTROL: src-Damaged branch dropped |
| 4 | G4 + `carrierArm_sendsAnEmptyList_whenBothOnDamaged` | stays 103; `verify(messageService).sendStockChangeMessage(argThat(List::isEmpty))`, not `never()` | RED |
| 5 | `carrierArm_refusesBeforeAnyWrite_whenBothOnDamagedWithoutTheFunction` | refused; `stockunitRepository.save` never | CONTROL: permission checked only on destDamaged |
| 6 | G2 (renamed, message updated) | §3.2 message; no access call; SU untouched | RED |
| 7 | `moveStock_refusedEvenWithTheFunction_whenTheUnitLoadIsOnDamaged` | §3.2 message; `stockunitBusinessService` untouched | RED |
| 8 | `fixedAssignmentArm_refused_whenTheAssignedUnitLoadIsOnDamaged` (`isMoveStock=false`) | §3.2 message; `verifyNoInteractions(stockunitBusinessService)` | RED (also kills classifier keyed on `isMoveStock`, and deletion of step 2) |
| 9 | `moveStock_refusedBeforeUnlock_whenBothOnDamaged` | refused; `removeStockDamaged` save never | RED |
| 10 | `moveStock_unlocksBeforeTheTransfer_whenLeavingDamaged` | `InOrder` unlock save → transfer; `−N` | CONTROL: refusal keyed on srcDamaged |
| 11 | `flowBinArm_unlocks_whenLeavingDamaged` | NOT_LOCKED; transfer runs | CONTROL: refusal keyed on `isStockArm && srcDamaged` |
| 12 | `stockArm_refusedAfterTheTransfer_whenTheDestinationMovedOntoDamagedUnderTheLock` (`doAnswer` on `transferStockToUnitLoad` sets dst location to Damaged) | the §3.4 re-check message (exact text); container relocation never | RED |
| 13 | `inboundPallet_refusesBeforeCreateUnitload_whenSourceOnDamagedWithoutTheFunction` | `createUnitload` never | CONTROL: permission moved below the fork |
| 14 | `treatsANullUnitLoadLocationAsNotDamaged` | no access call, no NPE | CONTROL: NPE on null `getStoragelocationId` / null treated as Damaged |
| 15 | G5 | ordinary pallet, no access call | CONTROL: permission unconditional |
| 16 | existing SBDEV-3102 C3 Location-arm tests | green, unedited | CONTROL: Location arm resolved wrongly |
| 17 | `peeksTheDestinationUnitLoadOnceWithoutARowLock` (carrier and moveStock) | `never().findByLabelidForUpdate("PAL001")`; `times(1).findByLabelid("PAL001")`; plus IT case 3 reaches the peek on Postgres | CONTROL: peek switched to `ForUpdate` / read duplicated |
| 18 / 19 | `refuses_whenTheUnitLoadIsOnShipped` / `…OnNirwana` | MMUS:424/:428 messages; no transfer, no access call | RED |
| 20 | `stockArm_ontoTheNirvanaSentinel_getsTheNirvanaLocationMessage` | pins §3.5 message change | RED |

**IT `integration/service/mobile/MoveUnitloadDamagedPalletIT extends BasePostgresIntegrationTest`.** Pattern of `MoveUnitloadLockOrderProbeIT` (`PgLaneFixtures`, TAG cleanup, assert by id — repo tests commit). Real grant chain as in `CancellationReversalDestinationIntegrationTest:263-290` (that class is on `BaseRollbackIntegrationTest`; first confirm `AccessService` resolves the chain on the Postgres base), real `StockunitBusinessService`, no `@MockitoBean AccessService`. Seed ids: Damaged 6, EmptyPallets 9 (`V2.2.00:2467/:2470`); EmptyTotes by name. Destinations are empty (L7). OMS deltas are asserted in unit tests only.
1. Tote S (1 SU, NOT_LOCKED) on an ordinary location; moveStock onto empty Tote T on Damaged, with the grant → refused with the §3.2 message (exact text); S, its SU and T unchanged.
2. Tote S on Damaged with 2 SUs of different items at 103; moveStock onto empty Default D on an ordinary location, with the grant → the SU now under D is NOT_LOCKED; the other SU is under S, NOT_LOCKED, and S is on EmptyTotes (D1). Do not pre-pick which SU moves (`get(0)`, MMUS:757-759, has no guaranteed order).
3. Case C (1 SU, NOT_LOCKED) — a child of an ordinary pallet — moved by the carrier arm onto Pallet P on Damaged, with the grant → C under P, its SU = 103. (Pallet `onotherunitloadallowed=false`, ULBS:490, so a whole pallet cannot go onto a pallet.)
4. Case 3 without the grant → `No permission to alter damaged stock`; nothing changes.
**PIT:** `export JAVA_HOME=$(/usr/libexec/java_home -v 21) && mvn -o test-compile && mvn org.pitest:pitest-maven:mutationCoverage -DtargetClasses=net.aim_ai.wms.service.mobile.MobileMoveUnitloadService -DtargetTests=net.aim_ai.wms.unit.service.mobile.MobileMoveUnitloadServiceUnitTest` (pom :548-553: the target suite must be green first); assert generated mutations > 0 (JDK 25 gives a silent 0%).
### Manual test plan (dev, `wms-dev-probe`)
Users: **panderson** (warehouse access; confirm the function with one query first). **No-function user:** a dev user whose group→role→function chain lacks `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`; if none has warehouse access, delete panderson's granting `mywms_group_mywms_user` row and re-add it in Cleanup (direct user→role grants confer nothing in v2). Stock-arm rows are **API-only** (`api.sh POST /moveUnitload/selectDestination` with `"moveStock":true`).
**Restore proof:** `snapshot.sh` proves, it does not restore. Before seeding: `snapshot.sh save sbdev3862 "<SELECT>"` where SELECT returns, for the chosen ids only, `unitload(id, storagelocation_id, carrierunitload_id)` of P, P2, T, T2, U, R, the Case and its original parent O; `stockunit(id, unitload_id, entity_lock, amount)` of their SUs; and panderson's `mywms_group_mywms_user` rows. After Cleanup: `snapshot.sh diff sbdev3862`.
**Not restored (list in the report):** real `+N`/`−N` stock-change messages sent to the **dev OMS** (LOCK, UNLOCK, U's seed and their cleanup reversals); `stockunit.additionalcontent` overwritten by every set/remove (MMUS:877, :916); `stockrecord` history and burned sequence ids.

| Scenario | Precondition (query at run time) | Steps | Expected | P/F |
|---|---|---|---|---|
| Seed | Q5 empty pallets P, P2 (209 on 10-23); empty Totes T, T2 (both taken from EmptyTotes); a 1-SU Case under pallet O; a 1-SU Tote U on an ordinary location | `snapshot.sh save`; Location arm moves P, P2, T and U to `Damaged` | P, P2, T on Damaged; U's SU 103 (OMS `+N`) | |
| Carrier LOCK, no function | P | no-function user moves the Case onto P | `No permission to alter damaged stock`; DB unchanged | |
| Carrier LOCK, function | P | panderson moves the Case onto P | Case under P; its SU 103; OMS `+N` | |
| Carrier KEEP | Case on P (103); P2 | panderson moves the Case P→P2 | SU stays 103; no OMS delta | |
| Stock-arm refusal | T; a 1-SU Tote/Default source R on an ordinary location | API moveStock R onto T, as panderson | §3.2 message; DB unchanged | |
| Stock-arm UNLOCK | U on Damaged (103); T2 | API moveStock U → T2, as panderson | SU under T2, NOT_LOCKED; `−N`; U on EmptyTotes | |
| Shipped / Nirwana | Q7: Shipped 15,889, Nirwana 11 pallets | carrier move of the Case onto one of each | `Can not move unit load to shipped/nirvana location` first | |
| Cleanup | — | panderson: Case P2→O (carrier, `−N`); Location arm U → its original location; API moveStock T2 → U (T2 → EmptyTotes); Location arm P, P2 → EmptyPallets, T → EmptyTotes; re-add the group row if removed | — | |
| Restore | — | `snapshot.sh diff sbdev3862` | Zero drift | |
No verify script (T3 opt-in declined).

## 7. Horizontal Scalability Validation
Pool math: peek and FLA reads hoisted and reused (0 net); +1 `findByName` in the post-lock re-check, same connection. Distributed lock: unchanged — UL(src) first (MMUS:367); stock arms re-checked under SUBS:319; carrier and child-destination windows recorded (§3.4). External notifications: after-commit; a refusal or rollback sends nothing. All other rows (in-JVM state, long tx, retry, …) No/N/A. **v2 constraints:** OSIV yes (all reads inside MMUS:318) · tx manager unchanged · readOnly N/A · Caffeine no · H2 SQL N/A (Testcontainers) · controller test N/A · metrics no.

## 8. Notes: Layer 2 completeness
All 11 concerns considered, each answered in its section (DB §5.1 #5, callsites §2, concurrency §3.4 + AC-12/17, compat §3.5, tests §6).
Open until run: PRD exposure (§5.1 #5). Adjacent bugs kept out: P21, the mobile-UI flag, stranded Q3/Q4 rows (§9). v1 reference-only.

## 9. ADR
Decision, drivers, alternatives and why chosen: the RALPLAN-DR summary above (B′, D2).
- **Consequences:** moving loose stock into a container on Damaged is refused for everyone; operators move the whole unit load. Whole-UL KEEP sends an empty list and overwrites `stockunit.additionalcontent` with the new comment (MMUS:877), replacing the original damage reason — same as today's Location-arm Damaged→Damaged. Two residual windows (§3.4): onto Damaged (child destination or carrier arm, not a regression) → Q4; carrier arm off Damaged (narrow regression) → Q3.
- **Follow-ups (Nam decides):** remediation of existing stranded rows (dev Q4=6, Q3=7; PRD unknown) — repair, OMS reconciliation, or none · option D if PRD Q3/Q4 go non-zero after merge · a move-stock-to-Damaged feature (B's `lockOne`, with H1's amount rule) if a client ever needs it · P21 · mobile-UI `isDamagedDestination` + read endpoint.

**OMC composition:** T3 → ralplan round 3 (Critic diff-check) → `wms-tdd-gate` (extends `012e75f5`, renames + updates G2) → `wms-plan-executor` with 4 lanes.

## 10. Review disposition
Rounds 1-2 dispositions: `.omc/research/SBDEV-3862-review-dispositions.md`.

## 11. Implementation Status (2026-10-25)
- **PR:** https://github.com/SiteBossInc/wms2-api/pull/566 → `develop`. Branch `bugfix/SBDEV-3862-damaged-pallet-destination`. **Do not merge until §5.1 #5 (PRD Q1/Q3/Q4) has been run.**
- **Commits:**
  - Gate: `2107f737`, `a7b13c07`.
  - Fix: `4029195a` (§3.1-3.3), `09bf1861` (§3.4).
  - Review round 1: `712817ce`, `4b9742dd`.
  - Rails: `65947d4e`.
  - Rounds 2-3: `79b17c25`, `907f4487`.
  - Rounds 4-6, tests and comments only: `31c8ed9c`, `5cc2e8fc`, `c60c14e7`.
  - Only `MobileMoveUnitloadService.java` changed in `src/main`.
- **Tests:**
  - `MobileMoveUnitloadServiceUnitTest.ScanDestinationDamagedPermission`: AC-1..20 plus review-driven tests. The class has 138 tests.
  - `MoveUnitloadDamagedPalletIT`: 5 cases (Postgres, real grant chain, real `StockunitBusinessService`).
- **Full suite** (`mvn clean verify -Pci`, JDK 21):
  - Baseline `55a3604a`: surefire 8770/0F (1 skipped), failsafe 995/0F (23 skipped).
  - Branch `907f4487` on a fresh Testcontainers DB: 8801/0F (1 skipped) and 1000/0F (23 skipped).
  - Tip `c60c14e7`, targeted: 167/0.
  - An earlier run (`79b17c25`) had 5 IT reds caused by the reused container (seqentities guard, message-page residue). Dropping the container cleared them.
- **PIT** (`MobileMoveUnitloadService`): 188 mutations, 145 killed, test strength 94%. The 9 un-killed mutants on changed lines are `orElseThrow` supplier lambdas or the re-indented pre-existing "Pallet not empty!" check. Every new assertion was also hand mutation-checked.
- **Deviations from the plan, all reviewed:**
  - D-M1: the stock-arm re-check re-takes the destination via `LockReads`, using the tenant EM.
  - D-L1: the flow-bin arm uses the existing assignment's UL location.
  - The carrier arm's truck/fence/gate checks moved before the lock writes, to preserve their messages.
  - Inbound find-or-create re-gate (§3.4).
  - Null `sltname` is treated as a whole-UL Location.
  - T1 (carrier lock) and E2 (location-id messages) were declined by Nam.
  - Ralph was not used: the omc CLI was shadowed. An Opus executor ran under the same contract.
- **Reviews:** conformance PASS; code review 1M/7L/8N fixed; scoped re-reviews r2-r7 on every fix commit. Reviewed SHA = tip `c60c14e7`. Reports are in `.omc/research/SBDEV-3862-*.md`.
- **Docs:** `wms2-move-stock-unitload-workflow.md` §3/§6/§10.9/§12, marked ✓ merged(SBDEV-3862: #566 ab983389, 2026-10-25).
- **Proposed siblings:** P21 (extended with S2) and P22 (mobile put-away), plus Q3/Q4 monitoring.

### Merged to develop — on dev (2026-10-25)
- **Merge:** PR #566, commit `ab983389`, graded head `f29d83f8`. That head merged origin/develop `063eb2ed` into the branch with **no conflicts**, so no resolution commit was needed.
- **Suite on the merge:**
  - Local `mvn clean verify -Pci` (fresh container): BUILD SUCCESS, IT 1000/0.
  - PR CI run 40194513914: the first attempt red on `TenantWarehouseProvisioningIntegrationTest.busyLockIsRefused`, an unrelated advisory-lock release race. The re-run of the failed job was green (unit 8842/0, IT 1000/0).
- **Develop CI:** run 40197307145, test and build both succeeded.
- **Deploy:** dev serves `develop-ab983389…` (drift false). `post-merge-verify.sh` reported ALL PROVEN.
- **Bookkeeping:** ClickUp is at `on dev` with a status block. 10 `⏳ pending-merge(SBDEV-3862)` markers were flipped (workflow doc ×9, this plan ×1).
- **Next:** the manual dev test (§6), then `archive-plan`. The mobile-UI `isDamagedDestination` prompt is a follow-up.

### Manual dev test (2026-10-25, `develop-ab983389`)
- **Passed:** stock-arm refusal; carrier refusal with no function (temporary `MOBILE_UI_VIEW_TRANSFER`-only grant, with a same-path control); Shipped/Nirwana refusals; control moves with the function.
- **Not run:** carrier LOCK/KEEP and stock-arm UNLOCK. Dev's `Damaged` location type admits only Case/PickLocation, so no Pallet or Tote can stand there, and UNLOCK would move stock the product can't put back.
- **Restore:** `snapshot.sh diff` reports restored for both snapshots (12 + 4 rows), and the temporary group/role are deleted.
- **Side effects:** stockrecord history for 4 control moves; no OMS deltas.
- Full details are in the ticket comment.

## Archive note (2026-10-25)
> Archived 2026-10-25: merged as #566 `ab983389`, on dev, dev-tested the same day (§11). No verify script.
> Implementation worktree(s) removed 2026-10-25: wms2-api/SBDEV-3862

**Findings disposition:**
- §3.4 child-destination and carrier-arm race windows: **Dropped.** Accepted by Nam (T1 declined). Any rows they create show up in Q3/Q4, which P24 tracks.
- §3.4 inbound find-or-create: **Dropped.** It predates this ticket and needs a same-label pallet created within milliseconds.
- Stranded rows, Q3/Q4 monitoring and option D: **Proposed, P24.**
- Mobile-UI `isDamagedDestination` plus a read endpoint: **Proposed, P23.**
- `StockunitService` existing-container path: **Proposed, P21.**
- Move-stock-to-Damaged feature: **Dropped.** No client has asked for it.
- §5 step 6 docs/bookkeeping: **Fixed.** Workflow-doc markers flipped to #566 `ab983389`; the PRD gate ran 2026-10-25.
