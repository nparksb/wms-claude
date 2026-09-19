---
name: oms-v2-picking-date-utc-future-picking
description: "Post-migration \"Future Picking Date\" = OMS V2 stamps picking_date in UTC, not warehouse TZ; WMS is correct"
metadata: 
  node_type: memory
  type: project
  originSessionId: 59a49d44-d682-4314-8d9a-169d017b6ca6
---

Post-V2-migration UAT bug (WineCo wsl, LA, 2026-06-28): an OMS V2 order pushed to WMS v2 showed as PICK_PACK with state `FUTURE_PICKING_DATE` (80, UI label "Future Picking Date"). Root cause = **OMS V2 data**, NOT a WMS conversion error.

WMS `customerorder.pickingdate` is a plain `date`/`LocalDate`; OMS sends `picking_date` as a date string, WMS does `LocalDate.parse()` (no TZ math) and sets state 80 only when `pickingDate.isAfter(timezoneService.todayInWarehouse())` (warehouse-local today, the deliberate `[UTC migration — Phase 2.5]` fix in `OrderBatchCreationService` + `ReleaseOrderJobService`). Evidence (order id 31148668, client NP-260628-1): created `2026-06-29 00:08 UTC` = `2026-06-28 17:08` LA; warehouse today = 6/28; flagged future ⇒ OMS sent `2026-06-29` (its UTC "today") while LA was still 6/28. **Fix belongs in OMS V2**: derive picking/ship dates in the warehouse TZ (America/Los_Angeles), not UTC. Bad window = LA evening (~17:00 LA → 00:00–07:00 UTC); NY analog ~19:00 EST.

Separately, the order "wouldn't release" because **all instances had `app.cron=false`** → `OrderReleaseJob` (@Scheduled, advisory lock 100001) never fired, so nothing evaluated picking date vs today. Re-enabling `app.cron` released it (state 80→released→200 ASSIGNED). Release predicate: query `co.state < 200 AND co.pickingdate <= today(warehouse) AND cob.type=PICK_PACK`, then `releaseOrder()` re-checks `pickingdate.isAfter(todayInWarehouse())`. Changing pickingdate to today + cron on = releases on next tick (state 80 does not need manual reset). Related: [[wineco-wsl-v1-v2-migration-status]], [[wms2-ui-warehouse-timezone-stale-persistedstate]].
