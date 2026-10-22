---
ticket: "SBDEV-3685"
kind: review
reviews: "pickface-move-guard-sizing.md"
created: 2026-10-13
reviewer: critic lane (review-pickface)
verdict: "REVISE — 0 High / 5 Medium / 6 Low"
code_base: "wms2-api origin/develop 8553299d (fetched 2026-10-13); arm identical on origin/main 0dfb0d4d"
db: "wsl-wineco-prd, c1wh-shipitez-prd, nywh-hydra-prd (read-only)"
---

# Review: pick-face container leaves its bin (cause and sizing)

**Verdict: REVISE.** The cause is right, and option A is the right fix. The coupling section is wrong, the test inventory and the "other paths refuse it" claim are incomplete, and option B is under-specified. None of this changes the recommendation (do A). All of it changes what the executor is told.

## What holds up (checked, not taken on trust)

- **The cause is the only path, on every PRD tenant.** All 1,556 WineCo FLA ULs are type `PickLocation` (1,553 have label = bin name; the other 3 are the mangled ones). So a type-scoped census covers every FLA UL. Since 2025-01-01, every `TRANSFERRED` row for a `PickLocation` UL with `fromlocation <> tolocation` falls into one of these groups:
  - `DELETE_FIX_ASSIGNMENT` → Nirwana: 2,812 rows (legitimate).
  - `MANUAL_REMOVAL` → Nirwana: 100 rows. All 100 have labels that are not location names, so none is a pick face.
  - `<null>` → TransferLane: **4** (the four incidents).
  - `SEND_TO_NIRWANA`: 4, the follow-ups.
  - `MANUAL_TRANSFER`: 1, `UL342017`, Damaged → TransferLane02, not a bin.

  c1wh-shipitez has only `DELETE_FIX_ASSIGNMENT` plus one row from Damaged. nywh-hydra has only `DELETE_FIX_ASSIGNMENT`. The only null-activity-code writer is `MobileTransferOrderService.java:424`. Every other `transferUnitLoadToLocation` caller passes a constant.
- **The 3 dangling FLAs are confirmed:** 8071264 (11-D06), 23958473 (11-C09) and 817243415 (45-B01). Each UL is on Nirwana, labelled `-X-`, with entity_lock 2, 0 SUs and 0 ULs on the bin.
- **The split keeps the pick face on its bin.** In `StockunitBusinessService.java:320-328`, the FLA is resolved by the source location, and `fla != null` creates a placeholder destination SU. The source SU stays at amount 0. The emptied-source cleanup at `:416` is gated on `fixLocationAssignment == null`, so the pick-face UL is never retired.
- **Pick-line classification.** `CODE_MANUAL_SPLIT` is `PASS_THROUGH` (`PickLineActivityCodeClassifier.java:42`). The arm requires reserved = 0, and the source SU (which a pick line would reference) stays on the bin, so nothing needs realigning.
- **Lock policy is at least equivalent.** `ignoreLock=false` checks the same source SU, UL and location as `SourceLockGuard.java:16-28`, but under `FOR UPDATE` instead of a plain re-read. It also checks the destination UL and location. A PASS_THROUGH code takes no Pickingorder lock, so the lock-order reason for avoiding `FOR UPDATE` (`MobileTransferOrderService.java:417-421`) does not apply.
- **Option A is strictly better in two further ways.** The doc should say so:
  - **Audit trail.** Today's arm writes no stockrecord. For 45-B01 on 10-09, the only stockrecords are the later `MANUAL_TRANSFER` and `TRANSFER_BUILD_TRUCK` rows. The split writes `recordRemoval` and `recordCreation`.
  - **Reservation race.** Today the reserved = 0 test runs on the controller's detached row and the whole container moves anyway. The split re-checks `amount <= amount - reserved` under the row lock (`:206`).
