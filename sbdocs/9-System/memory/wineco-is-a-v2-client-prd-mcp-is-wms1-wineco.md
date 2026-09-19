---
name: wineco-is-a-v2-client-prd-mcp-is-wms1-wineco
description: "WineCo environment map: which MCP handle is which version and env, and why the handle names mislead"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 411e9e67-30d3-4d8d-9429-961ab41472f2
  modified: 2026-08-27T18:08:52.899Z
---

**Nam, 2026-08-27: WineCo is a v2 client.** The MCP handle names do not track version, so resolve by
port + database, never by the name.

| handle | host:port | database | schema | notes |
|---|---|---|---|---|
| `wms1-wineco` | :25061 (**PRD**) | `wh01_om1` | **v1** | Nam: "wms1-wineco is db MCP for WineCo's PRD" |
| `wms1-wineco-dev` | :25060 (dev) | `wh01_om1` | v1 | |
| `wms2-wineco-dev` | :25060 (dev) | `dev_wh01_om1` | v2 | see [[wineco-dev-db-is-dev-wh01-om1-not-the-migration-env-target]] |
| `wsl-wineco-uat` | :25062 (UAT) | `wh01_om1_v2` | **v2** | where WineCo's v2 acceptance testing happens (`winecov2tests` tag) |

**There is no `wms2-wineco` MCP configured**, and on the PRD host `pg_database` lists `wh01_om1`,
`wh01_hydra_v2`, `wh01_shipitez`, `wh02_*` — but **no `wh01_om1_v2`**. So from this machine the only
WineCo v2 database reachable is the **UAT** one. If a "v2 prod" WineCo DB is needed, the handle has to be
added.

🔴 **HYDRA IS THE ONLY CLIENT ON v2 PRODUCTION (Nam, 2026-08-31). WineCo has NO v2 prod instance yet.**
Its v2 footprint is dev + UAT only; `wms1-wineco` at :25061 is WineCo's **v1** production and the v2
authorization programme does not exist there at all (no `FunctionGuardInterceptor`, no
`@RequiresFunction` — v1 has no function-gating mechanism).

⚠️ **How this bit me, 2026-08-31 on SBDEV-3142.** I surveyed six tenant DBs for a `WEB_UI_VIEW_*`
constant, found `wms1-wineco` missing it, and escalated it as *"WineCo PRODUCTION breaks — 93 users
denied, blocks release"*, including a comment on SBDEV-3017 claiming an already-merged gate was a
latent prd break. **All of it was wrong**: that is a v1 DB, where no v2 gate is ever evaluated. This
memory already said `schema = v1` in its own table and already carried the detection query below — I
read the word "PRD" and skipped both. Withdrawn and corrected on both tickets.

**The rule that would have caught it:** when reasoning about a v2 feature, the population is the set of
**v2** tenants. Today on production that is **Hydra alone** (`wh01_hydra_v2`, Flyway V2.2.21, 82
functions, 9 users). Counting "six DBs surveyed" or "93 users affected" is worthless if the DBs are the
wrong version — check the schema, not the handle, and not the environment label.

**How to tell v1 from v2 schema in one query** (do this instead of trusting a handle name):

```sql
select (select count(*) from information_schema.tables where table_name='flyway_schema_history') as has_flyway,
       (select data_type from information_schema.columns
          where table_name='location' and column_name='created') as location_created_type,
       (select count(*) from information_schema.columns
          where table_name='replenishorder' and column_name in ('moved_amount','moved_destination_location_name')) as v2_cols;
```
v1 → `0`, `timestamp without time zone`, `0`. v2 → `1`, `timestamp with time zone`, `2`.

**PRD is live and changes under you.** During one session a `PICK_PACK` position on `wh01_om1` moved into
`RAW_ON_HOLD_NO_FIXED_ASSIGNED_LOCATION` (56) between two queries ~30 min apart, which silently invalidated
a "there are zero held positions on prd" conclusion. Re-measure before restating a point-in-time count as a
finding, and say when it was measured.

Related: [[wineco-wsl-v1-v2-migration-status]], [[wms-v1-vs-v2-dev-api-hostnames]],
[[wms-mcp-tools-not-surfaced-use-psql-direct]]
