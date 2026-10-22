---
title: "SBDEV-3678: Two production decisions on the WMS v2 DB load (query stats + replenish sweep cadence)"
type: decision-brief
status: decision-2-tried-and-reverted
version: "v2"
scope: "v2/wms2-api production Postgres (all v2 tenants on one server): measuring the load, and an interim throttle on the replenish cron's full sweep"
owner: "Nam Park"
created: "2026-10-07"
updated: "2026-10-07"
last_verified: "2026-10-07"
verified_by: "Claude (read-only queries on wsl-wineco-prd; code read of origin/develop 969882a8 and origin/main = prd v0.0.37)"
related:
  - "ClickUp SBDEV-3678 (PR-A, on dev): https://app.clickup.com/t/868mekqfp"
  - "ClickUp SBDEV-3685 (PR-B, gated on Decision 1): https://app.clickup.com/t/868merd11"
  - "https://github.com/SiteBossInc/wms2-api/pull/473"
  - "sbdocs/3-Resources/data-dictionary/wms2-sysprop-catalog.md"
  - "sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md"
tags:
  - decision
  - performance
  - replenishment
  - postgres
---

# SBDEV-3678: two production decisions on the WMS v2 DB load

**Status (updated 2026-10-07 23:31 UTC): Decision 2 was tried on WineCo prd, measured, and reverted; the result is below. Decision 1 is still open.** Point-in-time brief, 2026-10-07. Every fact below was checked on that date against the code (`origin/develop` `969882a8`, and `origin/main`, which production runs as `0.0.37`) and against the WineCo production database (read-only).

## Context

On 2026-10-07 Leo reported that the order-release and replenish crons were "murdering postgres". What has happened since:

