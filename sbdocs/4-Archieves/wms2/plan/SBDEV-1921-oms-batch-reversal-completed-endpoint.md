---
title: "OMS endpoint: POST /services/call/batchReversalCompleted (SBDEV-1921 reversal-completion handler)"
ticket: "SBDEV-2369"
ticket_url: "https://app.clickup.com/t/SBDEV-2369"
type: feature
priority: high
status: archived
project: [wms2]
version: v2
requester: nam.park@siteboss.net
created: 2026-06-16
updated: 2026-07-27
db_verified: false
related:
  - "[[SBDEV-1921-order-cancellation-reversal-workflow]]"
  - sbdocs/3-Resources/architecture/wms2-oms-integration-map.md
tags: [oms-integration, cancellation, reversal, oms-laravel-api, plan, implemented, archived]
---

> **Archived 2026-07-27.** OMS endpoint shipped (SBDEV-2369, `b96b2daf`, in production) and the
> `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` sysprop is set on every reachable dev tenant (§4 step 2).
> Two items were handed off rather than closed here — see §4.1: the **dispatcher `Status`-blind success defect**
> (§3.1 item 3, needs its own ticket, cross-cutting) and the **unverified qa/ua/prod sysprop rows** (ops check).
> No paired acceptance script existed for this stub; the parent plan's script lives at
> `sbdocs/4-Archieves/scripts/verify-SBDEV-1921-order-cancellation-reversal-workflow.sh` (last run 2026-07-27:
> 21 pass, 0 fail, 1 skip).

# OMS endpoint: `POST /services/call/batchReversalCompleted`

**Project:** wms2 (work was in `v2/oms-laravel-api`; consumer is `v2/wms2-api`) | **Version:** v2 | **Type:** feature (paired prerequisite)
**Priority:** High
**Status:** **Implemented on OMS** — shipped under ticket **SBDEV-2369**, commit `b96b2daf` (David Oppenheim, 2026-06-10). Present on `oms-laravel-api` `develop` **and** `origin/main` (production release v2.0.69). Remaining closure work is WMS-side only (per-env sysprop URL, §4).
**Date:** 2026-06-16 (drafted) / 2026-07-27 (verified implemented)

> **Why this stub existed.** This was the **paired OMS-side prerequisite** for
> [[SBDEV-1921-order-cancellation-reversal-workflow]] (Open Q2 / Follow-up F1). The WMS side (Phases 1–4) is
> implemented and merged to `develop`, and WMS **enqueues** the `ORDER_BATCH_REVERSAL_COMPLETED` outbox message on
> reversal completion. The OMS handler it POSTs to now **exists**.

> ⚠️ **Correction to the original draft.** This document previously stated the endpoint was "verified absent in
> `oms-laravel-api` (`app/`, `routes/`) on 2026-06-16". **That check was wrong** — the OMS commit landed
> **2026-06-10**, six days *before* the stated verification date. The absence claim propagated into the parent
> plan's closure checklist and into `1-Projects/wms2/plan/README.md`; both have been corrected. Do not treat the
> original 2026-06-16 finding as evidence of anything.

---

## 1. Problem Statement (as drafted — retained for context)

WMS emits a reversal-completion notification (`MessageProcessType.ORDER_BATCH_REVERSAL_COMPLETED`) to OMS at a
dedicated URL (`WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` sysprop). A dedicated endpoint was **required** (not a
reuse of `/services/call/cancelPosition`) because that existing handler unconditionally calls
`returnInventoryToAvailable()`, which already fired on the original cancel — reusing it would **double-count
available inventory**. See parent plan §3.5.2.

## 2. Required handler contract (from parent §3.5.2) — as shipped

New route in `LegacyWmsController`: `POST /services/call/batchReversalCompleted`

**MUST:**
1. ✅ Validate `batch_id` (required) and `positions[].unique_id` (required).
2. ✅ Find the `Parcel` by `unique_id` within the batch.
3. ✅ Mark reversal complete — **decision made: timestamp**, not a status enum (see §3).
4. ✅ Write an audit-log row (`ParcelStatusHistory`).
5. ✅ Return `{ "Status": "Success" }`.

**MUST NOT:**
- ✅ Does **not** call `returnInventoryToAvailable()`.
- ✅ Does **not** touch `product_inventory` quantities or allocations.

## 3. Verification — 2026-07-27

Checked against `v2/oms-laravel-api` branch `develop` @ `f56b8ddf`.

