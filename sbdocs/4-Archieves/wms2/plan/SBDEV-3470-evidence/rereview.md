---
ticket: SBDEV-3470
kind: independent re-review of the fix round (T0, comment/javadoc-only)
reviewer: code-reviewer lane (separate from the authoring and first-review passes)
date: 2026-09-23
worktree: .claude/worktrees/wms2-api/SBDEV-3470 (uncommitted, based on origin/develop ccc659cf)
prior: review.md (1 High, 1 Medium, 3 Low; CHANGES REQUESTED)
---

# SBDEV-3470: re-review of the fix round

## 0. Diff is javadoc-only: CONFIRMED
`git diff origin/develop -U0 | grep '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-] \*'` returns nothing (exit 1).
3 files, +34/-16, and every changed line is a ` * ` comment line. Nothing that compiles changed.

## 1. Data re-derived (Hydra prd, my own query, run just now)
Per pallet: `unitload p JOIN unitload c ON c.carrierunitload_id=p.id LEFT JOIN customerorder co ON co.parcel_id=c.id`.
Result: all_pallets 46 · ordered 43 · max_parcels 14 · max(parcels+orders) **28** · mean_parcels 4.88 ·
mean acquisitions 9.77 · max parcels on an orderless pallet **70** · the three ≥70 are `IN-000020,IN-000021,IN-000022`.
So "43 pallets", "max 14", "max 28", "mean 4.9 parcels / 9.8 acquisitions" and "70-case inbound" all match.

## 2. New specifics, checked against the code
| Claim | Evidence | Verdict |
|---|---|---|
| "31 in total" = B1+B2+28+gate | explicit `FOR UPDATE`s: B1 `billofladingRepository.findByIdForUpdate` WriteService:283, B2 `findByLabelidForUpdate` :287, B3 loop :296, B5 loop :332, D `locationRepository.findByIdForUpdate(resolvedGateId)` :452. `transferUnitLoadToLocation(...,false,...)` locks the **same** gate row again (UnitloadBusinessService:245): a re-lock, not a new acquisition. 1+1+28+1 = 31 | correct as a count of explicit acquisitions (see L2) |
| "a 70-case inbound pallet: 72 acquisitions" | PHASE A (:244-273) checks only that the label, BOL and gate exist. Then B1 + B2 + 70 × B3; B5 = 0 (no orders); the throw comes at :393 (`unexpectedUnitLoadDoesNotHaveOrder`), before D0/D. 1+1+70 = 72 | correct |
| "B3 locks EVERY child before PHASE C looks at orders" | B3 :293-298 iterates `findIdsByCarrierunitloadIdOrderById` with no order filter; PHASE C :385-396 | correct |
| "this method checks only that the pallet label exists" | :251 `existsByLabelid`; no pattern check in WriteService.scanGate | correct (for the pallet) |
| "the UI flow's `checkPallet` label-pattern check, which a direct call to this endpoint skips" | `MobileTruckLoadingService.checkPallet` :83-98 matches `STRING_PATTERN_OUTBOUND_PALLET` / `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` and runs behind `POST /mobile/truckLoading/scanPallet` (TruckLoadingController:91-98). `MobileTruckLoadingService.scanGate` :166-172 calls `truckLoadingWriteService.scanGate` directly, never `checkPallet`. UI (wms2-mobile-ui origin/develop): `components/truckLoading/scanPallet.vue:67` sends `truckLoading/scanPallet` in the step before `scanGate.vue:61` | correct |
| multi-row `FOR UPDATE` without `ORDER BY id` locks in plan order; with it, in id order | Postgres puts LockRows **above** Sort: ORDER BY runs first and rows are locked as they come out (this is why the docs warn that READ COMMITTED + ORDER BY + FOR UPDATE can return rows out of order). With no ORDER BY, the order is whatever scan the plan picks | correct |
| "would re-open the ABBA that SBDEV-3419 closed" | SBDEV-3419 = ascending-parcel-id lock order (UnitloadRepository:59, ParcelMonitorViewService:81,188) | correct cite |
| "B4 and B6 are unlocked and add nothing" | B4 `findByUnitloadId`, B6 `findByOrderId`: neither is a `...ForUpdate` finder | correct |

## 3. Prior findings: each one resolved or not
| Prior | Status | Evidence |
|---|---|---|
| [HIGH] "at most 28" stated as a bound scanGate enforces | **RESOLVED** | WriteService: *"⚠ That 28 is a property of the data, not of this method. B3 locks EVERY child before PHASE C looks at orders"*, plus the 72-acquisition example and the checkPallet attribution. RaceIT: *"That max is a property of today's data, not a bound scanGate enforces."* Workflow doc:207-209: *"That is a property of the data, not a bound: B3 locks every child before PHASE C rejects an order-less pallet."* The substance changed, not only the wording. |
| [MEDIUM] "28" reads as the scan's total | **RESOLVED** | Every copy now says "B3+B5"; WriteService names B1/B2/PHASE D; RaceIT: *"31 counting B1, B2 and the gate"* |
| [LOW] "mean 9.8" ambiguous | **RESOLVED** | *"mean 4.9 parcels / 9.8 B3+B5 acquisitions"* (WriteService); ProbeIT: *"mean 4.9 parcels"* |
| [LOW] multi-row finder needs ORDER BY | **RESOLVED** | *"it must sit at the SAME sequence position AND carry {@code ORDER BY id} inside its query"* |
| [LOW] sibling copy in the SBDEV-3418 plan | **RESOLVED** (L4 below is a small leftover) | correction notes at :301 and :665, with the original text kept |

