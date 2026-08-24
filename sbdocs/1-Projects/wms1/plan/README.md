---
title: "WMS v1 — Active Plans"
type: index
status: active
version: v1
scope: wms1-planning
updated: 2026-08-20
tags: [moc, index, wms1]
---

# WMS v1 — Active Plans

Active fix plans, feature plans, and debug plans for the **legacy WMS v1 stack** (`v1/wms-api` — Java 8 / Spring Boot 2.3.7 / PostgreSQL). Completed plans live in [../../../4-Archieves/wms1/plan/](../../../4-Archieves/wms1/plan/).

See also: [vault index](../../../INDEX.md) · [plan template](../../../9-System/templates/wms-plan-template.md) · [v1 → v2 sync workflow](../../../2-Areas/wms-v1-v2-sync/README.md)

---

## Current plans (filesystem snapshot)

- [SBDEV-2485-club-split-unitload-reprint-label.md](SBDEV-2485-club-split-unitload-reprint-label.md) — **draft**; HIGH (urgent). Club staging-lane view hides the print/reprint label button for **split-created** unit loads. Root cause: `printable` is computed from `goodsreceiptposition` membership (receiving-only) via `findPrintableUnitLoadIds`, set in `CustomerorderBatchService.buildDtoList:1034`; split ULs (`createUnitload` w/ `CODE_MANUAL_SPLIT`) have no goodsreceiptposition row → `printable=false` → button hidden, even though `UnitloadService.reprintLabel` Path-2 already prints them. Fix (requester-approved + architect-refined): `printable = entry.getValue() > 0 && entityLock==NOT_LOCKED` (null-safe; has remaining stock AND active so it matches reprintLabel's precondition — else the button 500s on locked ULs) and delete the dead query — API-only, no UI change. v2 UAT twin DB shows 97.9% of stock-bearing ULs wrongly `printable=false`. Pairs [[../../wms2/plan/SBDEV-2485-club-split-unitload-reprint-label|v2]]
- [260710-location-import-stale-rack-reference-optimistic-lock.md](260710-location-import-stale-rack-reference-optimistic-lock.md) — draft STUB; v1 pair of the archived v2 plan (wms2-api PR #64 merged 2026-07-10): identical latent bugs in v1 FileImportController (un-refreshed else-branch rack re-save `:239-243`, rackRowMap wrong GET key `:200`, copy-paste log strings). Open question: does Hibernate 5 exhibit the dirty-merge driver? Settle via version-invariance test before prioritizing; fixes apply defensively regardless
- [260701-wineco-replenishment-job-index-and-cadence.md](260701-wineco-replenishment-job-index-and-cadence.md) — WineCo `app.cron=true` replenishment job is slowest across tenants: `replenishorder` (61k rows, 99% terminal) has no `state` index, so ~6 phases of `ReplenishOrderJob.doCalculation` full-seq-scan every minute. Fix A: Flyway `V1.26.31` partial index `idx_replenishorder_open_state (state) WHERE state<700` (subsumes the proposed narrow `destination_id IS NULL` index; serves state=300/≤300/<500); plain `CREATE INDEX IF NOT EXISTS` + DBA out-of-band `CONCURRENTLY` (Flyway 6.4 has no per-script executeInTransaction). Fix B: cron `recalculateOpenOrders(true)→(false)` to honor the cadence throttle — inert until `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS>0` (default `"0"`), so zero-regression. Mobile L789 stays `true`. db_verified (live wms1-wineco). Autovacuum/bloat remediation is a separate DBA action (report §8). Paired v2 eval pending
- [260504-transfer-order-null-transferlane-crash.md](260504-transfer-order-null-transferlane-crash.md)
- [260429-replenish-unit-load-stale-cache.md](260429-replenish-unit-load-stale-cache.md)
- [260427-changeReservedAmount-caller-rebind-followup.md](260427-changeReservedAmount-caller-rebind-followup.md) — production replenish broken since `v1.26.29`: 2 BUG + 1 LATENT call sites of `changeReservedAmount` after the `2351004` detach-before-lock fix; rebind `sourceStock` in `MobileReplenishService.finishReplenishmentOrderInternal` (L420/L424) and `stockUnit` in `ReleaseOrderJobService.createPickingForOrder` (L473)
- [260427-putaway-new-sku-no-location-guidance.md](260427-putaway-new-sku-no-location-guidance.md)
- [260427-putaway-unitloadlist-undefined-crash.md](260427-putaway-unitloadlist-undefined-crash.md) — mobile putaway crash: stale `currentIndex` across sessions + unguarded `unitLoadList` template access in `scanFlowBin.vue` and `storeBox.vue`
- [260427-uniform-transactional-strategy.md](260427-uniform-transactional-strategy.md) — 4-stage refactor to eliminate mixed `@Transactional` strategy: fix `rollbackFor` gaps, annotate phantom-TX services, convert class-level to method-level, disable OSIV
- [260424-oms-notification-rollback-risk-remediation.md](260424-oms-notification-rollback-risk-remediation.md)
- [260424-runClubLine-transaction-boundary-hardening.md](260424-runClubLine-transaction-boundary-hardening.md)
- [260422-changeReservedAmount-stale-object-state-fix.md](260422-changeReservedAmount-stale-object-state-fix.md)
- [260422-mobile-picking-stale-tote-clear-loses-pickingtoteid.md](260422-mobile-picking-stale-tote-clear-loses-pickingtoteid.md)
- [260416-move-stock-location-with-stock-shows-na.md](260416-move-stock-location-with-stock-shows-na.md)
- [SBDEV-1699-replenish-qty-requested-wrong-upperbound.md](SBDEV-1699-replenish-qty-requested-wrong-upperbound.md)
- [SBDEV-2095-large-bol-close-decoupling-and-perf.md](SBDEV-2095-large-bol-close-decoupling-and-perf.md) — large-BOL `closeBOL` perf (bulk batch finalize w/ NOT EXISTS, IN-clause chunking, bulk carrier unlink) + `bolToClose` leak/race fix; OMS-decoupling at the same site is owned by `260424-oms-notification-rollback-risk-remediation` S3 (this plan ships as Plan A rollout item 12)
- [SBDEV-2096-configurable-pick-path-direction.md](SBDEV-2096-configurable-pick-path-direction.md)
- [SBDEV-2099-outbound-parcel-report-clears-after-palletize.md](SBDEV-2099-outbound-parcel-report-clears-after-palletize.md)
- [SBDEV-2163-prevent-finished-club-batch-lane-reassignment.md](SBDEV-2163-prevent-finished-club-batch-lane-reassignment.md) — guard in `CustomerorderBatchService.assignStagingLaneToOrderBatch` blocks lane assignment when all child orders are FINISHED (700) or CANCELED (800); uses order state as source of truth per ticket spec
- [SBDEV-2164-stale-club-batch-cleanup-cron.md](SBDEV-2164-stale-club-batch-cleanup-cron.md)
- [260709-multi-unitload-replen-reserve-availability-guard.md](260709-multi-unitload-replen-reserve-availability-guard.md) — *implemented & TDD-gated 2026-07-09 on `fix/260709-multi-unitload-replen-availability` (off `develop`), but **uncommitted / no PR yet** — awaiting go-ahead (excluded from the 2026-07-15 archive sweep for lack of a merged PR). Adds a reserve-vs-available guard on multi-unit-load replenish.*
- [SBDEV-2610-move-unitload-false-reserved-block.md](SBDEV-2610-move-unitload-false-reserved-block.md) — **draft** (ST#1047, WineCo), diagnosis corrected after critic+architect. Move Unit Load blocked while UI shows 0 reserved-out. Real cause (DB-proven): SBDEV-2492 in-progress-replen block `ReplenishmentOrderSourceSyncService:59` (via `UnitloadBusinessService:247`), NOT `checkReservedStock` (reserved was 0 for 2m34s before the move). Part 1 = clarify block + surface replen state (mobile UI); Part 2 (splittable) = `checkReservedStock` honesty + Flyway **V1.26.32** callback reconciling 17 orphaned rows. Dropped: replen release-target rework (split doesn't carry reservation; orphan origin is picking). 🚦 blocking gate: confirm prod SHA + exact operator message. v2 pair flagged.

> This list can drift. The Dataview section below is always authoritative in Obsidian; elsewhere run `ls sbdocs/1-Projects/wms1/plan/*.md`.

---

## Dataview — by priority

```dataview
TABLE
  ticket AS "Ticket",
  priority AS "Priority",
  status AS "Status",
  scope AS "Scope",
  updated AS "Updated",
  owner AS "Owner"
FROM "1-Projects/wms1/plan"
WHERE type != "index"
SORT priority ASC, updated DESC
```

## Dataview — needs attention (no priority or no update in 14d)

```dataview
TABLE status AS "Status", updated AS "Updated", scope AS "Scope"
FROM "1-Projects/wms1/plan"
WHERE type != "index" AND (!priority OR !updated OR (date(today) - date(updated)) > dur(14 days))
SORT updated ASC
```

## Dataview — by scope

```dataview
TABLE rows.file.link AS "Plan", rows.status AS "Status"
FROM "1-Projects/wms1/plan"
WHERE type != "index"
GROUP BY scope
```

---

## Conventions specific to v1 plans

- **Ticket prefix** `SBDEV-####` in filename when tracked in the SBDEV issue system; free-form otherwise.
- **`version: v1`** is required so cross-version queries can filter cleanly.
- A v1 plan that ports to v2 links to its v2 counterpart via `related:` — the v1 → v2 sync skill uses this to avoid re-porting.
- When complete, **move** (do not copy) the file to `../../../4-Archieves/wms1/plan/` and set `status: archived`.
