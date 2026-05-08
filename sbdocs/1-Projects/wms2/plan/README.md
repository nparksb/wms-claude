---
title: "WMS v2 — Active Plans"
type: index
status: active
version: v2
scope: wms2-planning
updated: 2026-04-19
tags: [moc, index, wms2]
---

# WMS v2 — Active Plans

Active fix plans, feature plans, and debug plans for the **modern WMS v2 stack** (`v2/wms2-api` — Java 21 / Spring Boot 3.5.9 / PostgreSQL). Completed plans live in [../../../4-Archieves/wms2/plan/](../../../4-Archieves/wms2/plan/).

See also: [vault index](../../../INDEX.md) · [plan template](../../../9-System/templates/wms-plan-template.md) · [v1 → v2 sync workflow](../../../2-Areas/wms-v1-v2-sync/README.md)

---

## Current plans (filesystem snapshot)

- [260320-Auto_Release_Club_Transfer_Lane_Fix.md](260320-Auto_Release_Club_Transfer_Lane_Fix.md)
- [260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md](260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md)
- [SBDEV-2096-configurable-pick-path-direction.md](SBDEV-2096-configurable-pick-path-direction.md)
- [SBDEV-2099-outbound-parcel-report-clears-after-palletize.md](SBDEV-2099-outbound-parcel-report-clears-after-palletize.md)
- [SBDEV-2102-putaway-unit-load-not-found-stuck.md](SBDEV-2102-putaway-unit-load-not-found-stuck.md)
- [260402-UTC-TIMEZONE-MIGRATION.md](260402-UTC-TIMEZONE-MIGRATION.md)
- [260329-WMS_OMS_Picking_Notification_Bug_Analysis.md](260329-WMS_OMS_Picking_Notification_Bug_Analysis.md)
- [260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md](260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md)
- [260422-v2-testing-migration-rollup.md](260422-v2-testing-migration-rollup.md) — *draft; coordination layer for the 3 testing plans below (start here)*
- [260420-v2-integration-tests-h2-migration-report.md](260420-v2-integration-tests-h2-migration-report.md) — *draft; pending review*
- [260420-v2-port-plpgsql-functions-to-java.md](260420-v2-port-plpgsql-functions-to-java.md) — *draft; pending review*
- [260421-v2-replace-pg-advisory-lock.md](260421-v2-replace-pg-advisory-lock.md) — *draft; pending review — sibling of PL/pgSQL plan*
- [260418-wms-api-v1-v2-sync-batch-plan-2026-04-18.md](260418-wms-api-v1-v2-sync-batch-plan-2026-04-18.md)

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