- **Downstream, the transfer is container-agnostic.** `BillofladingService` build-truck reads `findByStoragelocationId(transferLane)` and calls `combineStock` → `transferStockToUnitLoad(…, CODE_TRANSFER_BUILD_TRUCK, order, …, removeUnitLoadIfEmpty=true, transferLaneFla)`. That drains each lane UL into the parcel (`:1099-1137`, `:907-929`). Nothing keys on the lane container's label.
  - On 10-09, the same order 062681-000001 drained seven minted ULs (`UL357062`–`UL357068`) the same way as `45-B01`. Option A's end state is therefore the path every other transfer already takes.
  - The `SEND_TO_NIRWANA` row carries the order number because it comes from inside `transferStockToUnitLoad` (`:402` → `relocateEmptiedContainer` → `PickLocation` falls to `default` → `sendToNirvana`). It does not come from the `emptyUnitLoadList` loop, which passes `null`.

## Medium

### M1. The SBDEV-3755 / PR #510 coupling is false on both counts
The doc says: `PR #510 / SBDEV-3755 Fix 1 … makes transferStockToUnitLoad refuse replen-held stock … Option A routes the FLA arm through that method, so it inherits the refusal.`

- **PR #510 does not contain Fix 1.** `gh pr view 510` shows it touches `ReplenishorderRepository`, `ReplenishmentOrderMessages`, `ReplenishorderService`, `MobileMoveUnitloadService` and tests. It does not touch `StockunitBusinessService`. The 3755 plan names #510 as its **base** (frontmatter `base_commit`, §7 row 4). Fix 1 is a later, separate branch.
- **3755's guard excludes FLA sources by construction.** Its predicate is `displacing = fixLocationAssignment == null && sourceStockunit.getAmount().compareTo(amount) <= 0`. Its javadoc names *"FLA drain-to-zero is excluded on purpose"* (3755 plan, Fix A step 2). Option A's FLA split has `fla != null`, so it can never be refused by 3755. The 3755 plan also checked this arm and recorded it as P-1: 0 FLA-sourced replens in 180 days on all 4 PRD tenants.
- **Fix:** replace the bullet with: "No behavioural coupling. 3755 Fix A excludes `fla != null`. Merge-order only: 3755 §6 migrates `MobileTransferOrderServiceUnitTest:1027` (`never()` → `verifyNoTransfer`), so whichever lands second rebases that test file."

### M2. "One file, plus the SBDEV-3341 tests" understates the change: a PostgreSQL IT pins the defect as intended behaviour
- `MobileTransferOrderServiceIntegrationTest.transferOrder_MoveBothUnitLoadsTest` (SBDEV-3240) deliberately gives both sources an FLA (fixture comment at `:59-61`, `:235-244`). It then asserts that both containers are now on the transfer lane: `movedUnitload1/2.getStoragelocationId() == transferLaneAfter.getId()`, with the comment *"Both moves relocate the whole unit load (transferUnitLoadToLocation)"*. That is the defect, written down as the contract. Option A makes it red, and it must be **inverted** (the UL stays on its bin, a minted UL holds the stock), not deleted.
- Unit tests that pin the arm: `MobileTransferOrderServiceUnitTest:713` (`shouldMoveWholeStockUnitWhenNoReservedAmountAndFixedLocation`, verify at `:740`), `:759`, `:792` (SourceLockGuard refusals through the relocation arm), `:1036` and `:1081` (`shouldRelocateTheContainer_whenAFixedAssignedCaseIsMovedWhole`, verify at `:1092`).
- **Fix:** list these by name in the sizing. Make the IT inversion the acceptance test: a mutant that restores `transferUnitLoadToLocation` must turn it red. Re-size A as **T2**, not T1–T2: a PostgreSQL IT whose stated contract flips is not a T1 change.

### M3. "The other whole-container move paths already refuse or avoid this" is incomplete
The doc lists two paths. Enumerating every operator-reachable route that can take an FLA UL off its bin:

