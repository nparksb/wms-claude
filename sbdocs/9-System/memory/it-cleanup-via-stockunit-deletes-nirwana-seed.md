---
name: it-cleanup-via-stockunit-deletes-nirwana-seed
description: "An IT cleanup that collects unitload ids FROM stockunit will delete the seeded 'Nirwana' unit load (id 1) after any delete/adjust-to-0, breaking every later IT on the reused container"
metadata:
  node_type: memory
  type: feedback
  originSessionId: accbb0fa-a9ea-4061-b4d7-305226e8dc0b
  modified: 2026-11-11T12:31:01.312Z
---

`StockunitBusinessService.sendStockUnitToNirvana` re-points the stock unit's `unitload_id` to **1**, the seeded unit load with labelid **'Nirwana'** (from the V2.2.00 seed). Any IT that calls `GoodsReceiptPositionService.delete`, adjusts a stock unit to 0, or does anything else that "sends to Nirvana" leaves its own stock unit on unit load 1. A cleanup that then does `SELECT unitload_id FROM stockunit WHERE <my rows>` followed by `DELETE FROM unitload WHERE id = ? AND NOT EXISTS (stockunit on it)` **deletes the shared seed row**.

After that, every IT on the **reused** Testcontainers DB that touches Nirvana fails with "Nirwana unit-load row is missing from tenant null". That includes other sessions' ITs, and the failure looks like someone else's state leak. Measured on SBDEV-4107 (2026-11-11): first blamed on peer sessions, then traced to our own `Sbdev4107ReceivingItSupport.wipeReceivingWorld`.

**Why:** the reused container is shared machine-wide, and the seed row is never re-created unless the container is dropped.

**How to apply:**
- In IT cleanup, never collect unit-load ids through `stockunit`. Delete only the unit loads your fixture created, keyed by your own label or id band, and always exclude id 1 / 'Nirwana'.
- After a cleanup that ran a delete or adjust-to-0, assert that the Nirwana row still exists.
- If you see "Nirwana unit-load row is missing", check by **labelid**, not id: `SELECT id FROM unitload WHERE labelid='Nirwana'`. Lookups go by label (`nirvanaUnitload` → `findByLabelid`), and labelid has two UNIQUE indexes. Another fixture may already have re-created the row under a new id (13794 on 2026-11-11). In that case a seed-id INSERT fails with 23505, and forcing it would leave two rows and break every delete. Insert from the seed, with its columns named, only if **no** labelid row exists. V2.2.00 seeds no `unitload_record` row for it.

Related: [[reused-container-accumulates-sequences-not-just-rows]], [[wms2-reused-container-fills-after-repeated-full-runs]].
