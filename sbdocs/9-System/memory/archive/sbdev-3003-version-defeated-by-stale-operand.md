---
name: sbdev-3003-version-defeated-by-stale-operand
description: A re-fetch that supplies a fresh @Version while the value comes from a stale snapshot commits a SILENT lost update — and the v1 tx-map wrongly said these entities had no @Version
metadata: 
  node_type: memory
  type: project
  originSessionId: 40648237-8207-4c72-9359-81f9619edc11
  modified: 2026-08-20T19:02:36.715Z
---

SBDEV-3003 (WineCo ST#1116). `v1/wms-api StockunitBusinessService.java:269-270`:

```java
Stockunit freshSourceStockunit = stockunitRepository.findById(sourceId).orElseThrow(...);
freshSourceStockunit.setAmount(sourceStockunit.getAmount().subtract(amount)); // stale operand
```

Re-fetches the row, then writes an **absolute** value computed from the caller's **stale** instance.
Measured on v1 DEV (CWUSTK): one Move Stock of 12 → two committed txns, both `STOCK_REMOVED`
reporting `amountstock=2988`, final 3012 on hand vs 3000 received = **+12 phantom**.

**How `@Version` is actually defeated — NOT the obvious way.** The losing transaction issues **no
UPDATE at all**: `stockunit 21376110` sits at `version=1`, modified at the *first* transaction's
timestamp. Hibernate's dirty check compares the freshly-loaded 2988 against the computed
`3000 − 12 = 2988`, finds the entity clean, and emits no SQL. `@Version` is never consulted because
there is no statement to guard, and the debit is simply dropped. **Consequence: zero forensic trace
on the row** — no version bump, no `modified` change — so no `stockunit`-based query finds victims.
Key detection on the duplicate `stockrecord` pair instead:

```sql
SELECT itemdata, fromunitload, amount, amountstock, count(*) FROM stockrecord
WHERE type='STOCK_REMOVED' GROUP BY 1,2,3,4
HAVING count(*)>1 AND max(created)-min(created) < interval '10 seconds';
```
Validated both ways: finds the CWUSTK case on `wh01_om1` (1 occurrence in all of 2026), returns zero
on `wh01_om1_v2`. **`entityManager.detach` before the re-fetch is mandatory** — otherwise a managed
caller instance makes `findById` return the identical object and the fix is a silent no-op.
`stockrecord` deltas still sum to 3000, so **the audit trail certifies the inventory as correct
while `stockunit` is inflated** — which is why it went unnoticed and why WMS diverged from OMS
rather than from itself.

**The general lesson:** `@Version` protects *which row state you overwrite*, never *which values you
computed*. The re-fetch makes it worse than doing nothing — saving the stale entity directly would
have thrown `OptimisticLockException`. When fixing a read-modify-write, the operand and the
persisted instance must be **the same object**. Grep for it with a backreference:
`([A-Za-z_]\w*)\.setX\(\s*(?!\1\b)\w+\.getX\(\)\.(add|subtract)\(` — 1 hit in v1, 0 in v2.

**Doc landmine that caused the wrong fix to be planned:**
`sbdocs/3-Resources/architecture/wms1-transaction-boundary-map.md` §8.1 listed `Stockunit`,
`Pickingorder`, `Customerorder`, `CustomerorderBatch`, `Billoflading`, `Replenishorder` as "notably
**missing** `@Version`". **All six have it** (45 of 67 model classes do; `Stockunit.java:43-44`).
That sentence is what pushes you to add a pessimistic lock. Corrected 2026-08-20.

**Design outcome:** the planned `findByIdForUpdate` port from v2 was **reversed** after review — it
would have added a lock across **23 call sites / 11 services**, including `BillofladingService:992`
inside a per-stockunit loop and `CustomerorderBatchService:666-684` in nested loops under one
`@Transactional` at `:558`, in a codebase with **zero lock timeouts** in `src/main`. The accepted
fix is ~5 lines: re-fetch in-tx, put the `:141` availability guard on the re-fetched instance, do
the arithmetic on it. Measured: that alone makes the gate's AC-1 (the inflation) and AC-4
(negative-stock guard) pass. Also note `findByIdForUpdate` is **JPQL**, so an L1 hit returns the
cached instance unrefreshed — a lock without `entityManager.detach` (see `:372`) would have been
decorative.

v2 is NOT affected: `:208-214` locks and refreshes, `:373` computes from the locked instance.
Related: [[wms1-osiv-not-pinned-dev-prod-divergence]], [[idle-review-subagent-is-not-a-passing-review]].
