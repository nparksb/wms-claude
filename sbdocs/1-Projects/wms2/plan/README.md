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
- [260606-wineco-v1-to-v2-migration-runbook.md](260606-wineco-v1-to-v2-migration-runbook.md) — *WineCo (wsl) v1→v2 UTC migration **run record**; sibling of the Hydra runbook above; procedure lives in the [SOP](../../../2-Areas/wms-utc-timezone-migration/README.md)*
- [260422-v2-testing-migration-rollup.md](260422-v2-testing-migration-rollup.md) — *reviewed 2026-06-22; coordination layer for the 3 testing plans below (start here) — see §9 decisions (D1 PG-lane owner hard-blocks P1 §4)*
- [260420-v2-integration-tests-h2-migration-report.md](260420-v2-integration-tests-h2-migration-report.md) — *reviewed 2026-06-22; approved execution plan*
- [260420-v2-port-plpgsql-functions-to-java.md](260420-v2-port-plpgsql-functions-to-java.md) — *reviewed 2026-06-22; Phase A baseline gate cleared 13/13 (#47 merged)*
- [260421-v2-replace-pg-advisory-lock.md](260421-v2-replace-pg-advisory-lock.md) — *reviewed 2026-06-22; sibling of PL/pgSQL plan — lock confirmed load-bearing (rollup D2)*
- [260520-rest-security-permitall-hardening.md](260520-rest-security-permitall-hardening.md)
- [SBDEV-2238-4.6-oms-sync-reconciliation-job.md](SBDEV-2238-4.6-oms-sync-reconciliation-job.md) — *draft; MEDIUM — daily WMS↔OMS drift-detection job (last SBDEV-2238 sibling). Code prereqs (SBDEV-2221 + 4.1) now merged; still externally blocked on the OMS GET endpoint (stub below) + state-mapping sign-off + SRE alert rule.*
- [SBDEV-2238-4.6-oms-order-state-get-endpoint.md](SBDEV-2238-4.6-oms-order-state-get-endpoint.md) — *draft STUB; MEDIUM — paired OMS prerequisite for 4.6: OMS must expose read-only `GET /api/order/{externalId}` (200+state / 404-unknown) for the reconciliation job to compare against. Not found in oms-laravel-api 2026-06-16.*
- [SBDEV-1921-order-cancellation-reversal-workflow.md](SBDEV-1921-order-cancellation-reversal-workflow.md) — *implemented; WMS Phases 1–4 merged to develop (wms2-api `bf14f6d`, mobile-ui `c7f50bb`). NOT closeable — gated on paired OMS endpoint + per-env sysprop URL (see stub below). Verify script 21/0.*
- [SBDEV-1921-oms-batch-reversal-completed-endpoint.md](SBDEV-1921-oms-batch-reversal-completed-endpoint.md) — *draft STUB; HIGH — paired OMS prerequisite for SBDEV-1921: OMS must add `POST /services/call/batchReversalCompleted` (audit/status only, NO inventory write). Verified absent in oms-laravel-api 2026-06-16. Closes the parent plan once shipped + sysprop URL set per env.*
- [260609-oms-transfer-id-wrong-source-fix.md](260609-oms-transfer-id-wrong-source-fix.md) — *draft; HIGH — OMS-side bug: `BatchProcessingService::getTransferId` sends `transfer_destination` instead of `CLIENT_CODE-ORDER_ID`, so offsite transfers fail WMS `field transfer_id not set` (DB-verified). Fix in oms-laravel-api; pairs with 260424-Transfer_Error_Fix*
- [260610-wms2-sku-trim-normalization.md](260610-wms2-sku-trim-normalization.md) — *implemented 2026-06-11 (ralph: architect APPROVED, reviewer 0-critical); replaces closed wms2-api PR #14 (FreeScout #959 trailing-space duplicate SKUs); Phase 1+1b code trim on PR [#44](https://github.com/SiteBossInc/wms2-api/pull/44) awaiting merge (verify script 7/7, targeted suites 60/60); Phase 2 per-tenant cleanup via new runbook [wms2-sku-trim-data-cleanup](../../../2-Areas/runbooks/wms2-sku-trim-data-cleanup.md) — hydra `BONMFPN23` pair must be resolved before that tenant's deploy (Phase 1b sequencing). Archive after merge + Phase 2 execution.*

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
