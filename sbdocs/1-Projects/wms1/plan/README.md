---
title: "WMS v1 — Active Plans"
type: index
status: active
version: v1
scope: wms1-planning
updated: 2026-04-27
tags: [moc, index, wms1]
---

# WMS v1 — Active Plans

Active fix plans, feature plans, and debug plans for the **legacy WMS v1 stack** (`v1/wms-api` — Java 8 / Spring Boot 2.3.7 / PostgreSQL). Completed plans live in [../../../4-Archieves/wms1/plan/](../../../4-Archieves/wms1/plan/).

See also: [vault index](../../../INDEX.md) · [plan template](../../../9-System/templates/wms-plan-template.md) · [v1 → v2 sync workflow](../../../2-Areas/wms-v1-v2-sync/README.md)

---

## Current plans (filesystem snapshot)

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
- [SBDEV-2116-unguarded-optional-get-fix-plan.md](SBDEV-2116-unguarded-optional-get-fix-plan.md)
- [SBDEV-2163-prevent-finished-club-batch-lane-reassignment.md](SBDEV-2163-prevent-finished-club-batch-lane-reassignment.md) — guard in `CustomerorderBatchService.assignStagingLaneToOrderBatch` blocks lane assignment when all child orders are FINISHED (700) or CANCELED (800); uses order state as source of truth per ticket spec
- [SBDEV-2164-stale-club-batch-cleanup-cron.md](SBDEV-2164-stale-club-batch-cleanup-cron.md)

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