| Route | Code | FLA UL refused? |
|---|---|---|
| Mobile transfer order | `MobileTransferOrderService.java:424` | **No.** This is the defect. |
| Mobile Move UL (scan + destination) | `MobileMoveUnitloadService.java:176-179`, `:380-381` | Yes |
| Mobile Move UL drain → empty pool | `:781/:785` | Only Pallet, Cart and Tote. Behind the guard above. |
| Web Move Stock, container arm | `StockunitService.java:518-542` | Yes **while on its bin only**. `flaOpt` is keyed on the UL's *current* location (`:433`, `findByAssignedlocationId(ulLocation)`), not on the UL's assignment. Once stranded on a lane, the UL relocates freely: PRD 45-B01, 2026-10-09 00:23, `MANUAL_TRANSFER` TransferLane06 → TransferLane06 by the same operator, 3 minutes after the incident. |
| **Web Delete Unit Load** | `UnitloadService.deleteUnitLoad` (`:716-758`) → `sendToNirvana(…, CODE_MANUAL_REMOVAL)` | **No FLA guard.** The result is the same as the incident: an active FLA pointing at a Nirwana UL. No PRD occurrence since 2025 (all 100 `MANUAL_REMOVAL` PickLocation rows are non-bin labels), but the code path is open. |
| **Mobile putaway store box / store pallet** | `MobilePutAwayService.storeBoxOnLocation` (`:513-586`), `storePalletOnLocation` (`:170-191`) | **No source guard.** The UL is resolved by label alone, with no type, area or FLA check. The UI only offers inbound boxes, but a replayed or hand-made request naming a bin label (e.g. `11-D06`) at an overstock or stock location relocates the pick face whole (`:582`). No PRD occurrence. |
| Receiving assign / unassign inbound pallet | `ReceivingService.java:717-772` | Yes (`requirePalletType`) |
| FLA move / delete | `FixLocationAssignmentService.java:163`, `:272` | Legitimate |
| Set on-hold | `StockunitService.java:745` | Moves to its own location, so it never leaves the bin |
| Picking, packing, palletising, truck loading, put-away assign, cycle count | totes, parcels, pallets; cycle count has no UL move | Not reachable for a PickLocation UL |

- **Fix:** replace the sentence with this table, or the rule it implies. Then decide on the two open rows: Delete Unit Load and putaway-by-label. They are the argument for B, or for a narrower B (see M4). As written, the doc uses the completeness claim to make B look optional, and the claim is false.

### M4. Option B's rule is ambiguous, and the wrong reading breaks build-truck
The doc says: `an FLA's assigned UL may leave its assigned location only through CODE_MOVE_FIX_ASSIGNMENT … or the FLA-delete Nirwana send.`
- **Reading 1:** the guard keys on "the moved UL is some FLA's `assignedunitload`".
  - A UL already stranded on a lane (the state of all four incidents between the arm and build-truck) then cannot be moved at all.
  - Build-truck's own `relocateEmptiedContainer` → `sendToNirvana` (`UnitloadBusinessService.java:585`) is refused, so `closeBOL`/build-truck rolls back for the whole transfer order.
  - That turns a data defect into a stuck transfer.
- **Reading 2:** the guard keys on source location == `fla.assignedlocationId` and destination ≠ source. This is what the prose says ("leave its assigned location"), but the doc never pins it.
  - On-hold's self-move (`StockunitService.java:745`) must pass, which only reading 2 allows.
- **Not fenced by B:** `transferUnitLoadToCarrier` / `transferUnitLoadToCart` (`UnitloadBusinessService.java:348-408`) change a UL's location without passing through `transferUnitLoadToLocation`. Today the only operator route there (`MobileMoveUnitloadService.java:526`) is behind the scan guard. Still, an "invariant in the central method" fences one mechanism, not the invariant.
- **The allow-list must decide `CODE_MANUAL_REMOVAL`** (web delete, M3). Allowing it keeps today's hole. Refusing it changes a web screen's behaviour and needs a message.
- **Fix:** state reading 2 explicitly (source = assigned location, destination ≠ source). List the allowed codes: `MOVE_FIX_ASSIGNMENT`, `DELETE_FIX_ASSIGNMENT`, and a decision on `MANUAL_REMOVAL`. Name the carrier methods as out of scope, with the reason. Add an acceptance test: "a stranded FLA UL on a lane is still drained and retired by build-truck".

### M5. Ticket placement is not addressed, and SBDEV-3685 is already on dev
`origin/develop` 8553299d is `Merge pull request #511 … SBDEV-3685-prefetch-assigned-locations` (e0c3033a). A merge to wms2 develop is a dev deploy. Under the wms-triage ticket policy carve-out, new scope on a ticket that is already `on dev` or later is **proposed as a new ticket**, not added. The doc proposes A, B and sizing without saying which ticket they go on.
- **Fix:** add a "Ticket" line. Check SBDEV-3685's ClickUp status. If it is `on dev` or later, propose a new ticket: A at T2, B as a separate proposal with its blast radius (23 call sites, one extra indexed lookup each).

