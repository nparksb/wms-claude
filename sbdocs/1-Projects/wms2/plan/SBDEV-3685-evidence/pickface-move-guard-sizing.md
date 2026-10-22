---
ticket: "SBDEV-3758"
ticket_url: "https://app.clickup.com/t/868mh12g6"
found_during: "SBDEV-3685"
kind: evidence
created: 2026-10-13
status: reviewed — critic round 1 REVISE (0H/5M/6L) applied; see review-pickface-sizing.md
---

# Pick-face container leaves its bin: cause and sizing

## Symptom (WineCo PRD, read-only)

- **3 dangling FLAs.** 8071264, 23958473 and 817243415 point at a pick-face UL that is now in Nirwana. Their bins are 11-D06, 11-C09 and 45-B01, and all three bins are empty. The SKUs have 0 live stock, 0 open positions and 0 open replens.
- **The incidents.** `unitload_record` was filtered on `TRANSFERRED`, `fromlocation = label`, a destination that is a transfer or staging lane, and `activitycode IS NULL`, from 2025-01-01. It returns **4 events**. Each was followed by a `SEND_TO_NIRWANA` from the lane carrying the transfer order number, after 22–27 h. That send is BOL build-truck `combineStock` draining the lane (`CODE_TRANSFER_BUILD_TRUCK`).

  | when | label | to | operator | Nirwana send | transfer order |
  |---|---|---|---|---|---|
  | 2026-07-15 17:48 | 50-C01 | TransferLane07 | adampetersen | 07-16 20:51 | 061312-000001 |
  | 2026-09-16 21:28 | 11-D06 | TransferLane08 | adriantorres | 09-17 14:05 | 062104-000001 |
  | 2026-09-16 21:28 | 11-C09 | TransferLane08 | adriantorres | 09-17 14:05 | 062104-000001 |
  | 2026-10-09 00:20 | 45-B01 | TransferLane06 | adampetersen | 10-09 19:03 | 062681-000001 |

- **50-C01 was repaired by hand.** Its FLA was created 07-27, deleted 07-31 and created 08-11. It was then deleted 08-25, created 09-01, and deleted and created again 09-30. Those later cycles may be unrelated churn; this is an open question.
- **Population.** All 1,556 WineCo FLA ULs are type `PickLocation` (reviewer). Since 2025, every PickLocation move off its location is accounted for: FLA deletes, manual removals of non-bin labels, the 4 incidents with their 4 Nirwana follow-ups, and one move out of Damaged. Other PRD tenants have **0 FLAs whose UL is off its bin**: c1wh-shipitez (846 FLAs, 5 transfer orders), nywh-hydra (135, 3) and nywh-shipitez (31, 0).

## Cause (origin/develop 8553299d; same on origin/main)

`MobileTransferOrderService.transferStock`, "move whole stock unit" branch (available ≤ amount left, reserved = 0). When the source UL is fix-assigned, it relocates **the pick-face container itself**: `transferUnitLoadToLocation(unitLoad, transferLane, false, null, null, null)`. Otherwise it splits. The arm writes no stockrecord.

An integration test pins this as intended: SBDEV-3240 PostgreSQL IT `transferOrder_MoveBothUnitLoadsTest` asserts both FLA containers land on the transfer lane.

## Whole-UL routes and whether they can strand a pick face

| route | guard |
|---|---|
| Mobile transfer-order pick (`MobileTransferOrderService.transferStock`) | **none: relocates it by design (the cause)** |
| Mobile Move Unit Load: scan + destination (SBDEV-3490) | refuses, `"Cannot move fixed assigned unit load "` |
| Web Move Stock, container arm (`StockunitService.transferStock`) | refuses **only while the UL is on its bin**. `flaOpt` is keyed on the UL's *current* location, so a stranded UL moves freely. PRD: 45-B01 moved TransferLane06 → TransferLane06, `MANUAL_TRANSFER`, 3 min after the incident |
| **Web Delete Unit Load** (`UnitloadService.deleteUnitLoad` → `sendToNirvana`, `CODE_MANUAL_REMOVAL`) | **none.** It leaves the same end state (active FLA → Nirwana UL). No PRD occurrence since 2025 |
| **Mobile putaway store box / store pallet** (`MobilePutAwayService`) | **none on the source.** The UL is resolved by label only. The UI offers inbound boxes only, but a hand-made request naming a bin label would relocate a pick face. No PRD occurrence |
| SDR `Unitload` writes (PATCH `storagelocationId`) | not checked; the SDR un-export programme may cover it |

