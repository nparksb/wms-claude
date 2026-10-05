---
name: adjust-reserved-amount-is-the-release-replen-hold-button
description: Ops use Adjust Reserved Amount → 0 to take stock back from replenishment orders; refusing such cuts would block ~300 ops / 90 d on WineCo
metadata:
  node_type: memory
  type: project
  originSessionId: 9775f266-5768-4333-9db0-d5d02f6f315b
  modified: 2026-10-02T15:43:28.844Z
---

Measured on PRD 2026-10-02: 330/330 manual reserved cuts in 90 days went to **0** (WineCo 311 by 5 operators, c1wh 19), and 96% hit an SU with a live replen order. All 23 under-held open orders had such a cut first. The pre-SBDEV-3618 recalc on prd then re-granted most cuts within 10 minutes (stockrecord `REPLENISHMENT` rows under the order number).

**Why:** this is why SBDEV-3622 attributes the cut (cancel/shrink the holding orders) instead of refusing it — refusing would have blocked nearly every real use.

**How to apply:** any change touching `StockunitService.adjustReservedAmount` or reservation holders: assume the dominant use is "cut to 0 to release a replen hold". Re-query before quoting counts. Related: [[held-share-model-overstates-other-holders-on-prd]].

**Measured on DEV after SBDEV-3622 shipped (2026-10-02):** the replenishment job runs every minute on DEV *and* PRD (`REPLENISHMENT_TIMER_MINUTE='*'`). Partial cuts regrew in 20–33 s (one order grew past its pre-cut request by absorbing the freed surplus), and a cut to 0 was re-claimed by a generator-created NEW order on the same SU in 17 s. So "honoured until the next cycle" (D-H1) means under a minute, and P-3 (re-source) is the real limiter of the button's effect.

**P-3 fixed by SBDEV-3636 (merged e3dfcc72, on DEV 2026-10-02):** automatic sourcing skips a just-cut SU for `REPLENISH_MANUAL_CUT_COOLDOWN_MINUTES` (default 60; no row → 60; ≤0 off; clamp 1440). Verified live: cut SU 929025745, and the cron sourced the next SU 929025744 instead (REPL389515), with nothing touching the cut SU. Partial-cut regrowth (D-H1) is still NOT covered, by decision. Any NEW system writer of a negative `MANUAL_ADJUSTMENT` row must be added to `StockunitRepository.MANUAL_CUT_COOLDOWN_EXCLUSION`'s exclusions, or it starts a cooldown.
