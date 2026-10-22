---
name: hub-flaky-its
description: Integration tests known to be timing/order flaky; rerun before investigating. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Known flaky ITs (rerun first)**. Moved out of MEMORY.md on 2026-10-15 to keep the index under its size limit; each line links the member memory.

- [[outbox-concurrent-enqueue-it-is-timing-flaky]]: OutboxConcurrentEnqueueIT flaky
- [[replenish-dup-concurrency-slice-it-is-timing-flaky]]: ReplenishDupConcurrencySliceIT flaky
- [[outbox-lane-claim-it-order-flaky]]: OutboxLaneClaimIT reds in full run
- [[wms2-testcontainers-reuse-breaks-an-it]]: TC reuse breaks ParcelMonitor IT
