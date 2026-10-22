---
ticket: SBDEV-3470
kind: independent review (T0, comment/javadoc-only)
reviewer: code-reviewer lane (separate from the authoring pass)
date: 2026-09-23
worktree: .claude/worktrees/wms2-api/SBDEV-3470 (branch bugfix/SBDEV-3470-correct-truck-loading-fanout-figure, uncommitted, 0 commits ahead of origin/develop)
---

# SBDEV-3470 — independent review: truck-loading fan-out figure correction

## Scope reviewed
- `src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingWriteService.java` — class javadoc "Fan-out" bullet (:136-147)
- `src/test/java/net/aim_ai/wms/integration/service/mobile/MobileTruckLoadingRaceIT.java` — "Exposure" paragraph (:117-122)
- `src/test/java/net/aim_ai/wms/integration/service/mobile/MobileTruckLoadingLockOrderProbeIT.java` — "Fixture scale" paragraph (:118-123)
- `sbdocs/3-Resources/workflows/wms2-bol-truck-loading-workflow.md:205-208`

## 1. No code/behaviour change — CONFIRMED
`git diff -U0 | grep '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-] \*'` returns nothing (exit 1):
every added/removed line is a javadoc ` * ` line. No compile/behaviour surface touched. (No LSP run needed;
no token outside comments changed.)

## 2. DB re-derivation (Hydra prd, `mcp__wms2-hydra__execute_sql`, my own queries)

Per-pallet query: `unitload p JOIN unitload c ON c.carrierunitload_id = p.id LEFT JOIN customerorder co ON co.parcel_id = c.id`, grouped by pallet.

| Claim | Author | Re-derived | Verdict |
|---|---|---|---|
| pallets currently carrying children | 46 | 46 rows | OK |
| pallets whose children carry an order | 43 | 43 | OK |
| max parcels (ordered pallets) | 14 | 14 (`OUT-100059`) | OK |
| max B3+B5 = parcels + distinct orders | 28 | 28 | OK |
| mean parcels | 4.88 / "~5" | 4.884 | OK |
| mean acquisitions (WriteService "mean 9.8") | 9.8 | 9.767 | OK (rounds to 9.8) |
| mixed pallets (some children orderless) | — | 0 of 43 | all-or-nothing; "whose children carry an order" is exact |
| parcels with >1 customerorder row | — | 0 prd-wide | so distinct orders == parcels on every pallet; the "Too many orders" guard is not hit |
| the three 70-child pallets are inbound | yes | `IN-000020/21/22`, 70 children each, all type `Case`, 0 orders, pallet AND children at location `PutAwayLane` | OK |
| "the 88 came from a different, 14-parcel pallet" | yes | `OUT-100059`: 14 children, 88 stockunits on its children | OK |
| inbound pallets carry 70 stockunits | (implied) | 70 each | consistent |

Every number in the new comments re-derives exactly. The old "70 parcels / 88 stockunits / ~142" figure was
indeed a conflation of two different pallets plus the inbound pallets.

## 3. Code re-read of scanGate (worktree, `MobileTruckLoadingWriteService.java:230-446`)

- B1 `billofladingRepository.findByIdForUpdate` :274 — 1 locked acquisition.
- B2 `unitloadRepository.findByLabelidForUpdate` :278 — 1.
- B3 loop `unitloadRepository.findByIdForUpdate(parcelId)` :286-289 — 1 per parcel, **for every child, with or without an order**.
- B4 `stockunitRepository.findByUnitloadId` :296-299 — **unlocked**. Confirmed.
- B5 loop `customerorderRepository.findByIdForUpdate(orderId)` over a `TreeSet` of distinct order ids :310-325 — 1 per distinct order. Confirmed.
- B6 `customerorderPositionRepository.findByOrderId` :330-333 — **unlocked** (not the `...ForUpdate` multi-row variant). Confirmed.
- PHASE C :379-387 — an orderless parcel throws `unexpectedUnitLoadDoesNotHaveOrder`. Confirmed.
- PHASE D0 :406 `handleTruckOffLoadingNoClear` — a DELETE on `billoflading_position` (implicit row locks on any matched rows).
- PHASE D :443 `locationRepository.findByIdForUpdate(gate)` — 1 more explicit acquisition; `transferUnitLoadToLocation(..., false, ...)` re-locks the same row (UnitloadBusinessService:245), a re-lock, not a new acquisition. Plus INSERT/UPDATE row locks for the BOL-position tree, orders, header.

