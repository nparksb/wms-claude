---
title: "WMS v2 — Active Plans"
type: index
status: active
version: v2
scope: wms2-planning
updated: 2026-07-28
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
- [SBDEV-2736-outbox-dispatcher-status-blind-rejection.md](SBDEV-2736-outbox-dispatcher-status-blind-rejection.md) — *draft **r2** (post-ralplan review); HIGH — outbox dispatcher marks rows SENT on HTTP 2xx alone, but legacy OMS returns 200 with a non-Success verdict in **two different envelope shapes** → rejections recorded as deliveries. DB-proven: 613 rows on wineco-dev; ~48-68% of real BOL-shipped notifications rejected May–Jul 2026. Phase 1 = observability only (no semantics change), **r3 scope widened to all three WMS→OMS egress paths** after production showed 95.5% of rejections on the direct-POST path the original scope excluded. Spawned SBDEV-2737 (WMS sends `positions:[]`), SBDEV-2738 (OMS envelope normalization), **SBDEV-2748** (inventory export failing 19 months on one unmapped SKU — 575 occurrences, found by looking outside the original scope).*
- [SBDEV-2729-system-sku-receiving-null-label-token.md](SBDEV-2729-system-sku-receiving-null-label-token.md) — ***APPROVED r8** (architect + critic, 5 review rounds); **URGENT** — system SKU (ICE PACK, HMG) cannot be received: `String.replace(CharSequence, CharSequence)` is null-hostile and 4 of the 12 ZPL token sources in `SharedService.createCaseLabel` are nullable columns. Root cause reproduced on `openjdk 21.0.11`. **Verified implementable by an independent implementation**: whole verify script `62 pass, 0 fail`, full suite `4538 tests, 2 failures` (both pre-existing on `develop`). Split **PR1 (urgent)** / **PR2 (hardening)**, PR1 with a named acceptance subset. **Two caveats the approval does not cover:** `db_verified: partial` and confidence ~50-60% on `itemdata.winetype` specifically, so **§7.2 step 0 (get the verbatim error string from the ticket's screen recording / HMG log) is BLOCKING** — if it does not name `replacement`, §2 reopens. But reviews also found a **second, independent live defect that does not depend on the hypothesis**: `SharedService:66` `findById(unitload.getBoxtypeId())` with `boxtype_id` NULL on **80.1%** of unit loads (10,718/13,381), **281** of them on the reprint path — HTTP 500 today. That alone justifies PR1.*
- [SBDEV-2777-stock-history-client-id-blind-mis-aggregation.md](SBDEV-2777-stock-history-client-id-blind-mis-aggregation.md) — *draft; HIGH — `public.stock_history()` groups and joins on `item_nr` only, so every client stocking a shared SKU gets the **all-clients** stockrecord aggregate. DB-proven on `dev_wh01_om1`: SKU `PNRO23` returns 8,322 received for both its clients where the truth is 1,074 / 7,248 (7.7× overstatement). **Not a v1→v2 porting miss** — the missing clauses are in no migration script and in neither repo's git history; they were hand-applied to WineCo's v1 DB, so the repo baseline has always been blind and **all 5 v2 tenants inherit it** (affected SKUs: wsl 135, dev 43, c1wh 13, hydra 7, nywh-shipitez 0). Propagates into `transaction_detail` BEGINNING/ENDING and `transaction_summary` beginning/ending inventory via 4 internal calls. Fix is one `V2.2.x` `CREATE OR REPLACE`, unconditional, **no Java change** (signature unmoved); corrected aggregation pre-validated inline. **Caveat: authored without the ralplan Critic pass** — see the plan header. Other v1 tenants likely still blind → separate ticket.*
- [SBDEV-2778-return-to-inventory-not-received-bol-not-closed.md](SBDEV-2778-return-to-inventory-not-received-bol-not-closed.md) — *draft, **pending approval**, BLOCKED on §10-Q0 then Q1; URGENT — OMS Returns QA "Return to Inventory" creates a RETURN inbound advice that is never received and never closed (repro `IBOL012604`/`RETURN529599`, 0 `goodsreceipt` rows, `db_verified`). **NOT a migration oversight and NOT a printer issue** — a `processdefault` RETURN printer exists, and **SBDEV-2236 deliberately deleted** the auto-receive block (PR #24, `7f9c250`, 2026-05-15) with tests now enforcing its absence. Same stakeholder (David Oppenheim) requested 2236 and is assigned 2778. Design: gate auto-receive on an explicit OMS `qa_confirmed` assertion so 2236's invariant survives rather than being reverted — **not** a straight revert. **Q0 must be asked first:** OMS's `receiveReturnInWms` (Flow 2, "Receive + Print", already sends `printer_id`) may already be the sanctioned path, which would void Fix A/D. Architect pass incorporated (validate-before-persist redesign after finding a post-save 400 burns `externalid` and bricks every retry; `getErrorMap()` never emits the error code so OMS's `ENTITY_ALREADY_EXITS` branch is dead code; v1's boxtype fallback chain is unreachable; `optionalBoxtype.get()` NPE→500 spawns a v1+v2 ticket). **Critic pass outstanding.** `wms-tdd-gate` deliberately deferred until Q0/Q1 land.*
- [SBDEV-2238-4.6-oms-order-state-get-endpoint.md](SBDEV-2238-4.6-oms-order-state-get-endpoint.md) — *draft STUB; MEDIUM — paired OMS prerequisite for 4.6: OMS must expose read-only `GET /api/order/{externalId}` (200+state / 404-unknown) for the reconciliation job to compare against. Re-verified still absent in oms-laravel-api 2026-07-27; no reusable substitute, and `externalId` is ambiguous WMS-side.*

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
