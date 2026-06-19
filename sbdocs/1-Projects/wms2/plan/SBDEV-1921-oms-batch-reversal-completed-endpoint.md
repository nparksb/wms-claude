---
title: "OMS endpoint: POST /services/call/batchReversalCompleted (SBDEV-1921 reversal-completion handler)"
ticket: ""
ticket_url: ""
type: feature
priority: high
status: draft
project: [wms2]
version: v2
requester: nam.park@siteboss.net
created: 2026-06-16
updated: 2026-06-16
db_verified: false
related:
  - "[[SBDEV-1921-order-cancellation-reversal-workflow]]"
  - sbdocs/3-Resources/architecture/wms2-oms-integration-map.md
tags: [stub, oms-integration, cancellation, reversal, oms-laravel-api, plan]
---

# OMS endpoint: `POST /services/call/batchReversalCompleted`

**Project:** wms2 (defect/work is in `v2/oms-laravel-api`; consumer is `v2/wms2-api`) | **Version:** v2 | **Type:** feature (paired prerequisite)
**Priority:** High
**Status:** Draft (STUB — needs OMS-team estimation + ticket number)
**Date:** 2026-06-16

> **Why this stub exists.** This is the **paired OMS-side prerequisite** for [[SBDEV-1921-order-cancellation-reversal-workflow]]
> (Open Q2 / Follow-up F1). The WMS side (Phases 1–4) is implemented and merged to `develop`, and WMS already
> **enqueues** the `ORDER_BATCH_REVERSAL_COMPLETED` outbox message on reversal completion. But the OMS handler it
> POSTs to **does not exist** — verified absent in `oms-laravel-api` (`app/`, `routes/`) on 2026-06-16. Until this
> endpoint ships, those outbox rows retry indefinitely against a missing handler. The parent plan **cannot be
> closed/archived** until this is done and the per-environment sysprop URL is set.

---

## 1. Problem Statement

WMS emits a reversal-completion notification (new `MessageProcessType.ORDER_BATCH_REVERSAL_COMPLETED`) to OMS at a
dedicated URL (`WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` sysprop). OMS has no route to receive it. A dedicated
endpoint is **required** (not a reuse of `/services/call/cancelPosition`) because that existing handler
unconditionally calls `returnInventoryToAvailable()`, which already fired on the original cancel — reusing it
would **double-count available inventory**. See parent plan §3.5.2.

## 2. Required handler contract (from parent §3.5.2)

New route in `LegacyWmsController`: `POST /services/call/batchReversalCompleted`

**MUST:**
1. Validate `batch_id` (required) and `positions[].unique_id` (required).
2. Find the `Parcel` by `unique_id` within the batch.
3. Mark reversal complete — set parcel status `REVERSAL_COMPLETED` (or a `reversal_completed_at` timestamp; **decide which** — Q2 sub-question).
4. Write an audit-log row.
5. Return `{ "Status": "Success" }`.

**MUST NOT:**
- ❌ Call `returnInventoryToAvailable()` — inventory was already restored by `/services/call/cancelPosition` on the original cancel.
- ❌ Touch `product_inventory` quantities or allocations.

Payload is the standard `OrderBatchDto` shape (parent §3.5.2); OMS only needs `batch_id` + `positions[*].unique_id`.
Effort: **low** — thin status/audit handler, no inventory math.

## 3. Acceptance

- [ ] Route exists and is auth-guarded consistent with other `/services/call/*` WMS callbacks.
- [ ] Idempotent: a duplicate POST for an already-reversal-completed parcel is a no-op `Success` (WMS outbox retries up to 5×).
- [ ] No `product_inventory` write occurs (assert via test — guards against the double-count footgun).
- [ ] Decision recorded: parcel-status enum value vs. timestamp field (parent Q2).
- [ ] Verified end-to-end against a WMS `ORDER_BATCH_REVERSAL_COMPLETED` outbox delivery on a dev tenant.

## 4. Deploy coupling (closes the parent plan)

1. Ship this endpoint in `oms-laravel-api`.
2. Set `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` sysprop to the real per-env URL on each tenant DB
   (wineco-dev/qa/ua/prod) — replaces the `oms-XXXXX.siteboss.net` placeholder default in
   `wms2-api WmsConstants.java:922`.
3. Re-run `verify-SBDEV-1921-order-cancellation-reversal-workflow.sh` — the "Closure blockers" section should flip
   to `[ok]`, after which the parent plan is archivable.

## 5. Open Questions

- [ ] Assign a real ClickUp/SBDEV ticket number (this is a stub).
- [ ] Parcel-status value: new `REVERSAL_COMPLETED` enum vs. `reversal_completed_at` timestamp column? (parent Q2)
- [ ] Does any existing OMS code reduce `quantity_allocated` at cancel-request time? (parent §3.5.1 "double-count risk" — confirm OMS is callback-only before relying on the cancel-side inventory restore.)