- **PR-A of SBDEV-3678 is merged and on dev** ([PR #473](https://github.com/SiteBossInc/wms2-api/pull/473), `969882a8`; **not on production yet**, which is a DevOps release):
  - `releaseOrder` prefetches only the order's own fix assignments. On WineCo production that is 4.29 per order on average, instead of all 1,525.
  - The handheld multi-unit-load confirm now recalculates only its own item, with no whole-warehouse sweep and no refill.
- **The larger redesign is split to SBDEV-3685 and gated on Decision 1.** It makes both crons' per-minute work proportional to what changed.
- **The root cause of the production load is unmeasured.** `pg_stat_statements` is not installed. Table counters show the biggest read volume on WineCo since 2026-09-25 is full scans of `stockunit` (about 13 billion rows) and `unitload` (about 6 billion rows). **No query has been tied to them yet.** The fix-assignment prefetch PR-A removed is about 3% of that volume.

The two decisions are independent. **Decision 1** finds out what is actually loading Postgres. **Decision 2** is cheap, reversible relief that may or may not touch the real cause.

---

## Decision 1: turn on query statistics (`pg_stat_statements`) on production

### Why
Without per-statement statistics, nobody can say which SQL causes the `stockunit`/`unitload` scans or what share of the load the two crons are. SBDEV-3685 requires a 24–48 hour baseline before anyone builds it, and the before/after check on the fix needs it too.

### What the production server looks like (queried 2026-10-07)
- **One Postgres server holds every production database:** the WineCo, Hydra and ShipItEZ v2 tenants (`wh01_om1_v2`, `wh01_hydra_v2`, `wh01_shipitez_v2`, `wh02_shipitez_v2`), the landlord (`wms2_landlord`), both Keycloak databases, and the old v1 databases.
- **Image:** official `postgres:14-alpine` (PostgreSQL 14.23), self-hosted in Docker, not a managed service. The superuser role is `doadmin`. The app roles (for example `wh01_om1_v2_app`) are not superusers.
- **The extension ships with the image (version 1.9) but is not loaded and not installed.** The `pg_stat_statements.*` settings do not exist, which means the library is not in `shared_preload_libraries`.

### Options

| Option | Change to production | What it tells us | Cost / risk |
|---|---|---|---|
| **A. Sample live queries** by polling `pg_stat_activity` every few seconds for a few hours | **None** (read-only) | Which queries are running most often at any moment | A sample: cheap queries that run very often are under-counted. Can start today |
| **B. Slow-query log**: `ALTER SYSTEM SET log_min_duration_statement = '500ms'; SELECT pg_reload_conf();` as `doadmin` | Configuration reload, **no restart** | Every statement slower than 500 ms, with its text | Misses cheap, very frequent statements. Log volume rises |
| **C. `pg_stat_statements`** | **Restart Postgres** | Call count and total, mean and max time for every statement, across all databases | A short outage for **every production tenant and Keycloak**. Runtime overhead about 1–2%. Removing it needs another restart |

### Steps for option C (infra: Joe)
1. Add `pg_stat_statements` to `shared_preload_libraries` in the container's Postgres configuration.
2. Restart Postgres in a quiet window, and tell the floor first, because handhelds and logins fail while it is down.
3. As `doadmin`, in one database (for example `wh01_om1_v2`), run `CREATE EXTENSION pg_stat_statements;`. The view covers every database on the server; filter by `dbid`.
4. `GRANT pg_read_all_stats TO <the role that will read it>;` Without it, other roles' query text shows as `<insufficient privilege>`.
5. Record a 24–48 hour baseline on SBDEV-3685: top statements by `total_exec_time`, plus calls and mean time, per database.

### Recommendation
**Start A now.** It changes nothing (note: the read-only MCP role `wh01_om1_v2_app` lacks `pg_read_all_stats`, so it sees query text only for WineCo's own app sessions. A server-wide sample needs `doadmin` or that grant) and may be enough to point at the scans. **Book C for the next maintenance window**, because only C satisfies SBDEV-3685's gate and gives a usable before/after.

---

## Decision 2: interim relief by slowing the replenish cron's full sweep

### What the setting is
The sysprop `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS`, per tenant, in `los_sysprop`.
- **Confirmed absent on WineCo production** (`wh01_om1_v2`). The only `REPLENISHMENT_RECALCULATION_*` row is `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS`, which the sweep rewrites every minute. No production tenant has the cadence row.
- **When absent, the code default is `"0"`, meaning a full sweep every tick (every minute).** Production code (`origin/main`, `0.0.37`) uses the same key and parsing: a number of seconds, and anything ≤ 0 means every tick.

### What it does
In `ReplenishmentOrderMaintenanceService`, `recalculateOpenOrders(false)` (the cron's full sweep) returns immediately unless the configured number of seconds has passed since `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS`.

- **What gets throttled:** the per-order full sweep. On WineCo that covers 570 open replenishment orders every minute. Each one costs two `SELECT … FOR UPDATE` row locks (the order and its source stock unit) plus about 6 queries: roughly 3,400 statements and 1,100 row locks a minute. At 300 seconds, about a fifth of that.
- **What still runs every minute:**
  - the cron's sub-operations;
  - the per-item recalculation of every item those sub-operations touched;
  - the handheld move path, which redirects an order immediately when its stock is moved.

### What gets slower (why this needs a sign-off)
For orders no sub-operation touched that minute, self-healing waits up to the cadence (about 5–6 minutes at 300) instead of at most 1 minute. Self-healing here means:
- redirecting an order whose source stock was picked, emptied or locked;
- cancelling an order with no remaining source;
- correcting its reserved share;
- retrying a deferred (`CONTENDED`) redirect.

An operator may briefly see a replenishment pointing at a stale source. This breaks the principle agreed on SBDEV-3678: "no reaction that happens within a minute today may become slower".

### ⚠ Production limitation
Production does not have PR-A. On `main`, **every handheld multi-unit-load confirm still runs a forced full sweep that ignores the cadence.** It also rewrites the last-run timestamp, which pushes the cron's next scheduled sweep further out. During busy handheld periods the saving is therefore smaller, because confirm-driven sweeps continue. The full benefit arrives when PR-A is promoted to production.

### The catch
It is **not proven** that this sweep is what loads Postgres. It is a plausible but unmeasured contributor, and the largest unattributed cost is the `stockunit`/`unitload` scans. The relief is cheap and instantly reversible, but it may not fix the symptom.

### SQL (WineCo production, `wh01_om1_v2`; repeat per tenant if wanted)
This follows the repo's own Flyway seed-insert pattern (`V2.2.10`). The id comes from `seqentities`, the sequence the app uses (allocation size 1, increment 1). The `NOT EXISTS` guard makes it safe to run twice.

```sql
INSERT INTO public.los_sysprop
    (id, version, entity_lock, hidden, syskey, sysvalue,
     workstation, client_id, groupname, description, created, modified)
SELECT
    nextval('public.seqentities'), 0, 0, false,
    'REPLENISHMENT_RECALCULATION_CADENCE_SECONDS', '300',
    'DEFAULT', 0, 'Operation Options',
    'SBDEV-3678: minimum seconds between the replenish cron''s full recalc sweeps. 0 or absent = every tick. Forced sweeps (multi-UL confirm, before PR-A) ignore it.',
    now(), now()
WHERE NOT EXISTS (
    SELECT 1 FROM public.los_sysprop
    WHERE syskey = 'REPLENISHMENT_RECALCULATION_CADENCE_SECONDS'
);
```

**Verify the row:**
```sql
SELECT id, syskey, sysvalue, workstation, client_id, created
FROM public.los_sysprop
WHERE syskey = 'REPLENISHMENT_RECALCULATION_CADENCE_SECONDS';
```

**Confirm it is working.** The timestamp should advance about every 5 minutes instead of every minute, except when confirms force a sweep:
```sql
SELECT sysvalue::bigint AS epoch_ms, to_timestamp(sysvalue::bigint / 1000.0) AS last_sweep
FROM public.los_sysprop
WHERE syskey = 'REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS';
```

**Turn it off.** Either statement takes effect within the same cache window:
```sql
UPDATE public.los_sysprop SET sysvalue = '0', modified = now()
WHERE syskey = 'REPLENISHMENT_RECALCULATION_CADENCE_SECONDS';
-- or
DELETE FROM public.los_sysprop WHERE syskey = 'REPLENISHMENT_RECALCULATION_CADENCE_SECONDS';
```

### Operational notes
- **It takes up to about 2 minutes to apply.** Sysprops are cached per replica. No restart is needed.
- **The interval is about 5–6 minutes.** The cron fires once a minute at :20 seconds, so a sweep runs on the first tick that is at least 300 seconds after the last one.
- **It applies per tenant.** The other three production tenants have their own databases and need the same insert to be throttled.
- **Applied on WineCo prd at 21:29:25 UTC (2026-10-07)**, value `300`. No other tenant has it.

### Result (measured 2026-10-07)
`pg_stat_user_tables` deltas on `wh01_om1_v2`:

| Table | Before: 18:33→21:45 (192 min, mostly pre-change) | After: 21:45:49→23:30:47 (105 min, all post-change) |
|---|---|---|
| `stockunit` full scans | 2.5/min, 2.1M rows/min | **2.8/min, 3.1M rows/min** |
| `unitload` full scans | 1.9/min, 0.82M rows/min | **2.3/min, 1.27M rows/min** |
| `fix_location_assignment` full scans | 17/min | **8.6/min** |
| `replenishorder` full scans | ~0.05/min | **0** |

**The full sweep is not what drives the `stockunit`/`unitload` scans.** They held or rose while the sweep ran about a fifth as often. This is one window, and floor activity was not controlled, but the expected drop would have shown. Under this brief's own criterion, the setting buys slower self-healing for no measured gain on the main cost. **Recommendation: set it back to `0`** (the SQL is above), unless the floor wants to keep it for the smaller `fix_location_assignment` saving.

**Reverted 2026-10-07 23:33:08 UTC** (set to `0`). Verified: sweeps ran at 23:36:24 and then 23:37:22, so every minute again. The row stays at `0`, which behaves the same as no row.

### Recommendation
**Run Decision 1's option A first** (about an hour, no change to production). If the replenish sweep's statements are near the top, set the cadence to 300 on WineCo and watch the job's `end. took {}ms for <tenant>` log lines. If they are not, skip it and let SBDEV-3685 follow the data.

---

## Summary

| | Decision 1: query statistics | Decision 2: sweep cadence |
|---|---|---|
| Purpose | Find what is actually loading Postgres | Cheap relief while that is unknown |
| Change | A: none · B: config reload · C: Postgres restart (all tenants and Keycloak) | One `los_sysprop` row per tenant |
| Reversible | A, B: yes, instantly · C: needs another restart | Yes, within about 2 minutes |
| Risk | C: brief outage | Replenish self-healing up to about 5 minutes slower, and may not address the real cause |
| Owner | Infra (Joe) for B and C; anyone with read access for A | Nam / Leo sign-off; anyone with production write access to run it |
| Recommendation | A now; C in the next window | Only if A shows the sweep near the top |
