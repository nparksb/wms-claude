---
name: wms2-outbox-latency-baseline-2026-09-13
description: "Measured WMS->OMS outbox latency across all v2 envs 2026-09-13; PRD RELEASED is phase-locked at a full poll tick (stddev 0.20s), not averaging half of one"
metadata:
  node_type: memory
  type: project
---

Baseline taken 2026-09-13 from `outbox_message` (`created_at` -> `sent_at`, SENT rows retained 7
days — **no instrumentation is needed to measure this, the data is already in the table**).

**PRD hydra/nywh is low volume (80 SENT rows/7d) and its dominant type is phase-locked.**
`ORDER_BATCH_PICKING_RELEASED`: n=26, avg 14.9s, min 14.32s, max 15.2s, **stddev 0.20s** against a
15s poll. That is a full deterministic tick every time, not the avg-half-interval a uniform arrival
would give. Cause: RELEASED is enqueued by `ReleaseOrderJobService` i.e. **`OrderReleaseJob`, itself a
cron job** — two schedulers on one clock, the producer committing just after the consumer's claim and
missing it every cycle. Picker-triggered types behave normally by contrast (`STARTED` min 0.89s,
stddev 4.63).

**How to apply:** when a queue's wait time has a tiny stddev pinned at the poll interval, look for a
CRON PRODUCER, not for load. And do not quote "average = half the interval" for a type whose producer
is scheduled — measure the stddev first.

Other envs, same sweep: UAT shipitez/c1wh (269 rows) showed the 40 rows/min ceiling — p95 214s, with
RELEASED < STARTED < FINISHED each ~one tick apart (the per-aggregate gate draining a chain). DEV
wineco showed max 5387s = **89.8 min**, independently confirming PR #351's "~90 minutes" claim for a
1,200-order club run. UAT shipitez/nywh has an empty table (verified with a positive control — true
zero, not a broken instrument).

**PRD has carried 2 undelivered `FAILED_TERMINAL` rows since 2026-07-13** — ids 81/82, both
`ADVICE_CLOSE` (404, and a read timeout on `/services/call/closeAdvice`), 5 attempts exhausted.
Nothing is blocked behind them (0 held rows) but OMS never learned of those two advice closures, and
nobody could have noticed: `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` defaults off and nothing scrapes
Prometheus. See [[wms2-metrics-exist-but-nothing-scrapes-them]].

Related: [[wms2-outbox-dispatcher-status-blind-silent-loss]], [[a-zero-scan-needs-a-positive-control]].