| Acceptance criterion | Verdict | Evidence |
|---|---|---|
| Route exists, auth-guarded consistent with other `/services/call/*` WMS callbacks | ✅ | `routes/legacy-services.php:89` — same `Route::prefix('services/call')` group as `cancelPosition`, `closeTransfer`, `closeAdvice`. **Consistency note:** that group carries *no* route-level middleware — the endpoint is as (un)guarded as its siblings, which is what "consistent" means here, not that it is authenticated. |
| Idempotent: duplicate POST is a no-op `Success` | ✅ | `app/Http/Controllers/Api/Legacy/LegacyWmsController.php:3251` — `if ($parcel->reversal_completed_at !== null) { $processed++; continue; }`. Matters because the WMS outbox retries up to 5×. |
| No `product_inventory` write | ✅ | Handler body (lines 3185–3295) contains no `returnInventoryToAvailable`, no `ProductInventory`, no `quantity_allocated`. Only the timestamp stamp + audit row. |
| Decision recorded: status enum vs. timestamp (parent Q2) | ✅ **timestamp** | Migration `database/migrations/tenant/2026_06_10_100000_add_reversal_completed_at_to_parcel.php` adds `parcel.reversal_completed_at datetime NULL`; `database/schema/tenant-baseline.sql:2350`; cast in `app/Models/Parcel.php:103`. **`parcel_status` is deliberately left unchanged.** |
| Tests exist | ✅ | `tests/Feature/Legacy/LegacyWmsBatchReversalCompletedTest.php` — covers happy path, idempotent re-POST (asserts the timestamp does not move), validation failures, missing-parcel. |
| OpenAPI published | ✅ | `storage/api-docs/api-docs.json:27672`, `operationId: legacyBatchReversalCompleted`. |
| Verified end-to-end against a real WMS `ORDER_BATCH_REVERSAL_COMPLETED` outbox delivery on a dev tenant | ❓ **not established** | Not determinable from the repo. Still worth doing once the sysprop URL is set (§4). |

### 3.1 Contract deltas vs. the drafted spec — read before closing the parent

Three things the shipped handler does that the draft did not specify. Items 1–2 turned out to be **non-risks**;
item 3 is a real defect.

1. **Batch lookup is by label, not id.** `BatchCriteria::where('batch_label', $batchId)` → then parcels are scoped
   by `batch_criteria_id`. WMS must send the batch **label** in `batch_id`.
2. **Parcel lookup is dual-key.** Numeric `unique_id` → `parcel.parcel_id`; otherwise (and as fallback) →
   `parcel.parcel_id_str`. Both are scoped to the resolved batch.

   > **Items 1–2 verified safe, 2026-07-27.** This is byte-for-byte the same resolution the **production-proven
   > `cancelPosition` path** uses — `LegacyPositionCancelService.php:54` (`BatchCriteria::where('batch_label', …)`),
   > `:160` (`parcel_id`), `:169` (`parcel_id_str`), both scoped by `batch_criteria_id`. Since WMS already drives
   > `cancelPosition` successfully with the same `batch_id` + `positions[].unique_id` shape, the identifiers line
   > up. On the WMS side `CancellationReversalService.java:231,235` populates `uniqueId` from
   > `Customerorder.externalnumber` and `batchId` from `CustomerorderBatch.batchid` — the same sources. No action
   > needed.