## 4. Sibling sweep
- `git grep -nE "~142|142 acquisitions|70 parcels|bimodal|88 stockunit|median of 4|46 pallets|70-parcel" -- src`: 4 hits, all
  inside an explicit "An earlier revision said/called/counted …" note (WriteService:149, ProbeIT:121, RaceIT:121-122).
- sbdocs, same pattern, excluding `*-evidence/`: workflow:209 (correction wording), SBDEV-3418:301/:665-668 (flagged),
  and unrelated hits only (SBDEV-3339 "bimodal", SBDEV-2554 `:~142` line cite, a replenishment report).
  No old figure is still stated as current.

## Findings (all new, all LOW)

### [LOW] L1: Broken sentence in the correction note
Confidence: HIGH
File: `MobileTruckLoadingWriteService.java:149-150`: *"⚠ An earlier revision said "70 parcels, 88 stockunits, ~142 acquisitions", reached a successful scan. That was wrong three ways"*
Issue: "said X, reached a successful scan" does not parse. It reads like an edit that was only half done ("said a successful scan reached X").
Fix: *"An earlier revision said a successful scan could reach "70 parcels, 88 stockunits, ~142 acquisitions". That was wrong three ways: …"*

### [LOW] L2: "(31 in total)" counts only explicit FOR UPDATE acquisitions
Confidence: MEDIUM
File: `MobileTruckLoadingWriteService.java` Fan-out bullet: *"so max 28 for B3+B5 (31 in total)"*
Issue: "in total" is a closed-set word. On a successful scan, D0 (`handleTruckOffLoadingNoClear` → `deleteBolPositionsCarrierIdsNoClear` /
`deleteBolPositionByIdNoClear`, MobileMoveUnitloadService) and PHASE D's writes also take implicit row locks on `billoflading_position`,
and those can block other sessions. RaceIT already words it safely (*"31 counting B1, B2 and the gate"*).
Fix: *"(31 explicit `FOR UPDATE` acquisitions in all, plus the implicit row locks of D0's DELETE and PHASE D's writes)"*, or copy RaceIT's wording.

### [LOW] L3: ProbeIT keeps the "scanGate rejects them" framing without the lock caveat
Confidence: HIGH
File: `MobileTruckLoadingLockOrderProbeIT.java:121-122`: *"Those three were inbound receiving pallets with no orders, which scanGate rejects."*
Issue: the sentence is true, but it is the framing that round 1 rated HIGH elsewhere. Read alone, it suggests the rejection keeps the fan-out away.
The other two copies now say B3 locks all 70 children first. This one has no caveat and no cross-reference.
Fix: *"… which scanGate rejects only after B3 has locked all 70 children (see the "Fan-out" note in `MobileTruckLoadingWriteService`)."*

### [LOW] L4: The SBDEV-3418 plan correction covers the figures but not the kept remedy
Confidence: MEDIUM
File: `sbdocs/1-Projects/wms2/plan/SBDEV-3418-mobile-truck-loading-transaction-boundary.md`
- :665: *"⚠ Corrected … by SBDEV-3470: the figures below are wrong."* The kept text goes on: *"if the tail is bad, the remedy is a multi-row locked finder at the same sequence positions, not a resequencing."*
  The WriteService now says such a finder does NOT reduce the lock count or the timeout bound, and needs `ORDER BY id`. The correction header
  scopes itself to "the figures", so a reader can take the remedy as still endorsed.
- :301: *"the real max on an order-bearing pallet is 28 B3+B5 acquisitions"*. This lacks the "today's data, not a bound" qualifier
  (it does point to item 6, which has it).
Fix: widen the :665 note: *"…the figures below are wrong, and so is the remedy: a multi-row finder saves round trips only, and must `ORDER BY id`."*
At :301 write *"today's max … (a property of the data, not a bound)"*. This is sbdocs, so a plain edit.

## Positive observations
- The HIGH was fixed in substance. All three live copies now say where the bound actually comes from (the separate scanPallet label check),
  and each claim holds against the code and the mobile UI's step order.
- The 72-acquisition worked example makes the "not bounded" claim concrete and checkable, and it checks out.
- The ORDER BY caveat is right for Postgres and ties back to the SBDEV-3419 invariant.
- Old figures are still kept only as flagged history, so nobody will "restore" them.
- Every number re-derives exactly from prd today.

## Summary
CRITICAL 0 · HIGH 0 · MEDIUM 0 · LOW 4 (L1–L4, all wording; none is a false quantitative claim)
All 5 prior findings are resolved. No new false claim at HIGH or MEDIUM. The diff is javadoc-only.
By standing policy Lows are fixed in the same pass (L1 and L3 are one-line edits), but none of them blocks.

APPROVE
