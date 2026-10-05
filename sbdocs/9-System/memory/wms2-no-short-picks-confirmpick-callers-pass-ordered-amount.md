---
name: wms2-no-short-picks-confirmpick-callers-pass-ordered-amount
description: "v2 never produces a short pick — both confirmPick callers pass getAmount(); \"confirmPick allows it\" ≠ reachable"
metadata:
  node_type: memory
  type: project
  originSessionId: 059dc57b-8e06-4f44-b5f1-5e27eb9946e7
  modified: 2026-09-23T08:49:52.317Z
---

**v2 has no short-pick path today.** `PickingorderBusinessService.confirmPick` guards `amountPicked`
only for `> 0`, so it *would* accept a short amount — but its only two callers,
`MobilePickingService.processPick` and `rapidPickingScanSource`, both pass
`pickingPosition.getAmount()`. Hydra PRD 2026-09-23: 0 of 470 PICKED lines had `amountpicked <> amount`.
So `amountpicked == amount` on every picked line; only positions cancelled before a pick differ (amountpicked 0).

SBDEV-3361's ticket claimed "the short pick is reachable" from reading `confirmPick` alone — the
architect consult broke it by reading the callers. The fix (cancellation log stores `getAmountpicked()`)
shipped as an invariant fix, PR wms2-api #407.

**Why:** a guard that *permits* a state is not a path that *produces* it — check the callers' arguments.
**How to apply:** before tiering or sizing anything on "short pick" / "partial pick" behaviour in v2,
treat it as latent unless a caller other than those two appears (`git grep "confirmPick(" origin/develop -- src/main`).
Also: when two picks of one SKU merge into one tote stock unit, a wrong reversal quantity is NOT refused
by `transferStockToUnitLoad`'s availability guard — it silently draws the sibling's units.
Related: [[wms2-rts-completereversal-moves-no-stock]], [[a-guard-fences-the-mechanism-you-aimed-at]],
[[advertised-capability-is-not-exploitable-capability]].