3. **⚠️ Errors return HTTP 200 — and WMS cannot tell. CONFIRMED defect, 2026-07-27.** An unknown `batch_id`, or
   any unresolvable `positions[].unique_id`, returns **HTTP 200** with `{"Status": "Error", "Result": [...]}` —
   not a 4xx. The WMS dispatcher decides success on the **HTTP code alone**:

   ```java
   // OutboxDispatchService.dispatchOne — service/job/OutboxDispatchService.java:135-140
   int code = Integer.parseInt(result.get("code"));
   if (code >= 200 && code < 300) {
       outboxService.markSent(msg.getId());                                  // ← body never parsed
       meters.counter("wms2.outbox.dispatched", TAG_OUTCOME, "sent").increment();
       writeServiceLog(msg, WmsConstants.MessageStatus.SENT, String.valueOf(code), result.get("answer"));
   }
   ```

   So an identifier mismatch is **recorded as a successful delivery**: the outbox row goes `SENT`, no retry fires,
   no metric distinguishes it, and `cleanupSent(RETENTION_DAYS)` eventually deletes the row. OMS never records the
   reversal and nothing alerts. The only trace is the service-log row, which stores the `{"Status":"Error"}` body
   under status **`SENT`** — forensically recoverable by grepping response bodies, but invisible to monitoring.

   This is exactly the silent-notification-loss class that SBDEV-2238/2221 exist to eliminate, reintroduced at the
   response-parsing layer. It is **not** specific to this endpoint — every `/services/call/*` OMS handler uses the
   same 200-with-`Status` convention, so this affects the whole outbox → legacy-OMS surface.

   **Action: tracked as [SBDEV-2736](https://app.clickup.com/t/868kgmr5a)** (filed 2026-07-27) — dispatcher should
   treat a 2xx body with `Status != Success` as a failure, or at minimum emit a distinct counter. Out of scope for
   this stub — but it means the §4 rollout below is not risk-free, and the URL is already pointed at a live dev OMS.

## 4. Remaining work to close the parent plan

1. ✅ ~~Ship this endpoint in `oms-laravel-api`.~~ Done — `b96b2daf`, in production.
2. [x] **Set `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` per tenant — DONE on every reachable dev tenant**
   (queried 2026-07-27). The code default in `WmsConstants.java:933` is still the `oms-XXXXX.siteboss.net`
   placeholder, but that default is never reached because each tenant DB has a real row:

   | Tenant DB | `sysvalue` | modified |
   |---|---|---|
   | wms2-wineco-dev | `https://api-oms.dev.sbo.li/services/call/batchReversalCompleted` | 2026-05-29 |
   | wms2-wineco-dev2 | `https://api-oms.dev.sbo.li/services/call/batchReversalCompleted` | 2026-06-09 |
   | wms2-hydra-dev2 | `https://api-oms-dev.siteboss.net/services/call/batchReversalCompleted` | 2026-06-09 |
   | wms2-hydra-v2t | `CHANGE-ME-FOR-NEW-CLIENT/services/call/batchReversalCompleted` | 2026-06-11 |

   `hydra-v2t` is the **fresh-provision template** DB — the `CHANGE-ME-FOR-NEW-CLIENT` placeholder is seeded by
   the base dump and rewritten per client by `db/configure-client-sysprops.sh`, so it is correct-as-is, not a miss.

   Also note there is **no `…_ACTIVATED` gate** for this key (unlike `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED`,
   which is `false` on both tenants). `CancellationReversalService.java:223-228` gates purely on the URL being
   non-blank, so the notification is **live wherever the row is set**.

   **Residual:** qa / ua / prod tenant DBs are not reachable from the dev workstation and were **not** verified.
   Re-check there with:
   `SELECT syskey, sysvalue FROM los_sysprop WHERE syskey = 'WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED';`
   (note the column is `syskey`/`sysvalue`, not `name`/`value`).
3. [x] ~~Confirm the §3.1 item 3 question (does the WMS dispatcher check `Status`, or only the HTTP code?).~~
   **Answered 2026-07-27: HTTP code only.** See §3.1 item 3 — this is a confirmed silent-loss defect spanning the
   whole outbox → legacy-OMS surface and needs its own ticket. Not a blocker on *this* stub, but it must be
   understood before step 2 points the URL at a live OMS.
4. [x] **Re-ran `verify-SBDEV-1921-order-cancellation-reversal-workflow.sh` 2026-07-27 — `21 pass, 0 fail, 1 skip`**
   (C8 Maven suites skipped; `RUN_TESTS=1` to include). Closure blocker flipped to
   `[ok] OMS endpoint batchReversalCompleted appears present in oms-laravel-api`. The remaining
   `[TODO] sysprop default still the oms-XXXXX placeholder` line only inspects the **code default** in
   `WmsConstants.java` and cannot see per-tenant `los_sysprop` rows — per step 2 those are set, so that line is
   cosmetic and will never clear unless the code default itself is changed.

   The same run initially reported 5 failures (C2 ×4, C7-menu); all were **stale assertions, not regressions** —
   `V2.1.12` had been squashed into the `V2.2.00` baseline (table @813, partial index @3869, function seed @2818)
   and the mobile menu item was retitled "Cancellation Process" → "Return to Stock (RTS)". The script was
   corrected to resolve the migration dynamically and to assert on the route + role rather than the label.
5. [x] **Archived 2026-07-27.**

### 4.1 Handed off, not closed here

- **Dispatcher `Status`-blind success (§3.1 item 3)** — confirmed defect, cross-cutting across the whole
  outbox → legacy-OMS surface. Filed 2026-07-27 as **[SBDEV-2736](https://app.clickup.com/t/868kgmr5a)**;
  deliberately not held inside this stub.
- **qa / ua / prod sysprop rows** — unverified from the dev workstation (step 2 residual). An ops check, not
  engineering work.

## 5. Open Questions

- [x] ~~Assign a real ClickUp/SBDEV ticket number.~~ OMS shipped it as **SBDEV-2369**.
- [x] ~~Parcel-status value: new `REVERSAL_COMPLETED` enum vs. `reversal_completed_at` timestamp column?~~
      **Resolved: timestamp column.** `parcel_status` is not mutated; the audit trail is the
      `ParcelStatusHistory` row with `status_txt = {"status":"Cancellation reversal completed by WMS","batch_id":…}`.
- [ ] Does any existing OMS code reduce `quantity_allocated` at cancel-request time? (parent §3.5.1 "double-count
      risk" — confirm OMS is callback-only before relying on the cancel-side inventory restore.) **Still open** —
      this was never about the new handler (which writes no inventory) but about `cancelPosition`'s restore being
      the sole inventory mutation. Unverified.
