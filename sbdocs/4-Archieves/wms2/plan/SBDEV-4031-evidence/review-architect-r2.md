---
lane: architect (ralplan round 2, scoped)
snapshot: plan-snapshot-r2.md sha1 7be5ab91
verified_against: origin/develop d6424491
saved_by: main session, summary of the lane's reply
---
# Architect review, round 2: all of round 1 is CLOSED; 5 new Lows; no High or Medium

**F1 is CLOSED.** Every BLOCK_REALIGN transfer locks P → L_dest → O. The move prefix in r2 now copies that order, and the re-entrant locks are safe (Hook A's re-lock is already held at PESSIMISTIC_WRITE; LockReads takes a scalar lock plus a refresh on a managed Location). Paths checked, none forms a cycle:
- confirm: can only need L′ by scanning it, and that scan is refused with "wrong location!" before any lock is taken;
- CODE_TRANSFER;
- cancel;
- deleteByUser / delete;
- C0 and recalc;
- every P → F path and every L → F path.

**F2–F10 are CLOSED.** Notes:
- Per-order R3 peaks at 1 connection.
- TenantContext is a ThreadLocal on the same thread.
- The @Lazy self idiom has 6 precedents.
- The widened catch at :754 swallows nothing that must propagate. Log `e` there, not only the message.
- The outer scalar lock placed after buildRecalcContext is not a lock upgrade.
- alignDestination returning null falls back to the sysprop upper bound.

**New findings, all Low**
- **N1.** The Pickingorder pre-walk has a TOCTOU gap. A Pickingorder committed between step 2 and the transfer's Hook A can complete a cycle with a concurrent CODE_TRANSFER of S. PostgreSQL detects it as 40P01, one side rolls back, and data is safe. Document it as residual. Do NOT lock the flowbin SU early, because that creates a cycle with confirm.
- **N2.** Fix F step 2 needs a Unitload for collectStockUnitIdsForUnitloadTree. Use getReferenceById or an id overload. A findById().orElseThrow there would park AC-10c too early and would throw before the existing business refusals.
- **N3.** Make AC-8b's allowlist method-level, not class-level. Confirm calls createFixedLocationAssignment and createOrderFromTemplate inside fulfillMultipleUnitLoadsTx, and a class-level list does not fence those.
- **N4.** In the §8.3 FixLocationAssignmentServiceIT:565 row: under MANDATORY, the delete call itself must run inside a second committed TransactionTemplate.
- **N5.** R3 can hit idx_replenishorder_active_item_dest when another open order already targets (item, L) (reachable via C5/C6). Skip such orders and log at INFO, otherwise the order WARNs every tick.
