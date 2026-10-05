---
name: replen-monitor-empty-cells-are-not-data-defects
description: "Replenishment Monitor 'Repl From 0 / Unassigned' reports (SBDEV-1404, 2577, 3587) were misreadings, not data bugs — check these three facts before investigating"
metadata:
  node_type: memory
  type: project
  originSessionId: 73cd9e4e-5020-44cc-928e-a06193232f4d
  modified: 2026-09-29T22:50:56.635Z
---

Filed three times by WineCo (SBDEV-1404, SBDEV-2577, SBDEV-3587). Verified on WineCo PRD 2026-09-30: every time, the data was accurate.

- **"Repl From 0"** was the ⓘ icon, which means *no open replenishorder* (state < 600). No RO row has source '0'.
- **"Repl To Unassigned"**: all 14 open ROs with a null destination were for SKUs with **zero fix_location_assignment**. The operator chooses the destination at drop time.
- **"Qty Req"** is total open PICK_PACK order demand, not a replenishment quantity, so moving stock does not reduce it.
- **Why ROs are missing:** `ReplenishmentOrderMaintenanceService.recalculateOrder` sizes and cancels orders against the pick-face upperbound, while the monitor lists SKUs by demand. When demand exceeds the upperbound, the SKU stays on the monitor while its ROs keep getting cancelled (~55% of WineCo ROs end CANCELED, all with no operator). This was proposed as T3, not filed.

**Why:** each recurrence cost a fresh investigation, because nothing on the screen explained the empty cells.

**How to apply:** for the next monitor-accuracy report, first check whether PR wms2-web-ui #151 (which shows the reasons in the cells) is deployed. Then bucket the live monitor rows by RO/FLA/upperbound/replenishable stock before reading any code.

Related: [[wms-mcp-tools-not-surfaced-use-psql-direct]] (the node pg fallback worked for wsl-wineco-prd when its MCP timed out).
