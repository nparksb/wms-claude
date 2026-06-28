---
title: "WMS v1 — Active Plans"
type: index
status: active
version: v1
scope: wms1-planning
updated: 2026-05-10
tags: [moc, index, wms1]
---

# WMS v1 — Active Plans

Active fix plans, feature plans, and debug plans for the **legacy WMS v1 stack** (`v1/wms-api` — Java 8 / Spring Boot 2.3.7 / PostgreSQL). Completed plans live in [../../../4-Archieves/wms1/plan/](../../../4-Archieves/wms1/plan/).

See also: [vault index](../../../INDEX.md) · [plan template](../../../9-System/templates/wms-plan-template.md) · [v1 → v2 sync workflow](../../../2-Areas/wms-v1-v2-sync/README.md)

---

## Current plans (filesystem snapshot)

- [260626-restore-replenishment-triggers-on-lock-state-changes.md](260626-restore-replenishment-triggers-on-lock-state-changes.md) — SBDEV-2033 follow-up (answers Brent's "did these triggers have a good reason?"): SBDEV-2033 over-removed — it stripped all 5 `triggerReplenishmentMaintenance()` call sites when only `transferStock` + `adjustReservedAmount` were the re-reservation bug. Selectively restores the 3 legitimate lock-state triggers (`setLockOnHold` L331, `setLockDamaged` L389, `removeLock` L500) so replenishment stops pointing picks at just-damaged/held stock (≤60s stale-source window, unbounded on cron-off dev); keeps the 2 buggy sites OFF; `adjustAmount` deferred. Safe because `isSourceUsable` excludes the relocated/locked UL (location not `useforreplenish`). Cron-enabled is a BLOCKING per-env prereq. Architect-verified against code. develop→release. v1-only; paired v2 port gated on SBDEV-2217
- [SBDEV-2486-club-lane-blank-screen-split-adjust.md](SBDEV-2486-club-lane-blank-screen-split-adjust.md) — URGENT: club-fulfillment lane screen renders blank after a unit-load split + qty adjust + refresh. Two-layer defense-in-depth (v1 only): backend hardens unguarded null derefs in `CustomerorderBatchService` (B1 `getClubLineSKUOverview`, B2 `calc()` reference-equality wrong-sums **+** null amount [HIGH], B3 client, B4 SKU filter) so failures become structured 422/404 not raw 500; frontend (`clubRuns.js`, `clubRunDetails.vue`, tab tables) resets the stuck loading flag, self-heals null `clubRunDetails` on refresh (rejection-safe), guards non-array computeds. B5 dead-code / B6 DB-disproven / B7 already-guarded excluded. `db_verified:false` (UAT unreachable — manual pre-work in §1). Paired v2 port pending
- [260624-stock-unit-history-on-unitload-relocation.md](260624-stock-unit-history-on-unitload-relocation.md) — operator whole-UL relocations (Move Fixed Location + Move Stock whole-UL) write only a `UnitloadRecord`, never a `Stockrecord`, so they're invisible in stock-unit history. Adds `STOCK_RELOCATED` + `StockrecordService.recordRelocation` called from the two operator paths (Option A; `processTransfer` untouched, scope-guarded). Reports unaffected via the `(activitycode,type)` allow-list + `amount=ZERO`. Surfaced in SBDEV-2481 UAT; pre-existing (not a regression). Paired v2 port pending
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
- [SBDEV-2116-unguarded-optional-get-fix-plan.md](SBDEV-2116-unguarded-optional-get-fix-plan.md)
- [SBDEV-2163-prevent-finished-club-batch-lane-reassignment.md](SBDEV-2163-prevent-finished-club-batch-lane-reassignment.md) — guard in `CustomerorderBatchService.assignStagingLaneToOrderBatch` blocks lane assignment when all child orders are FINISHED (700) or CANCELED (800); uses order state as source of truth per ticket spec
- [SBDEV-2164-stale-club-batch-cleanup-cron.md](SBDEV-2164-stale-club-batch-cleanup-cron.md)
- [SBDEV-2384-replenishment-monitor-pickpack-classification-fix.md](SBDEV-2384-replenishment-monitor-pickpack-classification-fix.md) — Replenishment Monitor classifies replenishable stock by a hardcoded area-NAME list (includes pick-only `Storage and Picking`); fix to classify by the `location_area.useforreplenish` flag across the native query, the deployed DB view, and the commented DDL
- [SBDEV-2481-stale-pick-line-realignment-on-stock-move.md](SBDEV-2481-stale-pick-line-realignment-on-stock-move.md) — URGENT regression: pick lines (`PickingorderPosition` string refs) go stale when stock/UL moves; SBDEV-1526's realign is a no-op (broken finder at `FixLocationAssignmentService:126` + broken detector SQL). Adds an activityCode-scoped guard at the 2 move choke points — realign not-started picks, block active (`Pickingorder.state>=500`), pass-through outbound/split; acyclic repos-only `PickLineRealignmentService`. Phased P0→P5. db_verified (37 stale rows). v2 pairing pending

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
