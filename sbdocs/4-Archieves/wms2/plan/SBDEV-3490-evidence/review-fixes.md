# SBDEV-3490: how each finding in code-review.md was handled

Author pass, 2026-09-24. The review verdict was APPROVE, with 1 Medium and 8 Lows.

## Medium: container-branch DESTINATION on Shipped. Disproved on dev, not proposed

The reviewer's premise was that a shipped child unit load has no BOL position under its own label, so
`assertPalletNotAssignedToGate(destinationLabel)` would let it through as a destination.

dev (`wms2-wineco-dev`), 2026-09-24:

```sql
-- unit loads on Shipped with NO billoflading_position whose source_id is them
select count(*) filter (where u.carrierunitload_id is null) as top_no_pos,
       count(*) filter (where u.carrierunitload_id is not null) as child_no_pos
from unitload u join location l on l.id=u.storagelocation_id and l.name='Shipped'
where not exists (select 1 from billoflading_position bp where bp.source_id=u.id);
-- => top_no_pos 0, child_no_pos 0

-- positive control: the same population WITH a position
-- => with_pos 411896, total 411896
```

On dev, every unit load on Shipped is the source of a position, so `assertPalletNotAssignedToGate`
already refuses each one as a destination. There is nothing to propose. **Caveat:** this was measured
on dev only. A tenant that ships unit loads without a BOL (so with no position) would reopen the
question. The Hydra prd count was not taken, because on 2026-09-24 the equivalent `storagelocation_id`
scan timed out under the 30 s MCP limit, as recorded on the ticket.

## Lows

| # | Finding | Action |
|---|---|---|
| 1 | SBDEV-2995 sentinel test comment: "scanDestination checks only ON_HOLD and reservations", plus dead `:NNN` line refs | Rewritten as history, and the line refs removed |
| 2 | AC-6a javadoc said "The Fix C throw is what rolls back…"; its display name said "rolls back" | Javadoc now says this was the original behaviour and points to the SBDEV-3490 note. Display name is now "is rejected before the move". The method name is kept because the SBDEV-3487 plan and evidence cite it |
| 3 | `handleTruckOffLoading` comment said "rolls the move back out of Shipped" | Now says "rolls that move back" |
| 4 | The fixed-assignment test did not pin placement (it would pass if the check sat only in the container branch) | Added `verify(locationRepository, never()).findByName("PALLET-9")`, so the refusal must come before the destination is resolved |
| 5 | Nothing pinned "Shipped before ON_HOLD" | New test `scanDestination_shouldReportShipped_whenShippedSourceIsAlsoOnHold` |
| 6 | The Nirvana-source test covers only the location branch | No change, as the reviewer suggested. It is the adjacent block to the Shipped check, at the same point in the method, and that check is pinned across three branches (wording corrected per re-review R-L5) |
| 7 | The message embeds `Location.toString()` | No change: kept byte-identical to `scanUnitLoad` on purpose |
| 8 | The four guards are duplicated in `scanUnitLoad` and `scanDestination` | Declined for this ticket. Extracting them would change `scanUnitLoad`, which the fix does not need, and its order differs (the stock ON_HOLD loop sits between the location and fixed-assignment checks). The javadoc on `assertNotNirvanaSentinel` records where each guard lives |

Findings 4 and 5 add assertions, so each one is mutation-checked before commit (results are in the ticket comment).

## Re-review (re-review.md) of cd7b7b72: APPROVE, 5 Lows

| # | Action |
|---|---|
| R-L1 | The ON_HOLD test now sets the lock on the fixture's source object, instead of calling the stubbed mock from test code. The Shipped-below-ON_HOLD mutant was re-run and is still killed ("Unit load is locked on hold!") |
| R-L2 | No change. The test comment states the stricter intent, which the reviewer agreed needs no fix |
| R-L3 | The sentinel-test comment now says the reservation check came after the stock load |
| R-L4 | A comment on the IT method explains why the name "…RollsBack" was kept |
| R-L5 | This file's row 6 was reworded. The PR body now says which commits each review covered, which commit the suite ran on, and that the Medium disproof is dev-only |
