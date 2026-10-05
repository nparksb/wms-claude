---
name: replenish-dup-concurrency-slice-it-is-timing-flaky
description: "ReplenishDupConcurrencySliceIT.ac6 reds intermittently — the loser throws \"No replenish stock available\" instead of hitting idx_replenishorder_active_item_dest; rerun, don't debug your diff"
metadata:
  node_type: memory
  type: project
  originSessionId: 2684c8c6-288e-43fe-8de7-697d5acdd01a
  modified: 2026-09-23T07:15:20.902Z
---

`ReplenishDupConcurrencySliceIT.ac6_concurrentSameDemand_yieldsExactlyOneActiveOrder` (wms2-api failsafe lane) is **timing-flaky**. Measured 2026-09-23 on PR #405 (SBDEV-3471): red on the first CI run, green on `gh run rerun --failed` with identical code. It had passed on `develop`'s own run minutes earlier.

Signature of the flake, at assertion line ~247: `Expecting actual: "net.aim_ai.wms.exceptions.FacadeException: No replenish stock available with destination = …" to contain: "idx_replenishorder_active_item_dest"`. The losing thread lost the race one step EARLIER, at stock availability, because the winner had already reserved the stock. It never reached the unique index. That interleaving is legitimate: the test's "loser must fail on the DUPLICATE GUARD" assertion assumes one fixed ordering.

**Why:** a red develop push run silently stops deploying (see [[outbox-concurrent-enqueue-it-is-timing-flaky]]), and a red PR check tempts you to chase a diff that did not cause it.

**How to apply:** if this exact signature appears, rerun the failed job before touching anything. Any OTHER message from this test is real. A proper fix, which should be proposed as its own ticket, would accept either loser path, or give the fixture enough stock that both threads reach the index. Related: [[wms2-concurrency-it-fixture-traps]].