So B3+B5 = parcels + distinct orders is correct **as a count of the fan-out loops**. It is not the scan's total.

## Findings

### [HIGH] The corrected bound "at most 28" is not a bound scanGate enforces — the inbound pallets are still fully locked before PHASE C rejects them
Confidence: HIGH
Files:
- `MobileTruckLoadingRaceIT.java:117-120` — *"max 14 parcels, so at most 28 lock acquisitions (parcels + distinct orders) held for the scan. ... Those three are inbound receiving pallets with no orders, and PHASE C rejects them."*
- `MobileTruckLoadingWriteService.java:142-144` — *"the 70-child pallets were INBOUND receiving pallets ({@code Case} children, no order) that PHASE C rejects"*
- `wms2-bol-truck-loading-workflow.md:207-208` — *"measured fan-out (max 28 acquisitions on Hydra prd, SBDEV-3470; an earlier "~142" figure counted inbound pallets and was wrong)"*

Issue: PHASE C runs **after** PHASE B. B3 locks every child of the scanned pallet regardless of whether it has an
order (:286-289), so a scanGate call on `IN-000020` takes B1 + B2 + **70** B3 acquisitions (72, each bounded by
`wms.tenant.lock-timeout-ms`, and contendable by receiving/putaway on those `Case` unitloads in `PutAwayLane`)
and only then throws at :384. PHASE C does not prevent the fan-out; it only makes the scan roll back afterwards.
The old figure was wrong about *what those pallets are*, but it was not wrong that scanGate would lock 70 rows
for them.

What actually keeps inbound pallets off scanGate in normal operation is a **different endpoint**:
`MobileTruckLoadingService.checkPallet` (behind `POST /mobile/truckLoading/scanPallet`) rejects any label not
matching `STRING_PATTERN_OUTBOUND_PALLET` / `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL`. On Hydra prd those are
`WC_\d{16}|OUT-\d{6}|OUT\d{6}` and `AOUT-%1$06d` — `IN-000020` matches neither. scanGate itself re-checks only
`existsByLabelid` (:242), not the pattern, so the 28 bound holds only for callers that went through scanPallet
first (the handheld UI does; a direct/replayed `scanGate` POST does not).

Because the ticket's entire deliverable is the accuracy of this exposure figure, restating a new un-enforced
upper bound as "at most" is the same class of defect being corrected — hence HIGH rather than MEDIUM.

Fix (wording only, keep it T0): scope the 28 to *pallets that pass scanPallet's outbound-label check*, and say
that PHASE C rejects an orderless pallet **after** B3 has locked all its children. E.g. RaceIT:
> "...43 pallets whose children carry an order, max 14 parcels, so at most 28 B3+B5 acquisitions on a pallet that
> passes `checkPallet`'s outbound-label pattern. The three 70-child pallets are inbound (`IN-`); `checkPallet`
> rejects their label, and if scanGate is called directly B3 still locks all 70 children before PHASE C rejects
> them — the label check, not PHASE C, is what keeps them off this path."
Mirror in the WriteService bullet and the sbdocs line.

### [MEDIUM] "(parcels + distinct orders) acquisitions" / "28 acquisitions" reads as the scan's total
Confidence: HIGH
Files:
- `MobileTruckLoadingWriteService.java:137-139` — *"so a scan takes (parcels + distinct orders) acquisitions"*
- `MobileTruckLoadingRaceIT.java:118-119` — *"at most 28 lock acquisitions (parcels + distinct orders) held for the scan"*
- `wms2-bol-truck-loading-workflow.md:207` — *"max 28 acquisitions"*

