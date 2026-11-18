---
ticket: "SBDEV-3999"
kind: evidence
lane: architect consult (one question)
created: 2026-11-03
base: origin/develop bcd20905 (v2/wms2-api), read via git show / git grep only
---

# Architect consult: FLA source-bin guard in `transferUnitLoadToLocation`

## Verdict (short)

The allow-list is **complete for every legitimate flow on develop**, but should change in three ways:

1. **Drop `CODE_ON_HOLD`.** The on-hold move is a self-move and the predicate (`destination != source`) already lets it through. An allow-list entry is redundant, and it would also bless any future cross-location `CODE_ON_HOLD` call.
2. **Narrow the predicate (recommended).** Refuse only when the source is the FLA's bin **and** `unitload.id == fla.assignedunitloadId`. This is still keyed on the source, so BOL build-truck can still retire a stranded FLA UL (its source is the lane, not the bin). It also stops the guard from refusing moves of a *foreign* UL that sits on an FLA bin, such as a cycle-count zero, a GR-position delete, the empty-pallet job or the operator who clears it off. PRD has 0 such ULs today. They are an anomaly to be cleaned up, not protected.
3. **Web Delete Unit Load needs no new allow-list entry.** `CODE_MANUAL_REMOVAL` is not on the list, so the central guard already refuses it, and `deleteUnitLoad` is `@Transactional`, so the stock-unit retires before it roll back. The extra check is still worth adding, but put it in **`UnitLoadController.bulkDeleteContainer`'s pre-scan** next to `alreadyToDelete`. The bulk loop has no outer transaction, so a refusal raised mid-loop leaves the earlier ULs already deleted.

Keep `CODE_MOVE_FIX_ASSIGNMENT` and `CODE_DELETE_FIX_ASSIGNMENT`: both are required (see §2).

## 1. Enumeration

**Instrument A, direct callers.** Command: `git grep -n "transferUnitLoadToLocation(" origin/develop -- 'src/main/**/*.java'`, then drop comment lines (`//`, `*`) and the `public void` declaration (UnitloadBusinessService.java:221). Result: **22 call sites**, 19 outside `UnitloadBusinessService` and 3 inside.
- Multi-line or method-reference check: `git grep -nE "transferUnitLoadToLocation\s*$|::transferUnitLoadToLocation"` returned comments only. The multi-line call at MobileTruckLoadingWriteService.java:584 was caught by A, because its `(` is on the same line.
- The sizing doc said 23. The difference is `MobileTransferOrderService.transferStock`: SBDEV-3758 fix A removed its container relocation (MobileTransferOrderService.java:430-446 now always `createUnitload(transferLane, …)` + `transferStockToUnitLoad`). The javadoc's "24" (UnitloadBusinessService.java:216) is still stale.

**Instrument B, wrapper callers.** Command: `git grep -n "<name>(" origin/develop -- 'src/main/**/*.java'`, dropping comments and declarations, for `sendToNirvana`, `relocateEmptiedContainer`, `sendToClearing`, `relocateEmptyStoragePallet` and `recoverPalletFromNirvana`.

**Blind spots:**
- callers on unmerged branches;
- SDR `PATCH` of `storagelocationId`, which never enters this method;
- the BOL bulk SQL transfers (BillofladingService.java:665 and :1699, "replaces per-pallet transferUnitLoadToLocation"), which bypass the method entirely;
- reflection (none found).

### 1a. Direct call sites

