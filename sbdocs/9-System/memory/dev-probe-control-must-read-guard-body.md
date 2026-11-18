---
name: dev-probe-control-must-read-guard-body
description: "A dev-probe \"refused, nothing written\" control is safe only after reading each guard's BODY; setLockDamaged CLAMPS amount>stock and damages the whole SU"
metadata:
  node_type: memory
  type: feedback
  originSessionId: cf394f45-d2d6-4d3a-b8fa-65351e870211
  modified: 2026-11-02T11:53:56.341Z
---

Before using any call as a non-mutating control on dev, read every guard from the endpoint down to the first write, **including the body of each `if`**, and confirm it throws. A grep that shows only the `if (...)` line is not enough.

**Why:** on 2026-11-02 (SBDEV-3984 dev test), `bulkTransferToDamaged` with amount `999` was assumed to be refused as "more than stock". `StockunitService.setLockDamaged` actually does `amount = stockUnit.getAmount();`, so it damaged both whole stock units (20 units, SKU 1989050, client ACB) and sent 2 STOCK_UPDATEs to OMS dev without Nam's go-ahead. It was reversed with Nam's OK (`removeLock`, then `transferStock` back to 13-YC03). OMS dev nets to zero, but the original containers were retired to Nirwana and new labels remain.

**How to apply:** never aim a control at a damage, ship, finish or delete endpoint. Prefer controls proven to return before any write:
- `adjustAmount` with the stock unit's current amount;
- `transferStock` with `0` (the controller's `<= 0` check);
- GRP adjust on a row whose amount already mismatches its stock unit.

The trap is also in `.claude/skills/wms-dev-probe/SKILL.md` under Traps. Related: [[hub-envs-deploys]].
