---
title: "Workflows — Business Process Reference"
type: index
status: active
version: both
scope: workflows
updated: 2026-04-19
tags: [moc, index, workflows]
---

# Workflows — Business Process Reference

Long-lived, code-grounded documentation of **business processes** in WMS (what happens end-to-end, which services fire, which tables change, which states transition). Distinct from plans (transient) and architecture docs (structural).

See also: [vault index](../../INDEX.md) · [workflow template](../../9-System/templates/wms-workflow-template.md) · [architecture](../architecture/) · [design](../design/)

---

## Current workflows

### WMS v1

- [wms1-bol-truck-loading-workflow.md](wms1-bol-truck-loading-workflow.md) — palletize → truck load → BOL close; TRANSFER_INTRACOMPANY two-step
- [wms1-cancel-cascade-workflow.md](wms1-cancel-cascade-workflow.md) — 6 cancel entry points, cascade through Customerorder / Pickingorder; `cancellationFromWithinWMS` dead-code finding; deferred cancel via `markedforcancellation`
- [wms1-club-order-processing.md](wms1-club-order-processing.md) — club order allocation → packed → shipped pipeline
- [wms1-cycle-count-workflow.md](wms1-cycle-count-workflow.md) — inventory audit; `amountbefore/amountafter` diff → stock adjustment; fast-path vs order-driven flows; orphaned-position failure modes
- [wms1-move-stock-unitload-workflow.md](wms1-move-stock-unitload-workflow.md) — move unitload vs move stock distinction; `transferStockToUnitLoad` two-path split; missing pessimistic lock (v1-specific); `SEND_TO_NIRWANA` activity code typo
- [wms1-multi-unitload-replenish.md](wms1-multi-unitload-replenish.md) — API-driven multi-UL batch `POST /v3/replenish/multi-unitloads`; deterministic order numbering; `amountPicked` explicit-set requirement
- [wms1-picking-workflow.md](wms1-picking-workflow.md) — release → reserve → start → finalize 5-entity cascade; RESERVED=400 v1-specific state; 3 OMS callbacks
- [wms1-replenish-order-creation.md](wms1-replenish-order-creation.md) — how replenish orders get created from demand
- [wms1-replenish-workflow.md](wms1-replenish-workflow.md) — replenish task execution on the floor
- [wms1-receiving-putaway-workflow.md](wms1-receiving-putaway-workflow.md) — OMS advice push → goods receipt → Unitload/Stockunit creation → mobile putaway; RETURN auto-receive; FLOWBIN/OVERSTOCK classification; v1-vs-v2 diff table
- [wms1-transfer-order-workflow.md](wms1-transfer-order-workflow.md) — source-to-destination two-warehouse walk; `CUSTOMER_ORDER_ACTIVATED` → `TRANSFER_LANE_ASSIGNED` → `finishTransfer`; v1-vs-v2 diff table

### WMS v2 — Outbound pipeline

- [wms2-picking-workflow.md](wms2-picking-workflow.md) — release → reserve → start → `finalizePicking` 5-entity cascade; mobile guards; rapid-pick side-door
- [wms2-cancel-cascade-workflow.md](wms2-cancel-cascade-workflow.md) — 6 cancel entry points, cascade through Customerorder / Pickingorder / PickingorderUnitload; `CANCELED` vs `CANCELLED` spelling
- [wms2-bol-truck-loading-workflow.md](wms2-bol-truck-loading-workflow.md) — palletize → truck load → BOL close; dual concurrency guard; `TRANSFER_INTRACOMPANY` two-step
- [wms2-club-run-workflow.md](wms2-club-run-workflow.md) — CustomerorderBatch 4-phase runClubLine + rollback semantics; synthetic UUID `historytote`
- [wms2-transfer-order-workflow.md](wms2-transfer-order-workflow.md) — source-to-destination two-warehouse walk; `CUSTOMER_ORDER_ACTIVATED` → `TRANSFER_LANE_ASSIGNED` → `finishTransfer`

### WMS v2 — Inbound & maintenance

- [wms2-receiving-putaway-workflow.md](wms2-receiving-putaway-workflow.md) — ASN / advice lifecycle, case-by-case receive loop, mobile putaway with FLOWBIN/OVERSTOCK classification
- [wms2-cycle-count-workflow.md](wms2-cycle-count-workflow.md) — inventory audit; `amountbefore/amountafter` diff → `WEBSERVICE_STOCK_UPDATE`; no-reopen constraint
- [wms2-move-stock-unitload-workflow.md](wms2-move-stock-unitload-workflow.md) — full unit-load moves vs partial stock splits; pessimistic lock site; outbound-pallet BOL cleanup

### WMS v2 — Replenishment family

- [wms2-replenish-order-creation.md](wms2-replenish-order-creation.md) — how v2 replenish orders get created
- [wms2-replenish-workflow.md](wms2-replenish-workflow.md) — v2 replenish execution
- [wms2-multi-unitload-replenish.md](wms2-multi-unitload-replenish.md) — multi-unitload variant

---

## Dataview — by version

```dataview
TABLE version AS "Version", scope AS "Scope", updated AS "Updated", last_verified AS "Verified"
FROM "3-Resources/workflows"
WHERE type = "workflow"
SORT version ASC, file.name ASC
```

## Dataview — v1 ↔ v2 pairs

For the replenish family, each v1 workflow should have a v2 counterpart. This query surfaces the pair state.

```dataview
TABLE scope AS "Scope", version AS "Version", updated AS "Updated"
FROM "3-Resources/workflows"
WHERE type = "workflow" AND contains(scope, "replenish")
SORT scope ASC, version ASC
```

## Dataview — stale (not verified in 60 days)

Business processes drift from code slowly. Re-verify at least every 2 months.

```dataview
TABLE version AS "Version", last_verified AS "Last Verified", verified_by AS "How"
FROM "3-Resources/workflows"
WHERE type = "workflow" AND last_verified AND (date(today) - date(last_verified)) > dur(60 days)
SORT last_verified ASC
```

---

## Conventions

- **Filename pattern**: `{version}-{process}.md` (e.g. `wms2-replenish-workflow.md`). The version prefix makes v1/v2 pairs obvious in `ls`.
- **Scope tag** should be the process, not the version (e.g. `scope: replenish`, not `scope: wms2-replenish`) so cross-version queries work.
- **Last-verified** is mandatory. A workflow doc with no `last_verified` field is effectively a blog post — it tells the reader nothing about whether it still matches the code.
- **Evidence**: every claim ties to a file path / class / stored procedure. If you can't cite it, don't state it.
- When a v2 workflow diverges enough that the v1 version is actively misleading, mark v1's `status: superseded` with `superseded_by:` pointing at the v2 file. Do not delete.
