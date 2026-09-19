---
name: wineco-prod-autovacuum-off-and-replenishorder-no-state-index
description: WineCo v1 prod DB — replenishorder has no state index (slow every-minute cron); planner stats were stale post-06-06-cutover (NOT bloat) and autovacuum has never completed on the big tables
metadata: 
  node_type: memory
  type: project
  originSessionId: 1039835d-246e-4941-bcc5-e63901b61965
---

As of 2026-07-01, on WineCo v1/wms-api production DB (`wms1-wineco` MCP, `wh01_om1`): the replenishment cron (`ReplenishOrderJob.doCalculation`, default **every minute**) is the slowest job across tenants. Two findings:

1. **`replenishorder` has no index on `state`.** 61,071 rows (count(*)), 99% terminal (`state>=700`), only ~624 open (`state<=300`). ~6 job phases filter by `state` → full seq scans every minute. Fix: partial index `(state) WHERE state < 700` (subsumes the proposed narrow `WHERE destination_id IS NULL AND state<=300`). See plan `sbdocs/1-Projects/wms1/plan/260701-wineco-replenishment-job-index-and-cadence.md` (Flyway V1.26.31 — latest real migration is V1.26.30, NOT V1.1.x).

2. **CORRECTION to an earlier claim: the tables were NOT 68–87% bloated.** That was an artifact of reading `pg_stat_user_tables` counters after they were reset at the 2026-06-06 cutover (`pg_stat_database.stats_reset`). Real issue = **stale planner statistics** (ANALYZE hadn't run since cutover): planner saw customerorder ~1,700 rows (actual ~479K), stockunit ~8K (actual ~1.9M), customerorder_position actual ~1.7M. A manual `VACUUM (ANALYZE)` at 2026-07-01 13:39 UTC fixed the stats; dead tuples are ~0. **Autovacuum is ON** (track_counts on, no per-table disable, default thresholds) — a manual VACUUM does NOT start/restart it. But `last_autovacuum` was NULL on all 5 tables for the 25 days since the reset → it has never *completed* on them; prime suspect is worker cancellation by the every-minute cron's locks. To verify continuous operation: `log_autovacuum_min_duration=0` + `pg_reload_conf()`, then monitor.

Also: `ReplenishOrderJob.java:93` `recalculateOpenOrders(true)` bypasses the `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` throttle (default "0" → never skips), so the cadence fix is inert until the sysprop is set >0. Full report: `sbdocs/3-Resources/reports/260701-wineco-replenishment-job-slow-runtime-index-eval.md` (§5.5 carries the correction). Related: [[wineco-wsl-v1-v2-migration-status]], [[wms2-seqentities-dual-island-id-space]].