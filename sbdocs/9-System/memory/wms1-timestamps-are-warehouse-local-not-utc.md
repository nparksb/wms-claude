---
name: wms1-timestamps-are-warehouse-local-not-utc
description: v1 WineCo customerorder created/modified are stored in WAREHOUSE-LOCAL time, not UTC — so `now()`/`current_timestamp` comparisons are off by the tz offset and read as a dead cron
metadata:
  type: reference
---

On WineCo v1 prod (`wh01_om1`), `customerorder.created` / `.modified` are stored in **warehouse-local**
time (`los_sysprop` `System Time Zone` = `America/Los_Angeles`), while Postgres `current_timestamp` /
`now()` return **UTC**. A `WHERE modified > now() - interval 'N hours'` filter is therefore off by the
offset (7–8h) in the direction that hides recent rows.

**Measured 2026-09-16** — hour-of-day histogram of `customerorder.created` over 14 days: rows only in
hours **07–16**, zero in 17–06 (18/35/150/260/277/75/109/22/140/154). A warehouse workday in local
time. Stored as UTC the same workday would land at 14:00–23:00.

**Why:** the code asserts the opposite. `OrderReleaseJob.releaseOrders` carries the comment *"all the
date stored in the DB is UTC but make sure a warehouse's time zone is used…"* and then formats
`new Date()` through the warehouse tz before comparing against `pickingdate`. The two instruments —
the comment and the data — **disagree**, and that disagreement is the finding. The formatting step is
consistent with local storage whatever the comment says.

Cost when missed: on SBDEV-3371 a first pass showed an apparent ~20-hour gap in order activity, which
reads as a stopped release cron and sends the investigation down a false path.

**How to apply:**
- Never date-filter these columns against `now()` / `current_timestamp` directly; compare against
  literal local timestamps, or check `max(created)` first and reason from the histogram.
- Proven for `customerorder` only. Do **not** generalise to other tables (`stockunit`, `stockrecord`,
  `pickingorder`) without re-running the histogram there — some may genuinely be UTC.
- An apparent "no activity in N hours" on this DB is a timezone hypothesis before it is an outage
  hypothesis. See [[a-zero-scan-needs-a-positive-control]].

Related: [[wms-on-hold-55-is-fragmentation-not-shortage]]
