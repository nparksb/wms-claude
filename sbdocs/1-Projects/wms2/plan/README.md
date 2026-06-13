---
title: "WMS v2 — Active Plans"
type: index
status: active
version: v2
scope: wms2-planning
updated: 2026-05-31
tags: [moc, index, wms2]
---

# WMS v2 — Active Plans

Active fix plans, feature plans, and debug plans for the **modern WMS v2 stack** (`v2/wms2-api` — Java 21 / Spring Boot 3.5.9 / PostgreSQL). Completed plans live in [../../../4-Archieves/wms2/plan/](../../../4-Archieves/wms2/plan/).

See also: [vault index](../../../INDEX.md) · [plan template](../../../9-System/templates/wms-plan-template.md) · [v1 → v2 sync workflow](../../../2-Areas/wms-v1-v2-sync/README.md)

---

## Current plans (filesystem snapshot)

- [260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md](260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md)
- [260523-UTC-TIMEZONE-MIGRATION.md](260523-UTC-TIMEZONE-MIGRATION.md)
- [260527-hydra-v1-to-v2-migration-runbook.md](260527-hydra-v1-to-v2-migration-runbook.md) — *Hydra (wh01, NY) UTC migration **run record**; procedure lives in the [SOP](../../../2-Areas/wms-utc-timezone-migration/README.md). A→C→F rehearsed on dev 2026-06-05; G–K pending*
- [260422-v2-testing-migration-rollup.md](260422-v2-testing-migration-rollup.md) — *draft; coordination layer for the 3 testing plans below (start here)*
- [260420-v2-integration-tests-h2-migration-report.md](260420-v2-integration-tests-h2-migration-report.md) — *draft; pending review*
- [260420-v2-port-plpgsql-functions-to-java.md](260420-v2-port-plpgsql-functions-to-java.md) — *draft; pending review*
- [260421-v2-replace-pg-advisory-lock.md](260421-v2-replace-pg-advisory-lock.md) — *draft; pending review — sibling of PL/pgSQL plan*
- [260520-rest-security-permitall-hardening.md](260520-rest-security-permitall-hardening.md)
- [SBDEV-2238-4.6-oms-sync-reconciliation-job.md](SBDEV-2238-4.6-oms-sync-reconciliation-job.md)
- [SBDEV-1921-order-cancellation-reversal-workflow.md](SBDEV-1921-order-cancellation-reversal-workflow.md) — *Order Cancellation & Reversal feature workflow*
- [SBDEV-2381-wms-parcel-status-out-of-order.md](SBDEV-2381-wms-parcel-status-out-of-order.md) — *CRITICAL; planned — outbox dispatch reorders PICKING_STARTED/FINISHED to OMS (43% inversion, DB-verified); id-ordering + fail-closed cross-tick gate + club dual-transport unify*
- [260609-oms-transfer-id-wrong-source-fix.md](260609-oms-transfer-id-wrong-source-fix.md) — *draft; HIGH — OMS-side bug: `BatchProcessingService::getTransferId` sends `transfer_destination` instead of `CLIENT_CODE-ORDER_ID`, so offsite transfers fail WMS `field transfer_id not set` (DB-verified). Fix in oms-laravel-api; pairs with 260424-Transfer_Error_Fix*
- [260610-wms2-multi-replica-hardening.md](260610-wms2-multi-replica-hardening.md) — *implemented 2026-06-10; all 3 phases on feature branches awaiting merge: A inert OptimisticLockRetry removal (PR #40), B JWT-decoder Caffeine 24h TTL (PR #41), C HTTP-in-tx ArchUnit guard (PR #42); verify script 20/20 once merged to develop. Archive after merges.*
- [260610-wms2-sku-trim-normalization.md](260610-wms2-sku-trim-normalization.md) — *implemented 2026-06-11 (ralph: architect APPROVED, reviewer 0-critical); replaces closed wms2-api PR #14 (FreeScout #959 trailing-space duplicate SKUs); Phase 1+1b code trim on PR [#44](https://github.com/SiteBossInc/wms2-api/pull/44) awaiting merge (verify script 7/7, targeted suites 60/60); Phase 2 per-tenant cleanup via new runbook [wms2-sku-trim-data-cleanup](../../../2-Areas/runbooks/wms2-sku-trim-data-cleanup.md) — hydra `BONMFPN23` pair must be resolved before that tenant's deploy (Phase 1b sequencing). Archive after merge + Phase 2 execution.*
- [260610-excel-export-localdatetime-unsupported-type.md](260610-excel-export-localdatetime-unsupported-type.md) — *draft (ralplan-approved: Architect SOUND-WITH-CHANGES ×2, Critic ITERATE→APPROVE); HIGH — six Excel exports 500 (Stock Unit Record, Container Record, Inbound Notice, Inbound BOL detailed, 2× Cycle Count): FileExportService throws UnsupportedOperationException on LocalDateTime/LocalDate cells (regression 6e5af846); DB-verified on wineco-dev2; Fix A setCellValue helper + java.time branches (Phase 1 no-conversion; Phase 2 UTC→warehouse-tz blocked on feature/utc-timezone merge) + Fix C catch(Exception) controller hardening + Fix B exporContainerRecord rename (lands last); conflict-free vs feature/utc-timezone; **implemented 2026-06-10**, verify script 24/0/0 (baseline was 5/19/0), PR [#43](https://github.com/SiteBossInc/wms2-api/pull/43) awaiting merge; Phase 2 (UTC→warehouse tz) follow-up blocked on feature/utc-timezone merge*

> This list can drift. The Dataview section below is always authoritative in Obsidian; elsewhere run `ls sbdocs/1-Projects/wms2/plan/*.md`.

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
FROM "1-Projects/wms2/plan"
WHERE type != "index"
SORT priority ASC, updated DESC
```

## Dataview — ported from v1

```dataview
TABLE related AS "v1 origin", updated AS "Updated", status AS "Status"
FROM "1-Projects/wms2/plan"
WHERE type != "index" AND related AND any(related, (r) => contains(string(r), "wms1"))
SORT updated DESC
```

## Dataview — by scope

```dataview
TABLE rows.file.link AS "Plan", rows.status AS "Status"
FROM "1-Projects/wms2/plan"
WHERE type != "index"
GROUP BY scope
```

---

## Conventions specific to v2 plans

- **`version: v2`** is required.
- Plans ported from v1 include a `related:` entry pointing at the v1 plan (either active at `../../wms1/plan/...` or archived at `../../../4-Archieves/wms1/plan/...`).
- Architectural divergence from v1 (Java 8→21, Jakarta namespace, `tenantTransactionManager`, extracted services) means **do not cherry-pick** v1 commits. Port via the `wms-v2-migrate` skill and write the plan here.
- When complete, **move** (do not copy) the file to `../../../4-Archieves/wms2/plan/` and set `status: archived`.
