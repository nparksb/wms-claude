---
title: "Reports — MOC"
type: index
status: active
version: both
scope: reports
updated: 2026-07-02
tags: [moc, index, reports]
---

# Reports — MOC

Point-in-time investigation, analysis, and validation reports for the SiteBoss OWL / WMS platform. Unlike the architecture/design MOCs (long-lived, re-verified on a cadence), **reports are snapshots** — they capture what was true at the time of writing and are not kept continuously in sync with the code. Read the `created`/`updated` date and treat older reports as historical.

See also: [vault index](../../INDEX.md) · [architecture MOC](../architecture/README.md) · [workflows MOC](../workflows/README.md) · [active plans (wms1)](../../1-Projects/wms1/plan/README.md) · [active plans (wms2)](../../1-Projects/wms2/plan/README.md)

---

## How to read this folder

- **Investigation** — diagnose / audit a concern without committing to a fix (hypotheses, evidence, verdict + confidence, recommendation).
- **Analysis / reference** — structural or comparative write-ups (delivery guarantees, migration-script comparison, project analysis).
- **Validation / test** — evidence that a deployed fix behaves correctly, plus a manual test plan to reproduce.

Filename convention: `YYMMDD-kebab-description.md` (date-prefixed) or a stable topic name for evergreen analyses.

---

## Inventory (filesystem snapshot)

| Report | Scope | Created |
|---|---|---|
| [Hydra UAT — Triage of Three Failed QA Flows (Pick & Pack, Club Line Palletize, Transfer Offsite)](260814-hydra-uat-three-flow-qa-triage.md) | wms2 | 2026-08-14 |
| [WMS v2 — `los_sysprop` Current-Value Census (DEV + UAT)](260730-wms2-sysprop-current-value-census.md) | wms2 | 2026-07-30 |
| [SBDEV-2514 — WineCo post-release (v1.26.43): Reserved-Out unit-load block + Replen Monitor QTY accuracy](260702-sbdev-2514-wineco-post-release-reserved-out-and-replen-monitor.md) | wms1 | 2026-07-02 |
| [SBDEV-2507 — Parcel Re-Palletized & Double-Shipped After Closed BOL (Web Palletize Check Gap)](260701-sbdev-2507-repalletize-double-ship-after-closed-bol.md) | wms1 | 2026-07-01 |
| [WineCo Replenishment Job Slow Runtime — Root Cause & Index Evaluation](260701-wineco-replenishment-job-slow-runtime-index-eval.md) | wms1 | 2026-07-01 |
| [Stock-Unit History Not Logged on Unit-Load Location Move (Move Fixed Location)](260624-stock-unit-history-gap-on-unitload-location-move.md) | wms1 | 2026-06-24 |
| [WMS2 Horizontal Scalability Readiness Audit (June 2026)](260610-wms2-horizontal-scalability-readiness-audit.md) | wms2 | 2026-06-10 |
| [WMS v2 UI ↔ API Datetime Audit (read + write paths)](260609-wms2-ui-outbound-datetime-audit.md) | wms2 | 2026-06-09 |
| [SBDEV-2384 — Replenishment Monitor Fix: Validation & Manual Test Plan](260602-SBDEV-2384-replenishment-monitor-fix-validation-and-test-plan.md) | wms1 | 2026-06-02 |
| [WineCo Replenishment — Pick-Pack Locations Counted as Replenishable & Inaccurate Order Counts](260601-wineco-replenishment-pickpack-source-and-order-count.md) | wms1 | 2026-06-01 |
| [WMS v1 vs v2 DB Migration Script Comparison](260527-wms-v1-v2-db-migration-script-comparison.md) | both | 2026-05-27 |
| [UTC Timezone Migration — Code Changes Reference](260526-utc-migration-code-changes-reference.md) | both | 2026-05-26 |
| [WMS2 REST Idempotency — Options Without JWT](260522-wms2-rest-idempotency-without-jwt-options.md) | wms2 | 2026-05-22 |
| [SBDEV-2033 — Adjust Reserved Amount Does Not Stick on WineCo Production](260522-sbdev-2033-reserve-amount-adjust-not-sticking.md) | wms1 | 2026-05-22 |
| [WMS2 — QA Blocked: Missing tote_label in PICKING_FINISHED Payload + Service Log Gap](260521-wms2-qa-blocked-tote-label-and-message-log-gap.md) | wms2 | 2026-05-21 |
| [WMS2 — ORDER_BATCH_PICKING_FINISHED Notification Silently Dropped](260520-wms2-picking-finished-oms-notification-dropped.md) | wms2 | 2026-05-20 |
| [WMS v2 Cycle Count — Blind & Randomized Count Capability Investigation](260520-wms2-cycle-count-blind-random-investigation.md) | wms2 | 2026-05-20 |
| [Picking lock-ordering inconsistency: processPick vs confirmPick](260507-picking-lock-ordering-inconsistency.md) | wms1 | 2026-05-07 |
| [SBDEV-1581: Empty Pallet Cleanup — Investigation Report](260506-sbdev-1581-empty-pallet-cleanup-investigation.md) | wms1 | 2026-05-06 |
| [WMS → OMS Notification Delivery Guarantees — Analysis Report](260424-wms-oms-notification-delivery-guarantees.md) | both | 2026-04-24 |
| [WMS API v1 → v2 Applicability — commits after 2026-03-20](wms-api-v1-commits-post-2026-03-20-applicability.md) | both | — |
| [WMS v2 Project Analysis](wms2-project-analysis.md) | wms2 | — |

> This list can drift. In Obsidian the Dataview block below is authoritative; elsewhere run `ls sbdocs/3-Resources/reports/*.md`.

---

## Dataview — by date

```dataview
TABLE scope AS "Scope", status AS "Status", created AS "Created", updated AS "Updated"
FROM "3-Resources/reports"
WHERE type = "report"
SORT created DESC
```
