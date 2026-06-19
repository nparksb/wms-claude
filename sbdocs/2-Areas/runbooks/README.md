---
title: "Runbooks — MOC"
type: index
status: active
scope: runbooks
updated: 2026-06-11
tags: [moc, index, runbooks]
---

# Runbooks — MOC

Oncall-ready recovery playbooks for WMS / OMS operational events. Each runbook assumes the reader is in triage — pages are scannable, commands are copy-pastable, and every rollback / force path names its preconditions.

See also: [vault index](../../INDEX.md) · [runbook template](../../9-System/templates/wms-runbook-template.md) · [symptom index](../../_symptom-index.md)

---

## 1. How to read this folder

- **One runbook per recoverable failure mode.** If an operation has multiple distinct failure modes, they get their own files, not sections inside one.
- **Runbooks are oncall docs, not design docs.** When the background of a problem gets too long, spin off an architecture or investigation doc under `3-Resources/` and link back.
- Start at §2 (by scope), or jump in via the [symptom index](../../_symptom-index.md) if you have an error message but not a system.

---

## 2. Active runbooks

| Runbook | Scope | Severity | When to use |
|---|---|---|---|
| [wms1-cancel-packed-parcel.md](./wms1-cancel-packed-parcel.md) | wms-api v1 | SEV3 | Cancelling a customer order past QA (state ≥ PACKED 650) — REST blocks this for PICK_PACK, runbook covers the CLUB REST path and the manual-SQL path with OMS notification + BOL cleanup |
| [wms1-revert-shipped-order-to-cancelled.md](./wms1-revert-shipped-order-to-cancelled.md) | wms-api v1 | SEV3 | Reverting an order that WMS shipped *after* OMS cancelled it — order state 700/800 with parcel still on `Shipped`. Covers the pallet-detach, Option A (parcel→Clearing only) vs Option B (return quantities to source stockunits), sibling-order safety, and BOL-position rollback |
| [wms2-resend-picking-finished-notification.md](./wms2-resend-picking-finished-notification.md) | wms2-api v2 | SEV2 | OMS reports "No Parcel Found" / QA does not trigger after picking — dropped `ORDER_BATCH_PICKING_FINISHED` notification due to double `afterCommit` registration. Covers curl resend, `batch_criteria.batch_label` fix, direct OMS SQL repair, and outbox INSERT fallback |
| [wms1-release-orphaned-stock-reservation.md](./wms1-release-orphaned-stock-reservation.md) | wms-api v1 | SEV2 | Pick line stuck on "Not enough stock on location" while the SKU report shows stock present (Total = Reserved). Confirms the reservation is held by no live picking/replenish order, then releases it (supervised `reservedamount` correction, in-app stock move, cycle count, or physical fallback) so the order ships. Worked example: BW23CPN / 10-B01 |
| [wms2-sku-trim-data-cleanup.md](./wms2-sku-trim-data-cleanup.md) | wms2-api v2 | SEV3 | Phase 2 of plan 260610 (SKU trim normalization) — per-tenant `itemdata.item_nr`/`name` whitespace cleanup. Collision census, duplicate-pair resolution (e.g., hydra `BONMFPN23`), gated trim UPDATEs, and the Phase 1b deploy sequencing choreography |
| [wms2-unstick-held-outbox-aggregate.md](./wms2-unstick-held-outbox-aggregate.md) | wms2-api v2 | SEV2 | SBDEV-2381 fail-closed gate aftermath — an OMS event stuck behind a lower-`id` `FAILED_TERMINAL` sibling holds the later PICKING_FINISHED for that order. Diagnosis query, re-drive vs. manual mark-SENT (per-tenant SQL on `outbox_message`), and the paired stuck-aggregate metric prerequisite |

---

## 3. Dataview — runbook inventory (Obsidian only)

```dataview
TABLE scope AS "Scope", severity AS "Severity", last_verified AS "Last verified"
FROM "2-Areas/runbooks"
WHERE type = "runbook"
SORT last_verified DESC
```

```dataview
TABLE scope AS "Scope", last_verified AS "Last verified", updated AS "Updated"
FROM "2-Areas/runbooks"
WHERE type = "runbook" AND last_verified AND (date(today) - date(last_verified)) > dur(90 days)
SORT last_verified ASC
```

---

## 4. Conventions

- **`type: runbook`** — mandatory on every file here.
- **`severity:`** — `SEV1` (paging, customer-facing outage), `SEV2` (degraded ops), `SEV3` (manual intervention, no alert).
- **`alert:`** — the exact alert name, ticket pattern, or support escalation phrase that maps here. A runbook with no `alert:` is hard to find when it's 2am.
- **`last_verified:`** — re-verify every **90 days** or after any underlying code change that touches the runbook's SQL / commands. Update `verified_by` too.
- **Command-level specificity.** No "contact the DBA" — write the exact SQL they'll run. If the command varies by env, name the variable and show where to look it up.
- **Every destructive block inside a transaction.** `BEGIN` / verify / `COMMIT`-or-`ROLLBACK`. Never present a raw `UPDATE`/`DELETE` as standalone.
- **Cite code line numbers** for any behavior the runbook depends on, so future drift is obvious when the line moves.

---

## 5. Adding a new runbook

1. Start from the [runbook template](../../9-System/templates/wms-runbook-template.md).
2. File name: `<system>-<action>.md` — e.g. `wms1-cancel-packed-parcel.md`, `wms2-unstick-stuck-pickingorder.md`, `oms-retry-failed-batch.md`.
3. Fill the frontmatter — especially `alert`, `severity`, `last_verified`, `verified_by`, `related`.
4. Follow the template sections: triage → diagnosis → recovery → escalation → verification → post-incident → related.
5. Add a row in §2 above.
6. If the runbook answers a recurring support symptom, register it in [_symptom-index.md](../../_symptom-index.md).