| # | site | code | can source be the FLA's bin (FLA UL) with dest ≠ source? | guard effect |
|---|---|---|---|---|
| 1 | CustomerorderService.java:709 | `FINISHED_PACKAGING_MOVE_TOTE` | No. `pickingTote` is a tote | none |
| 2 | FixLocationAssignmentService.java:171 | `MOVE_FIX_ASSIGNMENT` | **Yes, by design.** FLA row still points at the old bin when the guard runs (`setAssignedlocationId` comes after, :177ff) | **allow-list required** |
| 3 | PickingorderBusinessService.java:447 | `FINISHED_PICKING` | No. Pick-to UL | none |
| 4 | ReceivingService.java:622 | receiving code | No. Freshly minted UL on `inboundWorkStation` (:603) | none |
| 5 | ReceivingService.java:1068 | `ASSIGN_INBOUND_PALLET` | No. Inbound pallet | none |
| 6 | ReceivingService.java:1095 | `UNASSIGN_INBOUND_PALLET` | No | none |
| 7 | StockunitService.java:690 | `MANUAL_TRANSFER` (web Move Stock, container arm) | Already refused upstream: `relocatesWholeUnitLoad(…, flaOpt.isPresent(), …)` with `flaOpt` keyed on `ulLocation` (:580, :664) | backstop only |
| 8 | StockunitService.java:901 | `ON_HOLD` | `location = locationRepository.findById(stockUnitLoad.getStoragelocationId())` (:860), so it is a **self-move** and dest == source | predicate passes it; **allow-list entry unnecessary** |
| 9 | UnitloadBusinessService.java:585 (`sendToNirvana`) | caller's | see §1b | |
| 10 | UnitloadBusinessService.java:673 (`relocateEmptiedContainer`) | `CONTAINER_RELOCATED_EMPTYPOOL` | see §1b | |
| 11 | UnitloadBusinessService.java:698 (`sendToClearing`) | caller's | see §1b | |
| 12 | MobileMoveUnitloadService.java:618 | `TRANSFER` | Already refused: `findByAssignedunitloadId(sourceUnitLoad…)` → "Cannot move fixed assigned unit load" (:452-453) | backstop only |
| 13-14 | MobileMoveUnitloadService.java:1053/:1057 | `TRANSFER` → EmptyPallets/EmptyTotes | Same method family, behind :452 | backstop only |
| 15 | MobilePickingService.java:587 | `ASSIGN_TOTE` | No. Tote → user location | none |
| 16 | MobilePutAwayService.java:164 | `ASSIGN_PUT_AWAY` | Only through a hand-made request naming a bin label (sizing doc). Not a legit flow | **desired refusal** |
| 17-19 | MobilePutAwayService.java:216/:218/:240 | `PUT_AWAY`/`UNASSIGN_PUT_AWAY` | Pallet type is enforced (`entityNotOfExpectedType`). A PickLocation FLA UL is not a pallet | none |
| 20-21 | MobilePutAwayService.java:662/:666 | `PUT_AWAY` | Source is a putaway UL. Note that a **flowbin destination merges stock** into the FLA UL and never moves a UL onto the bin (:634-641 `transferStockToUnitLoad(sourceStockUnit, assignedUnitLoad, …)`) | none |
| 22 | MobileTruckLoadingWriteService.java:584 | truck loading | No. Outbound pallet lane → gate. Pallets are carriers, which :258-261 bars from FLA bins (`CARRIER_NOT_ON_FIXLOC`) | none |

### 1b. Wrapper callers

**`sendToNirvana`** (UnitloadBusinessService.java:562; early-returns at :580 `if (nirvanaLocation.getId().equals(unitload.getStoragelocationId())) … return;`)

| site | code | source can be FLA bin? | verdict |
|---|---|---|---|
| CustomerorderService.java:712, :1013 | packaging / cancel | No. Totes | none |
| **FixLocationAssignmentService.java:360** | `DELETE_FIX_ASSIGNMENT` | **Yes, by design.** `fixLocationAssignmentRepository.deleteById` runs **after** the send (:363), so the FLA row is live during the guard. It is already skipped when the UL is in Nirwana (:336 `!Objects.equals(…, locationService.getNirvana().getId())`) | **allow-list required** |
| GoodsReceiptPositionService.java:233 | `SEND_TO_NIRVANA` (GRP delete) | Only a foreign UL on a bin (PRD 0). An FLA UL is never a GR position's UL | none with refined predicate |
| UnitloadBusinessService.java:659 | via `relocateEmptiedContainer` default arm | see below | |
| **UnitloadService.java:803** | `MANUAL_REMOVAL` (web Delete Unit Load) | **Yes.** This is the hole the sizing doc flagged | **intended refusal**; see §3 |
| MobileCycleCountService.java:254, :538 | `CYCLE_COUNT` | No for an FLA UL. Both arms gate on `!fixAssignmentOpt.isPresent()` with `findByAssignedunitloadId(unitLoad.getId())` (:251, :535) and `changeAmount` instead. A foreign UL on a bin *would* be refused under the as-proposed predicate | refine predicate |
| MobileMoveUnitloadService.java:1063 | `SEND_TO_NIRVANA` | Behind :452 | backstop only |

**`relocateEmptiedContainer`** (UnitloadBusinessService.java:620)