Issue: the scan also takes B1 (BOL), B2 (pallet) and PHASE D's gate `Location` explicitly (`findByIdForUpdate`
at :274, :278, :443), plus implicit row locks from D0's DELETE and D's writes. On the max pallet the explicit
`FOR UPDATE` count is 31, not 28. The WriteService bullet opens with "B3 and B5 lock by looping..." so a careful
reader can infer the scope, but "a scan takes" and RaceIT's "held for the scan" state it as the total.
Fix: "B3+B5 take (parcels + distinct orders) acquisitions, on top of the fixed three (B1 BOL, B2 pallet, D gate)"
and "at most 28 B3+B5 acquisitions (31 explicit FOR UPDATE in all)".

### [LOW] "mean 9.8" is ambiguous next to "14 parcels / 28 acquisitions"
Confidence: HIGH
File: `MobileTruckLoadingWriteService.java:141` — *"max 14 parcels / <b>28 acquisitions</b>, mean 9.8"*
Issue: correct (9.767 acquisitions), but it sits next to a parcel figure and the ProbeIT says "mean ~5" (parcels);
a reader comparing the two sees an apparent contradiction.
Fix: "mean 4.9 parcels / 9.8 acquisitions".

### [LOW] "It saves only round trips" slightly understates a multi-row finder's cost
Confidence: MEDIUM
File: `MobileTruckLoadingWriteService.java:144-147` — *"A multi-row locked finder would NOT reduce the lock count or the per-acquisition timeout bound (both stay per row). It saves only round trips."*
Assessment: the core claim is **accurate** and consistent with the SBDEV-3250 note at
`CustomerorderPositionRepository.java:34-37` (lock_timeout applies per acquisition; worst case = rows x bound).
One nuance is missing: a single multi-row `FOR UPDATE` locks its rows in plan order, not id order, unless the
query carries `ORDER BY id` — so "at the SAME sequence positions" is necessary but not sufficient to keep the
canonical intra-table ascending order that the looped finder guarantees.
Fix (optional): append "and it must `ORDER BY id`, or the intra-table lock order becomes plan-dependent."

### [LOW] Sibling copy of the old figure still asserted in an active plan doc
Confidence: HIGH
File: `sbdocs/1-Projects/wms2/plan/SBDEV-3418-mobile-truck-loading-transaction-boundary.md`
- :301 — *"up to ~142 extra round-trips that buy nothing"*
- :667-669 — *"On a worst-case Hydra prd pallet (measured: **70 parcels, 88 stockunits**) that is up to ~142 acquisitions ... Nothing on develop takes this many locks"*
Issue: this plan is still in `1-Projects/` (`status: "on dev"`) and states the figure as current, with no
correction pointer. The `SBDEV-3418-evidence/*` hits (`rereview-fix-commits.md:29,206`,
`arch-target-sequence.md:427`, `verifier-conformance.md:392,495`, `plan-critic-review.md:419`) are dated
review records and are fine to leave as history.
Fix: add a one-line "⚠ corrected by SBDEV-3470: ..." note at :301 and :667 (sbdocs is not in git; plain edit).

### Sweep results (no further stale copies)
`git grep -nE "142|70 parcels|bimodal|88 stockunit|median of 4|46 pallets|p99" -- src` in the worktree: the only
fan-out hits are the three edited files, and each occurrence there is inside an explicit "an earlier revision
said ..." correction note. Every other `142` hit is unrelated (line cites `:139-142`, sysprop id 142, the
NeverMatcher/OptionalSafety counts, seed timestamps). The p99 hit is `application.properties:109` (palletize
latency), unrelated. sbdocs `3-Resources/` has only the corrected workflow line; the two `bimodal` hits are
SBDEV-3339 (cancellation log), unrelated.

## Positive observations
- Every quantitative claim in the new text re-derives exactly from prd, including the non-obvious "the 88 came
  from a different 14-parcel pallet".
- B4/B6-unlocked and B3/B5 = parcels + distinct orders are faithful to the code.
- The old figure is retained as a flagged corrected-history note rather than silently deleted, which stops a
  future reader "restoring" it.
- Diff is strictly javadoc — zero behavioural surface.

## Summary
- CRITICAL 0 · HIGH 1 · MEDIUM 1 · LOW 3
- Numbers: all verified. Wording: the new "at most 28" is stated as a bound scanGate enforces; it is a bound the
  separate scanPallet label check enforces, and PHASE C rejects inbound pallets only after locking all 70 children.

Verdict: CHANGES REQUESTED
