---
title: "P2 verdict: container delete of received TRANSFER stock"
type: evidence
created: 2026-10-21
related:
  - "[[proposals-register]]"
  - oms-side.md
---

# P2: container delete of received TRANSFER stock sends `MANUAL_REMOVAL`

**Verdict: real, but narrow, and with no live exposure on any v2 PRD tenant today.**

**Decision 2026-10-21 (Nam): Deferred to 2026-11-21, together with P14.** Re-check sooner if any v2 PRD tenant
gets its first TRANSFER advice. ShipItEZ's two warehouses (nywh, c1wh) are already on v2 and have never run an
intra-company transfer, so the trigger is that first advice, not a migration. The census query is in the
proposals-register decision log.

## Evidence

**WMS side** (wms2-api `origin/develop`, read 2026-10-21 after SBDEV-3854 merged as c9e8f9a1):
- **Receiving TRANSFER stock tells OMS nothing.** In `ReceivingService.receiveGoods`, REGULAR reports
  receipt (behind `INBOUND_UPDATE_STOCK_IMMEDIATELY`) and RETURN always reports it. TRANSFER is
  `case AdviceType.TRANSFER: // intentionally empty`.
- **Accepting the advice sends no quantities.** `AdviceService.acceptTransferAdvice` enqueues
  `ADVICE_ACCEPT_TRANSFER` with an `AcceptTransferDto` that carries only `transferId`.
- **Accept is reachable after receipts.** Receiving keeps the advice `OPEN` (`ReceivingService` guards on
  `AdviceState.OPEN`), and accept is allowed from CREATED or OPEN.
- **The delete reports the loss.** `UnitloadService.deleteUnitLoad` reports `MANUAL_REMOVAL` with
  `normal = -amount` for every stock unit, whatever advice type its stock was received under.

**OMS side** (oms-laravel-api `origin/develop` ab83f75e; full trace in `oms-side.md`):
- **The destination is credited at close only.** Only `LegacyTransferCompleteService::updateInventoryForTransfer`
  credits the destination, on closeTransfer, by `order_item.quantity` (the ordered quantity, not what WMS received).
- **A STOCK_UPDATE `normal: -n` is floored at zero.** `LegacyInventoryAdjustService` applies
  `$inventory->{$column} = max(0, $newValue); // inventory can never go negative`.
- **No pre-close credit exists.** No OMS handler credits the destination on a WMS-side transfer receipt.

## Arithmetic

Write B for the destination's OMS on-hand for the SKU before close, Q for the ordered quantity, and n for the
units deleted.

| Delete happens | OMS destination after close | WMS | Wrong? |
|---|---|---|---|
| after accept / closeTransfer | B + Q − n | B + Q − n | no |
| before accept, B ≥ n | (B − n) + Q | B + Q − n | no |
| **before accept, B < n** | **0 + Q** (the −n is floored) | B + Q − n | **OMS overstated by n − B** |

The before-accept delete can also deallocate destination orders against stock OMS has not credited yet
(`LegacyInventoryAdjustService` recomputes `quantity_available`).

## Exposure (WMS PRD census, 2026-10-21)

| Tenant | TRANSFER advices | `RECEIVING_TRANSFER` stock rows |
|---|---|---|
| WineCo (wsl) | 0 | 0 |
| Hydra (nywh) | 0 | 0 |
| ShipItEZ nywh | 0 | 0 |
| ShipItEZ c1wh | 1 (FINISHED, 2022-11-28, the v1-era transfer) | 2 (2022-11-28) |

So SBDEV-3854 does not make P2 reachable in practice on any current tenant. The proposals-register note "live
again once SBDEV-3854 ships" was true of the code path, and is moot for the data.

## Fix, when it becomes live (≈½ day incl. IT)

Refuse the container delete, in WMS, while any of its stock was received under a TRANSFER advice that is not
yet FINISHED (accepted). The refusal message: "accept or adjust transfer <advice number> first". This is the
same kind of guard as the SBDEV-3547 goods-out refusal.

Alternatives considered:
- **Suppress `MANUAL_REMOVAL` for that stock:** this hides a real loss from OMS after close.
- **Fix the floor in OMS:** the floor is deliberate ("inventory can never go negative").

## Second finding (P14, proposed)

Accepting a **short-delivered** transfer (`allowshortdelivery = true`) credits OMS the full ordered quantity,
because closeTransfer ignores what WMS received and credits by `order_item.quantity`. The OMS destination is
overstated by `Q − received`, and nothing reconciles it. This is independent of container deletes. The
exposure is nil for the same reason as P2.