## Fix options

- **A: delete the FLA branch in the transfer-order pick.**
  - The existing `else` already splits, and `transferStockToUnitLoad` keeps an FLA source's UL and a 0-amount stock unit on the bin (`… || fixLocationAssignment != null` mints a fresh destination SU). `removeUnitLoadIfEmpty` is moot for an FLA source. The FLA-source split already runs in production through the partial and reserved > 0 arms.
  - Effects: `CODE_MANUAL_SPLIT` is PASS_THROUGH for pick-line realignment. The lock checks are at least as strict as `SourceLockGuard` and run under a row lock. It adds the stockrecords the old arm never wrote. Build-truck drains minted lane ULs the same way (same order 10-09 drained 7 such).
  - Keep `SourceLockGuard` ahead of the `createUnitload` mint for the whole-stock case. Otherwise a lock refusal leaves an empty minted UL on the lane, because the method is not `@Transactional`.
  - Fix the stale `// is from flowbin` comment.
  - Tests: invert `transferOrder_MoveBothUnitLoadsTest`, then re-express the 5 unit tests that pin the arm. Add an end-state test: bin keeps its FLA UL with a 0 SU; lane holds a minted UL with the amount and a `MANUAL_SPLIT` stockrecord pair.
  - **Tier T2** (multi-file, an intended-behaviour pin inverted, a PostgreSQL IT), about ½ day.
- **B: invariant guard in `UnitloadBusinessService.transferUnitLoadToLocation`.** This is a separate proposal with its own tier call, not a rider on A.
  - Rule: refuse when the **source is the FLA's assigned location and the destination differs**. Keying on "the UL is an FLA's assigned UL" would stop build-truck retiring an already-stranded UL and roll back the whole transfer.
  - Allow-list: `CODE_MOVE_FIX_ASSIGNMENT`, the FLA-delete Nirwana send, and the on-hold self-move. Decide `MANUAL_REMOVAL` (web Delete Unit Load).
  - It does not cover the carrier/cart moves or the web Move Stock stranded hole.
  - 23 call sites on develop (20 outside `UnitloadBusinessService`, 3 inside). The "24" in a code comment is stale.
  - **Tier T2+** (central method, a web-screen behaviour change), about 1 day.
- **Web Delete Unit Load FLA guard.** Small and independent; one could argue it belongs with B.

## Couplings

- **None with SBDEV-3755.** That was a mistake in the draft, corrected here. PR #510 does not touch `StockunitBusinessService`. 3755's planned replen-held refusal skips FLA sources (`fixLocationAssignment == null && …`), so A cannot be refused by it. The only overlap is a shared test file.
- **No OMS impact.** For transfer batches OMS gets the build-truck parcel label (`BillofladingService`, `parcelExternalNumber`), not lane UL labels.

## Repair of the live rows

Delete the FLA in the web UI, then re-create it if the bin should keep the SKU. `FixLocationAssignmentService.delete` skips the UL retire when the UL is already in Nirwana. It refuses while any active replen exists for the SKU; there are 0 today.

## Routing

SBDEV-3685's PR #511 is merged to develop, which is a dev deploy. Adding unrelated scope there would muddy its status ladder. Its cron-load scope is also unrelated. **Filed as SBDEV-3758** (Nam confirmed 2026-10-13): fix A in scope; B and the delete-UL guard are ranked follow-ons.
