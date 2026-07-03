---
title: "WMS v2 — Active Plans"
type: index
status: active
version: v2
scope: wms2-planning
updated: 2026-07-02
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
- [260628-shipitez-v1-to-v2-migration-runbook.md](260628-shipitez-v1-to-v2-migration-runbook.md) — *ShipItEZ v1→v2 UTC migration **run record**; two warehouses (wh02/nywh NY + wh01/c1wh LA), both pre-bridge v1; readiness GREEN 2026-06-28, nothing executed yet. LA has a seqentities multi-island item; procedure lives in the [SOP](../../../2-Areas/wms-utc-timezone-migration/README.md)*
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
- [260629-transfer-lane-leak-on-cancel.md](260629-transfer-lane-leak-on-cancel.md) — *implemented 2026-06-29 (ralplan: architect SOUND, reviewer SHIP); empty "Activate Transfer Order" dialog → transfer lanes leaked by orders abandoned at state 505/510. cancelOrder/forceCancelOrder now clear `transferlaneId`; `unlinkTransferLaneFromTransferOrder` got its missing tenant TM. PR [#56](https://github.com/SiteBossInc/wms2-api/pull/56) → develop (143 tests/0 fail, verify 12/0). Post-deploy: unlink order 22476694. Archive after merge.*
- [260629-activate-transfer-atomicity.md](260629-activate-transfer-atomicity.md) — *implemented 2026-06-29 (ralplan: Architect SOUND, Critic APPROVE; code review SHIP); MEDIUM — root-cause follow-up to the lane-leak fix: `/activateTransferOrder` ran activate+assign in two separate tenant TXs, stranding orders at 505-with-lane on partial failure (5 confirmed live on wineco-dev). Fix = one atomic `activateAndAssignTransferLane` (persists 510 directly). PR [#58](https://github.com/SiteBossInc/wms2-api/pull/58) → develop (58 tests/0 fail, verify 14/0). Archive after merge.*
- [260629-transfers-available-lanes-orderbatchid-mislabel.md](260629-transfers-available-lanes-orderbatchid-mislabel.md) — *implemented 2026-06-29 (ralplan: Architect SOUND, Critic APPROVE; code review SHIP); LOW — `TransfersController.getAvailableTransferLanes` passed the request body `orderBatchId` straight in as `customerOrderId`, breaking the JPQL self-exclusion so the activate/reassign dialog couldn't show the order's own current lane. Fix resolves CO id from batch id server-side + empty-batch guard; getSKUOverview log strings corrected. PR [#57](https://github.com/SiteBossInc/wms2-api/pull/57) → develop (20 tests/0 fail, verify 6/0). Archive after merge.*
- [SBDEV-2390-web-pickpack-keycloak-refresh-loop.md](SBDEV-2390-web-pickpack-keycloak-refresh-loop.md) — *ready-for-review 2026-07-02 (ralplan: Planner→Architect→Critic APPROVE); HIGH — **frontend (wms2-web-ui)**, not wms2-api. Continuous refresh/redirect loop on Open PickPack Parcels. Root cause = `check-sso`→`login-required` regression (`47a3a12` reverted `d1562c1`) + unconditional `keycloakInstance.login()` with no loop guard; desktop↔mobile shared-origin localStorage collision is the trigger. Fix = restore check-sso + sessionStorage redirect-loop breaker (MAX=2 → `/unknown-tenant?reason=auth`) + `tokenParsedfg` typo. Fix F (namespace localStorage keys) deferred. verify script baseline 0/14. Paired with mobile plan below.*
- [SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.md](SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.md) — *ready-for-review 2026-07-02 (ralplan APPROVE); HIGH — **frontend (wms2-mobile-ui)** paired mirror of the web plan (identical regression `1c219bc` + shared SSO session). Adds Fix D (dead-code catch path → guarded clear-error) and re-adds the `/mobile/` silent-SSO uri. No test harness in mobile → manual QA + verify-script code-shape checks. verify baseline 1/14.*

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
