---
name: wms2-client-without-section-silently-stalls-pickpack
description: "A client with section_id=NULL makes Pick & Pack orders stall at RAW forever with zero signal; most UAT clients are in that state, so random test clients fail"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3a4dfda1-ae96-4231-b8fb-1643f798e979
  modified: 2026-08-14T17:37:50.949Z
---

A v2 Pick & Pack order whose **batch client** has `section_id = NULL` is silently dropped by
`CustomerorderPositionRepository.streamOrderReleaseInfo` (`AND sec.id is not null`, line 88; sibling
`getOrderReleaseInfo` line 62 has it too). It sits at `state = 0` (RAW) **forever** — no error, no state, no log.
Filed 2026-08-14 as **SBDEV-2961** (+ SBDEV-2962 for the pallet-label message); triage report is
`sbdocs/3-Resources/reports/260814-hydra-uat-three-flow-qa-triage.md`.

**Why:** the failure is *doubly* silent, so "no picking orders generated" reads as a broken cron and burns a
whole investigation on the wrong hypothesis. (1) The SQL filters the row out, so `releaseOrder()` is never
reached. (2) `WmsConstants.State.CLIENT_HAS_NO_SECTION = 45` exists but **no code ever writes it** — it is only
ever read (`ReleaseOrderJobService:246`, `:581`, plus `getCodeText`). (3) The unreachable fallback
`BusinessException("Section not configured for order=…")` (`ReleaseOrderJobService:604`) is swallowed by
`OrderReleaseJob:292-295` behind a `showLog` gate, and `CRON_JOB_SHOW_LOG=false` on UAT/prod.

**How to apply:** when a v2 Pick & Pack batch never generates picking orders, check
`client.section_id` for the *batch's* client **before** suspecting cron. On Hydra UAT **118 of 138 clients had
`section_id = NULL`** (only `ZoneA`=59250 with 18 clients and `TestSection`=50800 with 2) — so a randomly
chosen QA client fails ~86% of the time; tell QA to use a section-having client. Prove it with a differential
re-run of the production query, removing only the `sec.id is not null` line.

Backfill is tracked as **SBDEV-2963**; it needs a human to say which section each client belongs to (warehouse
layout, not derivable). Of the 118, only 4 ever had a batch and 1 in 180 days — but **110 have SKUs**, so frame
it as 110 armed landmines, not 118 dead rows. Fix path: Admin → **Shippers** → edit → Section
(`editShipper.vue:38` → `PATCH /client/{id}`), or SQL. **No restart/cache flush needed** — the release query is
native SQL reading `client` directly, so it lands on the next tick; the `clients` Caffeine cache
(`CacheConfig.java:37`) only affects `ClientService` and expires in 5 min. Stuck batches self-heal.

LANDMINE — do **not** conclude "cron is dead" from a stale `pickingorder`/`replenishorder` max(created).
Confirm the scheduler independently: on Hydra UAT `INVENTORY_FULL_EXPORT` rows in `message` proved
`StockSummaryExportJob` ran nightly, and unrelated orders were advancing to state 50, while
`replenishorder` had been untouched since January. Contrast with [[oms-v2-picking-date-utc-future-picking]],
where `app.cron=false` genuinely was the cause.

Club runs are **not** affected — they are operator-driven and never pass through `OrderReleaseJob`, so a CLUB
batch for the same section-less client advances normally. Related: [[wms2-uat-outbound-pallet-label-patterns]].