| site | code | source can be FLA bin? | verdict |
|---|---|---|---|
| BillofladingService.java:996 | build-truck emptied lane ULs | Source is the **transfer lane**. It hits only if a lane carries an FLA. WineCo PRD: all 1,592 FLAs are on `flowbin`, none staging/xdock/lane-named. The code tolerates a lane FLA (`transferLaneFla`, :969), but even then the FLA source never empties (next row) | none |
| PickingorderBusinessService.java:1380 | `PICKING_CARRIER_EMPTY` | Relocates the stock UL's **carrier pallet** (:1366-1367). An FLA UL cannot have a carrier: mobile move refuses it (:198), and carriers cannot sit on FLA bins (UnitloadBusinessService.java:258-261) | none; **no allow-list needed** |
| StockunitBusinessService.java:505 | split/replen/pick emptied source | Unreachable for an FLA source: that branch is entered only when the guard at :429 is false, `destinationStockUnit == null && (… || fixLocationAssignment != null)` → the split path. The comment at :486 says the same | none |
| StockunitBusinessService.java:527 | merge emptied source | Explicitly gated `fixLocationAssignment == null && …` (:520) | none |
| UnitloadBusinessService.java:980 | `recoverPalletFromNirvana` (AdminActionController.java:381) | Source is Nirwana | none |
| UnitloadBusinessService.java:1057 | `relocateEmptyStoragePallet` ← EmptyPalletCleanupJobService.java:114 | Only a foreign empty pallet on a bin (PRD 0). Per-pallet transaction, so a refusal rolls back one pallet | none with refined predicate |

**`sendToClearing`** (UnitloadBusinessService.java:695): CustomerorderService.java:498/:535/:1059 and PickingorderBusinessService.java:848 handle totes/parcels. MobileMoveUnitloadService.java:1072 is behind :452. **None can move an FLA UL off its bin.**

## 2. Q2: does a cleanup move from the bin roll back a bigger transaction?

There are exactly two flows whose *own purpose* is moving the FLA UL off its bin, and both are allow-listed:
- **FLA move** (FixLocationAssignmentService.java:171). The guard runs inside `move`'s `@Transactional`, before the `setAssignedlocationId`. Without the allow-list every FLA move is refused.
- **FLA delete** (FixLocationAssignmentService.java:360). The FLA row is deleted *after* the send (:363). Without the allow-list every delete of a live pick face is refused.
  - Alternative: move `deleteById` above the send and drop the allow-list entry. This is riskier: it changes the order of `replenishorderService.getActive` / FLA-delete side effects and the Hibernate flush order (see the hub-code-traps note "insert-before-delete"). Keep the allow-list.

The guard does **not** roll back the following larger flows:
- **BOL build-truck:** the source is the lane.
- **Pick confirm:** the source is the carrier pallet.
- **Replenish/split drain:** an FLA source never relocates.

PRD WineCo since 2025 (`unitload_record`, `recordtype='TRANSFERRED'`, `unitloadtype='PickLocation'`, `label = fromlocation`, from ≠ to) has two codes:
- `DELETE_FIX_ASSIGNMENT`: 3,250
- `NULL`: 4 (the SBDEV-3758 incidents, now fixed)

No other code ever moved a pick face off its bin. `MOVE_FIX_ASSIGNMENT` shows 0 rows under this filter. Either no FLA move has happened since 2025, or the row is written before the relabel. Treat it as code-proven, not data-proven.

**Blind spots:**
- Only WineCo was checked. The c1wh, nywh-hydra and nywh-shipitez PRD MCPs dropped the connection.
- The "currently assigned bins" join cannot see historic FLA bins.

## 3. Web Delete Unit Load

`deleteUnitLoad` is `@Transactional(rollbackFor = {BusinessException, FacadeException})` (UnitloadService.java, the annotation directly above `public List<StockChangeDto> deleteUnitLoad`). A refusal from the central guard therefore also undoes the `sendStockUnitToNirvana` calls above it (:786-800) and the CRM notify, which runs after. The problem is the callers:
- `UnitLoadController.bulkDeleteContainer` (:160-176) loops `deleteUnitLoadRecursivePreRun` and `deleteUnitLoad` per UL with **no outer transaction**. An FLA UL in the middle of the batch commits every UL before it and skips every UL after.
- The controller already does an all-or-nothing pre-scan for To-Delete ULs ("Nothing was deleted: already To Delete …", :168-170).

Put the FLA check in that pre-scan, and in the single-delete path at :111 before `deleteUnitLoadRecursivePreRun`. Make it `findByAssignedunitloadId(ul.getId())` *and* the UL's location == the FLA's bin, matching the central predicate. Use a message that names the remedy: "delete the fixed location assignment instead".

Also note that `deleteUnitLoadRecursive` (UnitloadService.java:606-629) deletes children first. An FLA UL is never a child (it has no carrier), so this adds no case.

## 4. Q3: performance and reuse

