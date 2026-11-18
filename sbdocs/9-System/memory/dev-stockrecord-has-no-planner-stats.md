---
name: dev-stockrecord-has-no-planner-stats
description: dev_wh01_om1 stockrecord has never been analyzed — EXPLAIN plans on dev are not representative of PRD
metadata:
  node_type: memory
  type: project
  originSessionId: 3a2d7026-06f3-4515-a6d8-16bea93efd77
  modified: 2026-11-06T16:16:14.790Z
---

As of 2026-11-07, `dev_wh01_om1.stockrecord` (~9.7M rows, PG 16) had no `pg_stats` row for `created`, and `last_analyze`/`last_autoanalyze` were both null (`n_live_tup` 10,772 vs `reltuples` 9.7M). Selective custom plans fall back to a parallel seq scan there, while c1wh PRD (analyzed, PG 14) uses `index_stockrecord_created` for the same query.

**Why:** found during the SBDEV-4002 O-1 plan measurement. A dev EXPLAIN alone would have reported a false perf regression.
**How to apply:** don't judge plan shape or cost from dev EXPLAIN without checking `pg_stats` first. Measure plans on an analyzed PRD DB (read-only MCP: no PREPARE/SET, and no pg_stat_statements on dev or c1wh). `ANALYZE stockrecord` was run on dev on 2026-11-07 with Nam's approval, which fixed it. A dump restore can wipe the stats again. See [[hub-scan-instruments-lie]].
