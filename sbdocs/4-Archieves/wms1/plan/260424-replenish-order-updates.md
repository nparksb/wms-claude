# Replenish Order Updates Plan

## Goals
- Stop obsolete replenishment requests from lingering when shortages disappear or bins are already filled.
- Keep open orders’ source, destination, and requested quantity aligned with current stock/fixed-assignments without relying on operator scans.

## Assumptions / Inputs
- Use existing bounds on `FixLocationAssignment` (`lowerbound`, `upperbound`) instead of the global default when evaluating shortages.
- Current global default: `SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY` (used by `cancelReplenishmentIfFlowbinIsFull`)—plan is to prefer per-assignment bounds.
- “In-transit replenish” = reserved amounts on **PROCESSABLE** replenish orders for the same item/destination (reservations live on the source stockunits).
- Orders of interest ("open" orders for this logic): `state == PROCESSABLE` and not manually overridden to a different source/destination.

## Implementation Plan
1) **Config & queries**
   - Add sysprops for recalculation cadence and cancel threshold (e.g., fraction of `upperbound`).
   - Extend repo queries to fetch: current on-hand/reserved at destination, open replenish-inbound for an item/destination, and availability of replacement source stock.

2) **Job: auto-cancel / auto-close** (in `ReplenishOrderJob` pipeline)
   - For each open order (PROCESSABLE and not manually overridden), recompute destination shortage: `shortage = upperbound - (onHand + inboundReplenish + existingReservedAtDest)`; if `shortage <= 0`, cancel the order and release reservations.
   - For non-fixed destinations (or `destinationId` null), cancel when no shortage exists anywhere the order was targeting (e.g., picking assignment resolved).

3) **Job: auto-recalculate requested qty**
   - For remaining open orders (still PROCESSABLE), recompute `requestedamount` using current shortage (clamp to available source stock).
   - Adjust reservations to match the new amount (increase/decrease) and persist `requestedamount`.
   - If shortage drops to zero, reuse step 2’s cancel path.

4) **Auto-redirect or cancel when source invalid**
   - Detect orders whose reserved stock unit is depleted, moved, or locked.
   - Try to find a new source (same item, replenishable area, sufficient qty), **preferring stockunits in the same area/zone** and, among candidates, choosing the one with the **largest available quantity**; if found, update `stockunitId`, `requestedlocationId`, `sourcelocationname`, and reservations; otherwise cancel.

5) **Destination alignment**
   - Extend `recalculateReplenishmentOrderWithoutFixedLocationAssignment` to handle changes in fixed assignments: if the item’s fixed assignment moved/was removed, update `destinationId` (or cancel if now invalid). When a new fixed assignment becomes available, only adopt it for replenish orders whose `destinationId` is currently `null`; orders that already have a concrete destination are not retargeted and will instead be cancelled by the shortage logic when no longer needed, or when the source stock is exhausted.

6) **Event triggers (fast path)**
   - Invoke the recalculation/cancel routine on stock movements, stock adjustments, and fixed-assignment create/update/delete events, in addition to the scheduled job.

7) **Safety & UX**
   - Only mutate orders in `PROCESSABLE` state (everything else, including `STARTED` and any state `>= FINISHED`, is read-only for this job) and respect manual overrides where applicable.
   - Ensure mobile/desktop reads reflect updated source/destination/qty (DTO builders already map fields; verify polling/refresh in clients).

8) **Tests**
   - Add service-level tests for shortage calc, reservation adjustments, source redirection, and cancellation triggers.
   - Add job-flow tests covering fixed vs non-fixed destinations and event-triggered recalcs.