## Low

- **L1. `removeUnitLoadIfEmpty=false` is moot, and A reduces to deleting the branch.** For an FLA source, the only use of `removeUnitLoadIfEmpty` is inside `if (fixLocationAssignment == null && …)` (`StockunitBusinessService.java:416-422`). Today's `else` arm (`MobileTransferOrderService.java:425-430`, `true`) therefore already does exactly what option A describes. The FLA-source split is already exercised in production by the partial (`:439-440`) and reserved > 0 (`:433-435`) arms. A = delete the `if (findByAssignedunitloadId…)` branch and keep the else. Fix the stale `// is from flowbin` comment while there. Presenting `false` as load-bearing will mislead a reviewer.
- **L2. A moves the lock refusal after a committed write.** `transferStock` and `TransferOrderController` are not `@Transactional`, and `UnitloadService.createUnitload` has no `@Transactional` of its own. So the minted lane UL is saved (and its label drawn) before `transferStockToUnitLoad` refuses a locked source. Today the FLA arm refuses in `SourceLockGuard` before any write. The result is an empty UL left on the transfer lane, which build-truck later retires through `emptyUnitLoadList`. The other arms already behave this way. Either keep `SourceLockGuard.assertSourceUnlockedForContainerRelocation` ahead of `createUnitload` for the whole-stock case, or record the orphan as accepted.
- **L3. The "OMS-visible label change" claim is unsupported.** For transfer batches, `BillofladingService.java:611-614` sends `parcelExternalNumber` from the BOL position's source, which is the parcel built at build-truck (`createUnitload(customerOrder.getParcelexternalnumber(), …)`, `:899`). The lane containers are drained into that parcel and never reach OMS by label. Drop the bullet, or cite the payload field that carries the lane label.
- **L4. There are 23 `transferUnitLoadToLocation` call sites on develop, not 24:** 20 outside `UnitloadBusinessService` plus 3 inside (`:585`, `:673`, `:698`). The "24" probably comes from the stale comment at `UnitloadBusinessService.java` (location-constraint block, "This throw site has 24 call sites"). Count with `git grep`; do not copy the comment.
- **L5. Symptom-table inaccuracies.**
  - "Followed within a day": 50-C01 went 07-15 17:48 → 07-16 20:51, which is 27 h.
  - The 50-C01 repair history stops at 08-11. PRD shows more `DELETE_FIX_ASSIGNMENT`/`CREATE_FIX_ASSIGNMENT` cycles: 08-25 delete, 09-01 create, 09-30 delete and create. Either the hand repair needed three more passes or the bin is churned for another reason. Worth one line, since it feeds the "recurring cost" argument.
  - "Transfer completion then empties it" should name the mechanism: `BillofladingService` build-truck `combineStock`, `CODE_TRANSFER_BUILD_TRUCK`.
- **L6. Sizing wording.**
  - "A alone: T1–T2, about 2–4 h": after M2 this is T2. The time is plausible, but the IT inversion runs on the PostgreSQL lane.
  - "A + B: T2": B adds a refusal to a central method with 23 callers, a web-screen behaviour change (M3, delete UL) and the M4 build-truck hazard. It should be its own proposal with its own tier call, not a rider on A.

## What's missing

- A one-line repair note for the **3 live dangling FLAs**. `FixLocationAssignmentService` delete skips the retire when the UL is already on Nirwana (`:256`), so "delete FLA, then re-create" works. Note, though, that it refuses while any active replen exists for the SKU (`:245-247`).
- An acceptance test for the end state, not just the call: after A, the bin still holds its FLA UL with a 0-amount SU, and the lane holds a minted UL with the moved amount and a `MANUAL_SPLIT` removal/creation stockrecord pair.
- Whether the stranded-UL hole in web Move Stock (M3 row 4) is in scope. It is harmless once A removes the only way to strand a UL, but B in reading 2 would not cover it either.

## Open questions (unscored)

- SDR exposure of `Unitload` writes (PATCH `storagelocationId`) would bypass every guard above. This was not checked here; the SDR un-export programme may already cover it.
- Why 50-C01 needed repeated FLA re-creation after the 07-27 repair (L5). It is possibly unrelated churn.
