---
name: stockrecord-staging-scan-traps
description: Counting WMS stock moves from stockrecord double-counts every event and mixes two callers; both traps inflate concurrency scans
metadata:
  type: reference
---

Two traps when measuring stock movements out of `stockrecord` (both hit on SBDEV-3412, 2026-09-17):

1. **Every staging writes TWO rows ~5ms apart** — one with `amount 0.0000`, one with the real
   quantity. Any "events within N seconds" scan double-counts unless filtered to `amount > 0`.
   Unfiltered this produced 66 phantom "sub-5-second pairs" on one tenant that read as rampant
   concurrency; it was 33 single events.
2. **`activitycode = 'MANUAL_SPLIT'` has two producers.** `MobileTransferOrderService.transferStock`
   (handheld, one scan at a time) AND `StockunitService.transferStock` reached from
   `StockUnitController`'s bulk `ids` loop, which iterates **serially in one request thread**. The
   bulk path emits ~30 moves into one location inside one second. **No column in `stockrecord` names
   the producing caller** — they can only be separated by burst structure.

`operator` IS reliably populated (never null in any sample, 2-7 distinct per tenant), so it works as
a two-actor discriminator — but only if the floor does not share logins, which is an ops question no
query answers. See [[a-zero-scan-needs-a-positive-control]]: pair any such scan with a control like
`count(*)` on the unfiltered table.

Useful shape: window function `lag(created) OVER (PARTITION BY tostoragelocation, itemdata ORDER BY created)`.
