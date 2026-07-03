---
title: "WineCo UAT — \"Future Picking Date\" + order not releasing (root-cause)"
type: report
status: resolved
project: [wms2, oms]
version: v2
requester: nam.park@siteboss.net
created: 2026-06-28
tags: [report, wms2, oms, utc, timezone, order-release, future-picking-date]
related:
  - ../../1-Projects/wms2/plan/260606-wineco-v1-to-v2-migration-runbook.md
  - ../../2-Areas/wms-utc-timezone-migration/README.md
---

# WineCo UAT — "Future Picking Date" + order not releasing

**Environment:** WineCo UAT (`wsl-wineco-uat`, DB `wh01_om1_v2`), after the v1→v2 UTC migration and full
v2 code deploy. Warehouse timezone: **America/Los_Angeles**.
**Sample order:** customer order id `31148668` — `058767-000001`, client order `NP-260628-1`, type `PICK_PACK`.

## TL;DR

There were **two independent issues**, both now understood:

1. **Order would not release** → caused by **`app.cron=false` on every WMS instance**, which disables the
   scheduled `OrderReleaseJob` entirely. It had nothing to do with the picking date. **Fixed** by
   re-enabling `app.cron`; the order released immediately on the next job tick.
2. **Order showed "Future Picking Date"** → caused by **OMS V2 sending a UTC-based picking date**, not by
   a WMS bug. WMS handled the data correctly. **Fix belongs in OMS V2.**

---

## Issue 1 — Order not releasing (RESOLVED)

`OrderReleaseJob` is a `@Scheduled` background job, gated per-instance by the `app.cron` flag. With
`app.cron=false` on all instances, the job **never ran**, so no order was ever evaluated for release —
regardless of its picking date or state. Editing the picking date therefore had no effect on its own.

**Resolution:** set `app.cron=true` (done by the operator). The order then released on the next tick:
order `31148668` is now **state 200 (ASSIGNED)**, `modified 2026-06-29 00:30 UTC` — immediately after the
flag was enabled.

How release works, for reference:
- The job fetches candidates with `co.state < 200 (ASSIGNED) AND co.pickingdate <= today(warehouse) AND
  cob.type = 'PICK_PACK'`, then re-checks `pickingdate.isAfter(todayInWarehouse())` before releasing.
- A "Future Picking Date" order (state 80) **does not** need a manual state reset — once its picking date
  is today-or-earlier and `app.cron` is on, the job transitions it forward automatically.

---

## Issue 2 — "Future Picking Date" comes from OMS data, not WMS

**"Future Picking Date" is a WMS order state** (`FUTURE_PICKING_DATE` = 80; the UI label is literally
"Future Picking Date"). WMS sets it **only** when the incoming picking date is *after* the warehouse's
local "today".

### What WMS does (correct)

- `customerorder.pickingdate` is a plain **`date`** column (Java `LocalDate`) — date only, no time, no
  timezone.
- On order create, WMS parses the OMS-supplied `picking_date` string verbatim: `LocalDate.parse(...)` —
  **no timezone conversion is applied to the date.**
- It then compares against the **warehouse-local** today (`TimezoneService.todayInWarehouse()`, i.e.
  `America/Los_Angeles`), and flags `FUTURE_PICKING_DATE` if the picking date is later. This warehouse-TZ
  comparison is a deliberate part of the UTC migration (so a UTC-evening request is not mis-judged).

So WMS does **not** shift or mis-convert the date. It faithfully reports that the order's picking date is
in the future *relative to the warehouse's day*.

### The evidence (order 31148668)

| Fact | Value |
|---|---|
| Order created | `2026-06-29 00:08 UTC` = **`2026-06-28 17:08` America/Los_Angeles** |
| Warehouse "today" at creation | **`2026-06-28`** (LA) |
| Client order number | `NP-260628-1` → intended for **6/28** |
| Resulting WMS state | `FUTURE_PICKING_DATE` (80) → UI "Future Picking Date" |

The order was created in the **evening in LA, which is already the next day in UTC.** WMS only flags
`FUTURE_PICKING_DATE` when the picking date is `>= 2026-06-29`. The order was meant for 6/28, so **OMS sent
`picking_date = 2026-06-29`** — i.e. OMS used a **UTC-based "today"** (it was 00:08 UTC) instead of the
warehouse's LA date (6/28).

### Root cause

**OMS V2 derives the picking/ship date in UTC rather than in the warehouse timezone.** During the window
when LA is in the evening but UTC has already rolled to the next day (~17:00 LA → midnight; `00:00–07:00`
UTC), every order OMS auto-dates is stamped **one day ahead** of the warehouse, and WMS correctly classifies
it as a future picking date.

This is the OMS-side mirror of the fix WMS already made: WMS computes "today" in the warehouse timezone;
OMS does not.

---

## Recommendation

- **Fix in OMS V2:** compute the order's `picking_date` (and any ship/pick dates) in the **warehouse
  timezone** (`America/Los_Angeles` for WineCo), not UTC. This is the actual defect.
- **Operational workaround (already used):** editing the picking date to the intended local day works; with
  `app.cron` enabled, the order releases on the next tick.
- **Check other regions:** an East-coast warehouse (e.g. NY) has the same exposure in its evening window
  (~19:00–24:00 local → after midnight UTC).
- **Unrelated but worth confirming:** `API_TIMESTAMP_FORMAT` on `wsl-wineco-uat` is `ISO8601_UTC` (the
  Phase-J flag is flipped). That is consistent with the v2 code being live; confirm it was intentional for
  this environment.

---

*Validated directly against `wsl-wineco-uat` (order 31148668, `los_sysprop`, `rest_idempotency`) and the
wms2-api source (`OrderBatchCreationService`, `ReleaseOrderJobService`, `OrderReleaseJob`, `TimezoneService`).*
