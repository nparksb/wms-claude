---
name: geometry-branch-inherits-its-arms-lock-policy
description: A method that picks a movement primitive on a shape condition silently inherits that arm's guard policy; found twice in wms2 on one ticket
metadata:
  type: project
---

When a method routes between two primitives on a **geometry** condition — "does this move drain the
container?", "does the source have a fixed-location assignment?" — it inherits whichever guard policy
that arm happens to carry. The condition has nothing to do with locks, so the same operator action
honours a lock or ignores it depending on the shape of the data.

Found **twice in wms2 on SBDEV-3341** (2026-09-14), one method apart:

- `StockunitService.transferStock` — `amount == amountToTransfer && no FLA && single SU`
- `MobileTransferOrderService.transferStock` — `FLA present` (opposite polarity, same shape)

In both, the split arm calls `StockunitBusinessService.transferStockToUnitLoad` (refuses any non-zero
source lock) and the whole-container arm calls `UnitloadBusinessService.transferUnitLoadToLocation`
(**no source guard at all, deliberately** — truck loading relocates pallets of PICKED_FOR_GOODSOUT
stock at `ignoreLock=false`). Fixed by `net.aim_ai.wms.util.SourceLockGuard`, called from both.

**Why: the lock-policy layer and the movement layer are different layers.** The primitive is right to
be policy-free; the *caller* owns the policy. So when a caller can reach two primitives, check that it
imposes the same policy on both paths — the primitives will not do it for you.

**How to apply.** Grep for callers that branch between `transferStockToUnitLoad` and
`transferUnitLoadToLocation` before assuming a lock guarantee holds. Only the second site was found —
by a review lane asked explicitly *"is this an instance fix or the rule?"*. Asking that question of a
reviewer is what turned a one-site patch into the invariant; see
[[a-guard-fences-the-mechanism-you-aimed-at]] and [[prose-enumerations-rot-state-the-rule]].

A doc had also asserted the guarantee this defect violated, by counting call sites of *one primitive*
and concluding about the whole method — see [[annotation-census-by-grep-is-wrong-by-default]].