- **Cost.** One `findByAssignedlocationId(sourceId)` per top-level call. `assignedlocation_id` has a UNIQUE index (`uk_qakwvmdhdymic54v3dgie46wa`, base schema V2.2.00:3764; confirmed on WineCo PRD `pg_indexes`), so it is one index probe.
- **Bulk paths.**
  - BOL build-truck's shipped transfer uses bulk SQL and **does not call this method** (BillofladingService.java:665, :1699).
  - The only per-UL loop through it is the emptied-lane `relocateEmptiedContainer` loop (:993-997), about one call per lane UL. Each call already does several lookups: type, location by name, and the destination FLA lookup at UnitloadBusinessService.java:255.
  - EmptyPalletCleanupJob is per-pallet and batched by the job.
  - **Not a concern.**
- **Cheaper form.** The method already looks up the *destination* FLA at :255. Replace both with a single `fixLocationAssignmentRepository.findByAssignedlocationIdIn(List.of(sourceId, destId))` (FixLocationAssignmentRepository.java:65) and split by `assignedlocationId`. That is zero extra round-trips. Be aware that the parameter is misleadingly named `unloadIdlist`; the query itself is by location.
- **Preloaded pattern.** `StockunitBusinessService.transferStockToUnitLoad(..., FixLocationAssignment preloadedFixLocationAssignment)` (:203, :250, :392-397) threads a pre-fetched FLA through an overload. Do **not** copy it here: it would add a parameter to a method with 22 call sites to save one indexed probe. The `In` merge above gets the same saving with no signature change.
- **Guard placement.**
  - Read `unitload.getStoragelocationId()` as captured at :222. Every legit caller re-reads or locks the UL before calling.
  - Skip when the source id is null.
  - Run it *before* the BLOCK_REALIGN pre-walk lock (:233-236) so a refusal takes no locks.
  - It applies to the top-level UL only. `processTransfer` children cannot be FLA ULs.

## 5. Q4: Nirwana early return

`sendToNirvana` returns at :580-583 before reaching the transfer when the UL is already in Nirwana. `FixLocationAssignmentService.delete` also skips the send itself when the UL is in Nirwana (:336). So the dangling-FLA repair (delete the FLA whose UL is in Nirwana) never meets the guard. In any case, its source is Nirwana and not the bin. No interaction.

## 6. Exact change list

| change | why |
|---|---|
| **Keep** `CODE_MOVE_FIX_ASSIGNMENT` | FLA row still points at the old bin during the move (FixLocationAssignmentService.java:171 vs the later `setAssignedlocationId`) |
| **Keep** `CODE_DELETE_FIX_ASSIGNMENT` | FLA deleted after the send (:360 vs :363) |
| **Remove** `CODE_ON_HOLD` | self-move (StockunitService.java:860, :901); the dest ≠ source predicate passes it |
| **Do not add** `CODE_PICKING_CARRIER_EMPTY`, `CODE_CYCLE_COUNT`, `CODE_SEND_TO_NIRVANA`, `CONTAINER_RELOCATED_EMPTYPOOL`, receiving/putaway codes | no legitimate path moves an FLA UL off its bin with them (§1) |
| **Do not add** `CODE_MANUAL_REMOVAL` | that refusal is the point; give it a friendly pre-check in the controller pre-scan (§3) |
| **Add the conjunct** `Objects.equals(fla.getAssignedunitloadId(), unitload.getId())` | stops refusing foreign ULs on a bin (cycle count, GRP delete, empty-pallet job, operator cleanup); keeps the source keying, so stranded-UL retirement stays allowed |
| Error | `BusinessException` with a key constant, as with `MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION` (:309-310). Do not build ad-hoc strings (SBDEV-3993 no-raw-text direction) |
| Fix the stale javadoc count | :216 says 24; develop is 22 |

## 7. Trade-offs

| option | pros | cons |
|---|---|---|
| As proposed (source = FLA bin) | simplest; also freezes foreign ULs on a bin | refuses legit cleanup of foreign ULs (cycle-count zero, GRP delete, cleanup job), which cannot be repaired except by FLA delete |
| **Refined (source = FLA bin ∧ UL = FLA UL)** | protects exactly the invariant; no legit flow refused | a foreign UL on a bin stays movable (desired); one more field compare |
| Key on UL only (UL = FLA UL, any source) | catches stranded-UL moves too | rolls back BOL build-truck retiring a stranded UL (BillofladingService.java:996), as the sizing doc warned |

**Steelman against the guard itself.** After SBDEV-3758, every legit caller either already refuses (mobile move :452, web Move Stock :664) or structurally cannot reach the case. The guard then only protects hand-made putaway requests and Delete Unit Load, both of which could be fixed at their call sites. The answer is the javadoc's own warning: "every caller of this method" grows. One central invariant check costs one probe (zero with the `In` merge) and closes the class rather than the instances.
