---
name: wms2-cutover-leaves-new-cron-job-activated-false
description: "Searchable-but-not-pickable orders stuck at state 0 (RAW) => check los_sysprop NEW_CRON_JOB_ACTIVATED first; a v2 tenant cutover can leave it 'false'"
metadata: 
  node_type: memory
  type: project
  originSessionId: 1e8df5e9-e2a3-4c4e-8151-3e66d979c8e6
  modified: 2026-09-09T20:04:55.210Z
---

**SBDEV-3288 (2026-09-09, ShipItEZ C1WH UAT `wh01_shipitez_v2`):** orders searchable in WMS but never
Ready for Picking, sitting at `customerorder.state = 0` (RAW). Cause was **`los_sysprop
NEW_CRON_JOB_ACTIVATED = 'false'`** — not a code defect.

**Why:** `NEW_CRON_JOB_ACTIVATED` is the master gate for **six** jobs (`OrderReleaseJob`,
`ReplenishOrderJob`, `StockSummaryExportJob`, `CleanUpOldMessagesJob`,
`ReleaseExpiredPickingOrdersFromUserJob`, `StaleClubBatchCleanupJob`). Each ANDs it with its own
`*_ACTIVATED` flag, so `ORDER_TIMER_ACTIVATED = 'true'` alone looks correct and proves nothing. The
skip logs only at INFO (`"{} not activated for {} - {}"`) and increments `tenantSkippedNotActivated`,
which nothing scrapes — see [[wms2-metrics-exist-but-nothing-scrapes-them]]. So the failure is
**silent until a client reports it**.

Nam confirmed the DB was **refreshed from production v1 and migrated to v2 that same day**. The
in-repo seed is `'true'` in BOTH `V2.2.00__base_v2_schema.sql` and the v1→v2 onboarding
`V1.0.04__wms_init_data.sql` — the `false` came from **out-of-repo cutover tooling**. Its
`los_sysprop.modified` was byte-identical across 19 rows (the same write that repointed every
`WEBSERVICE_*` URL to the UAT host), which is how you tell a provisioning script from a human toggle.

**How to apply:**
1. Orders stuck at state 0 (RAW) or state 80 (FUTURE_PICKING_DATE) past their picking date →
   `SELECT syskey, sysvalue, modified, version FROM los_sysprop WHERE syskey LIKE '%CRON%' OR syskey LIKE '%TIMER_ACTIVATED%';`
   **before** reading any Java.
2. Sweep the sibling tenants — a per-tenant value is only meaningful against the others. All six other
   reachable v2 DBs were `'true'`; the outlier IS the finding.
3. **Instrument for "has the v2 app ever run here":** count sub-millisecond `created` precision.
   v1 (Java 8) writes ms; v2 (Hibernate/Java 21) writes µs. `0 of 87,613 pickingorder` rows had µs
   precision = the release job had never run once since cutover. Clean, cheap, no logs needed.
4. Fix is a one-row `UPDATE`; `OrderReleaseJob` reads sysprops at **fire time** per tenant
   (SBDEV-3198), so **no restart** — it took effect on the next tick, 23s later.
5. Flipping it starts all six jobs at once, incl. `StockSummaryExportJob` POSTing to OMS. Say so
   before flipping.

Add the cron-gate check to the v1→v2 cutover checklist. Related:
[[wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway]], [[shipitez-two-warehouse-v2-migration]].

**Auditing the rest of a freshly-cut-over tenant** (done on SBDEV-3288, found 1 real break + 4 to decide):
- Missing keys: extract the 144 key literals from `WmsConstants.java`
  (`grep -oP 'SYSTEM_PROPERTY_\w+_KEY\s*=\s*"\K[^"]+'`) and `NOT IN (SELECT syskey FROM los_sysprop)`.
  15 came back — **all benign**, they read through `getIntValue(key, default)`. Run the same query on a
  sibling tenant as the control: identical 15, so it is fleet-normal, not drift.
- **`version = 0` + a `created` inside the cutover window = the app seeded a CODE DEFAULT** because the
  v1 DB had no such row. Those are the suspects. `version >= 1` with an old `created` = a genuine v1
  production value; leave it alone.
- A cutover script rewrites many rows with a **byte-identical `modified`** — that timestamp is how you
  separate a provisioning run from a human toggle, and how you date the cutover.
- Don't assume the fleet has a right answer: on all four SBDEV-3288 disagreements Hydra ran one way and
  WineCo the other. The reportable fact was "the SAME CLIENT's two warehouses now disagree", not "C1WH
  is wrong".

