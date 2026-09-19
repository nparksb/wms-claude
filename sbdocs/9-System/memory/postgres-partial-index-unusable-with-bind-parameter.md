---
name: postgres-partial-index-unusable-with-bind-parameter
description: "A Postgres partial index (WHERE state < 700) is unusable when the query says `state < :param` under a GENERIC plan — predicate implication is unprovable, so the optimisation silently evaporates in production"
metadata:
  node_type: memory
  type: project
---

**A partial index is used only when the planner can prove the query predicate implies the index
predicate.** With a literal it can (`state < 700 ⇒ state < 700`); with a **bind parameter** it cannot
(`state < $1 ⇒ state < 700`). So an index like

```sql
CREATE UNIQUE INDEX idx_replenishorder_active_item_dest
  ON replenishorder (itemdata_id, destination_id) WHERE (state < 700);
```

is available under a **custom** plan and **gone** under a **generic** one — the plan silently falls back to a
full index + `Filter`. Measured on SBDEV-3153, `dev_wh01_om1`: 28,110 buffers custom vs **338,404** generic for
the identical SQL. A 12× difference decided entirely by plan mode.

**Why this bites in wms2-api specifically:** `plan_cache_mode` is `auto` (default — 5 custom plans, then
Postgres may switch to generic), **no `prepareThreshold` is set anywhere in `src/main`** so pgjdbc's default
of 5 applies and the statement becomes a server-side prepared statement after 5 executions on a connection,
and `TenantDynamicRoutingDataSource` sets `maxLifetime` 30 min so a cron connection easily reaches that.

⚠️ **`TenantDynamicRoutingDataSource` sets `cachePrepStmts` / `prepStmtCacheSize` /
`prepStmtCacheSqlLimit` — those are MySQL Connector/J names.** pgjdbc ignores all three, so there is no
statement-cache tuning in effect at all. Pre-existing; noted on SBDEV-3153.

**So: never quote a partial-index speedup without saying which plan mode produced it,** and measure both with
`SET LOCAL plan_cache_mode = force_custom_plan | force_generic_plan`. The fix, where it matters, is to pin the
literal — but check first whether the parameter is part of an **SDR-exported** signature, because dropping it
is then a contract change. Related: [[sbdev-3153-refill-or-split]].
