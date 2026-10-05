---
name: population-query-must-filter-to-the-paths-precondition
description: "A \"how many rows does this path touch\" DB count must filter to rows the path can actually accept — SBDEV-3470's ~142 came from inbound pallets scanGate rejects"
metadata:
  node_type: memory
  type: feedback
  originSessionId: a541b2e1-815c-4ba3-af51-93b6a1077a65
  modified: 2026-09-23T07:23:59.028Z
---

When sizing a code path's exposure from prod data (fan-out, lock count, p99), filter the population to rows that pass the path's own guards. Counting "every pallet with children" pulled in 3 INBOUND receiving pallets (70 Case children, no orders) that truck-loading scanGate rejects. That produced a false "bimodal, ~142 locks on 6.5% of pallets" claim. The claim went into 3 javadocs, a workflow doc, a plan, and a whole ticket (SBDEV-3470) proposing a production refactor. Real max on order-bearing pallets: 14 parcels / 28 locks.

**Why:** the outliers in a population count are exactly where rows from a different flow hide. The correction itself then produced a new false claim: I said the ~142 had "counted stockunits (88) as locks", but the recorded derivation was 1+1+70+≤70 orders (70+88 = 158). The 88 had only been quoted next to it. Re-derive a figure from its recorded derivation before explaining what was wrong with it.

**How to apply:** before quoting an exposure figure, (1) inspect the top outliers (label, type, location), not just the counts; (2) join the path's precondition (here `customerorder.parcel_id`) into the query; (3) count only acquisitions the code actually locks; (4) find the figure's ORIGINAL derivation (the plan evidence file) before diagnosing it. And don't overcorrect: "max 28" is a property of the data, not a bound the method enforces — B3 locks every child before PHASE C rejects. See [[a-zero-scan-needs-a-positive-control]], [[fixing-a-false-claim-tends-to-produce-a-new-one]].
