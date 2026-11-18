---
name: order-by-limit-1-needs-a-mirrored-test-pair
description: "One test cannot pin an ORDER BY ... LIMIT 1 — the unordered scan may return the expected row anyway; use a mirrored pair"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 4ddfcc59-1650-45c2-b27a-e5f4e6c95b90
  modified: 2026-11-02T03:20:54.682Z
---

A single test cannot prove an `ORDER BY x LIMIT 1` is load-bearing. Measured on SBDEV-3128 (2026-11-02):
`backfill_lowestClientIdWins` set up "the client-5 row is first in heap order", but with `ORDER BY client_id`
dropped PostgreSQL still returned the client-1 row first (an index scan, not heap order), so the test stayed
green against the mutant. The test's own comment asserted a scan order the database never promised.

**Why:** without `ORDER BY`, PG's row order is unspecified — it depends on the plan (seq vs index scan), HOT
updates, and insert order. Any fixture that "arranges" physical order is guessing.

**How to apply:** pin the clause with a **mirrored pair** — the same rows with the ordering key and the
expected value swapped. Whatever row an unordered `LIMIT 1` returns, it is the wrong one in exactly one of the
two cases, so the mutant always kills one. Then mutation-check it (drop the `ORDER BY`, confirm exactly one of
the pair goes red with an attributable message). See [[mutation-fixture-needs-a-row-in-the-dominant-value-band]]
for the sibling "fixture can't distinguish" trap and [[pit-killed-does-not-mean-the-assertion-killed-it]].
