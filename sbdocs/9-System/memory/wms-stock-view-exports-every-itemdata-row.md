---
name: wms-stock-view-exports-every-itemdata-row
description: "WMS `stock_view` (source of INVENTORY_FULL_EXPORT) selects every itemdata row with NO WHERE clause — zero-stock SKUs are still exported, so depleting stock never removes an item from the OMS export."
metadata: 
  node_type: memory
  type: reference
  originSessionId: b569dc6d-2bf6-4ec2-b56e-388516b2932c
  modified: 2026-07-28T23:14:26.238Z
---

`stock_view` is what `StockSummaryExportJob` → `WarehouseStockReportService` exports to OMS as
`INVENTORY_FULL_EXPORT`. Its definition is:

```sql
FROM itemdata i
  LEFT JOIN stockunit su ON su.itemdata_id = i.id
  LEFT JOIN client   c  ON i.client_id = c.id
  LEFT JOIN unitload ul ON su.unitload_id = ul.id
GROUP BY i.id, i.item_nr, c.id, c.cl_nr
```

**`FROM itemdata` + LEFT JOINs + no `WHERE`.** Every itemdata row appears, stock or not.

**Why:** the intuitive fix for "OMS rejects SKU X in the export" — write off / deplete the stock — **does not
work**. The row stays in the view at `total_stock = 0` and keeps exporting. Verified on WineCo production: Elk
Cove's `PNWV20` exports at `total_stock = 0` and is accepted. This wrong conclusion was reached and had to be
retracted on SBDEV-2748.

**How to apply:** to stop an item being exported you must remove/retire the **itemdata row** (blocked by the
`stockunit` FK, and destroys history) — so in practice the fix for an unknown-SKU rejection belongs on the
**OMS side**: register the missing `(client, item_nr)` pair.

Also note `total_stock` excludes `entity_lock IN (405, 2)` on either stockunit or unitload, so a SKU can show
`total_stock = 0` while `SUM(stockunit.amount)` is large — don't treat the raw sum as the exported quantity.

**Field landmine:** the export's `itemDataNumber` is **`itemdata.item_nr`**, NOT `itemdata.name`
(`WarehouseStockReportService:163` → `dto.setItemDataNumber(report.getItemNr())`). In **v1** the column is
`item_nr`; in **v2** it is `itemnr`. Searching the wrong column returns zero rows and looks like "the SKU does
not exist".

Related: [[wms2-outbox-dispatcher-status-blind-silent-loss]] — this export path hard-codes
`MessageStatus.SENT` regardless of the response body (`StockSummaryExportJob:299-310`), which is why one
unmapped SKU failed silently for 19 months (SBDEV-2748).
