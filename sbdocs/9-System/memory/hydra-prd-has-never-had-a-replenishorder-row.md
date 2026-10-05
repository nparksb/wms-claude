---
name: hydra-prd-has-never-had-a-replenishorder-row
description: "SUPERSEDED 2026-09-29: Hydra prd now HAS replenishorders (2, both PROCESSABLE), and v2 prd also runs WineCo + ShipItEZ with thousands; re-query before claiming zero prd exposure"
metadata: 
  node_type: memory
  type: project
  originSessionId: 9d52a4a0-a665-4761-910e-aecb134394a3
  modified: 2026-09-09T18:20:46.621Z
---

⚠ **UPDATE 2026-09-29 (SBDEV-3561), which overrides the zero below:** `nywh-hydra-prd` now has `300=2`. v2 PRD is also
**not** Hydra-only: `wsl-wineco-prd` 300=563/700=864/800=60916, `c1wh-shipitez-prd` 300=103/700=4263/800=1125,
`nywh-shipitez-prd` 800=34. So replenishment defects **do** have live v2 prd exposure. The rest of this file is history.

Measured 2026-09-09 on `wms2-hydra` (prd): `replenishorder` has **never held a row** —
`count(*) = 0` and `max(version) = -1`. So `findByStateAndItemdataId` / `findByState` return empty,
the recalculation loop body never executes, and replenishment-recalc defects cannot fire in
production today.

Positive control for that zero (a zero-scan is worthless without one): same DB, same query session —
556 `stockunit` rows, 475 with `version > 0`, 2238 `stockrecord` rows with the latest written that
same day, 132 **active** `fix_location_assignment` rows, 327 stockunits with `entity_lock <> 0`. The
database is live and the replenishment *configuration* exists; only the orders are absent.

**Why:** it separates two axes that get conflated on replenishment tickets — execution risk (real)
from live business impact (currently nil). Do not downgrade a fix's tier on this, but do question a
`high` priority, and do not claim production breakage you cannot evidence.

**How to apply:** the second concurrent actor is already live —
`REPLENISHMENT_TIMER_ACTIVATED = true` with `REPLENISHMENT_TIMER_HOUR = *` /
`REPLENISHMENT_TIMER_MINUTE = *`, and `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` resolved to 13
seconds before the query. So exposure appears the moment the first `PROCESSABLE` order exists; this
is a latent, not a theoretical, defect class. For a population that actually exercises the versioned
update path, use Hydra **UAT** (`nywh-hydra-uat`): **124** replenishorders, **121** with `version > 0`,
`max(version) = 27`, of which only **8** are `PROCESSABLE` (8 distinct `stockunit_id`s), 147 active
FLAs, 23663 stockunits. `max(created)` there is 2026-07-01, so those figures are static.

Open question nobody has answered: 132 active FLAs plus a per-minute cron have produced **zero**
replenishorders on prd. That is either a config reality (Hydra does not use replenishment) or a
separate silent defect — worth asking before assuming the former.

⚠ **`WmsConstants.State.PROCESSABLE = 300`, not 100** (`service/WmsConstants.java:53`; the distinct
states actually present on UAT are 300/700/800). A `WHERE state = 100` filter returns 0 on a fully
populated table and reads exactly like a true zero — it cost me a wrong figure on SBDEV-3244, caught
only when an independent lane re-ran the query. Note also `los_sysprop` columns are
`syskey`/`sysvalue`, not `name`/`value`, and `stockunit` uses `entity_lock`, not `entitylock`.
Related: [[wineco-is-a-v2-client-prd-mcp-is-wms1-wineco]], [[hmg-is-hydra-nywh-warehouse]].
