---
title: "Runbook: Unstick a Held Outbox Aggregate — FAILED_TERMINAL blocking a later event (WMS v2)"
type: runbook
status: active
version: "wms2-api (Java 21, Spring Boot 3.5.x, PostgreSQL)"
scope: "v2/wms2-api tenant DBs — outbox_message rows held behind a lower-id FAILED_TERMINAL sibling (SBDEV-2381 fail-closed cross-tick gate)"
owner: "nam.park@siteboss.net"
created: "2026-06-14"
updated: "2026-06-14"
last_verified: "2026-06-14"
verified_by: "Claude (Opus 4.8) — code-read of OutboxDispatchService / OutboxMessageRepository / OutboxMessage on wms2-api develop"
alert: "wms2.outbox.stuck_aggregate (intended gauge — see §8; until wired, detect via the §4 query). Symptom: OMS not receiving a parcel's PICKING_FINISHED / later status; parcel stalls; outbox_message has a FAILED_TERMINAL row with un-SENT higher-id siblings for the same aggregate"
severity: "SEV2 (degraded ops — WMS↔OMS status divergence for the affected order; no full outage)"
escalation: "WMS on-call → Nam Park (SBDEV-2381 owner); OMS-side root cause / stale-event contract → David Oppenheim (paired OMS ticket)"
related:
  - "[[SBDEV-2381-wms-parcel-status-out-of-order]]"
  - "[[wms2-resend-picking-finished-notification]]"
  - "[[wms2-oms-integration-map]]"
  - "[[wms2-scheduled-jobs-catalog]]"
tags:
  - runbook
  - wms2
  - outbox
  - oms-integration
  - dispatch-ordering
  - data-repair
---

# Runbook: Unstick a Held Outbox Aggregate (WMS v2, per tenant DB)

**Alert:** stuck-aggregate (intended metric not yet wired — §8) | **Severity:** SEV2
**Scope:** `v2/wms2-api` tenant DBs — `outbox_message` | **Version:** wms2-api develop
**Owner:** nam.park@siteboss.net | **Last verified:** 2026-06-14 (code-read of dispatcher + repo)

> **Mechanism (why an event gets stuck).** SBDEV-2381 added a **fail-closed cross-tick ordering gate** to the
> dispatcher's claim query (`OutboxMessageRepository.findAndClaimPending`, the `NOT EXISTS` clause at lines
> 38–44). A row is NOT claimable while **any lower-`id` sibling** for the same `(aggregate_type, aggregate_id)`
> is in `PENDING`, `FAILED_RETRY`, `IN_FLIGHT`, **or `FAILED_TERMINAL`**. Only `SENT` (delivered) or physical
> absence releases a sibling. So a STARTED event that lands in `FAILED_TERMINAL` **permanently holds** the
> later FINISHED for that customer order. This is **intentional** (decision 6 / R2 in the plan): holding a
> stuck FINISHED is preferred over leaking a "FINISHED-without-STARTED" that would regress the parcel in OMS.
> The escape hatch is operator action — this runbook. **Do not "fix" this by removing `FAILED_TERMINAL` from
> the gate; that reintroduces SBDEV-2381's 43% out-of-order inversion.**
>
> **How a row reaches `FAILED_TERMINAL`** (`OutboxDispatchService.isTerminal`, lines 200–202): OMS returns
> HTTP **400 / 404 / 422** (terminal on the *first* attempt), **or** `attempts >= app.outbox.dispatcher.max-attempts`
> (default **5**). Terminal rows are **never auto-deleted** (repo comment, `OutboxMessageRepository` line 72).

---

## 1. When to Use This Runbook

Use when an OMS parcel/order status is not advancing and the WMS outbox shows a held chain:

- OMS reports a missing/stale status for a customer order (e.g. parcel never reaches QA after picking), **and**
- `outbox_message` for that aggregate has a **`FAILED_TERMINAL`** row with one or more **higher-`id`** siblings still in `PENDING` / `FAILED_RETRY` (confirmed by §4).

**Do NOT use** for:
- A *dropped* (never-enqueued) PICKING_FINISHED — that is the double-`afterCommit` bug → use [[wms2-resend-picking-finished-notification]].
- A single FINISHED-only CO that never dispatches — that is **valid** (FINISHED is the lowest `id`, gate finds no lower sibling, it dispatches; R3 case a). Re-check §4: there must be a real lower-`id` blocker.

---

## 2. Severity & Impact

- **SEV2 — degraded ops, not an outage.** Only the affected aggregate(s) are stuck; the dispatcher keeps delivering every other order normally (every 15 s).
- **Impact:** OMS and WMS diverge for that order until cleared — parcel may stall in QA / show a stale status. Customer-facing only if the order is time-sensitive.
- **Blast radius:** scoped to one `(aggregate_type, aggregate_id)` per terminal row. A spike across many aggregates usually means an **OMS-side outage or bad deploy** (many first-attempt 4xx) — see §8.

---

## 3. First 5 Minutes — Triage

- [ ] Identify the **tenant** and **facility** (`tenant_name` / `facility_code`). The alert payload should carry them; the `outbox_message` table lives **in each tenant DB**.
- [ ] Connect **read-only first** to the correct **wms2 tenant DB** (4-char routing key = 2-char tenant + 2-char warehouse).
- [ ] Run the §4 diagnosis query to confirm there is a real `FAILED_TERMINAL` blocker holding higher-`id` siblings. If none → this is not the right runbook (see §1 "Do NOT use").
- [ ] Note the blocker's `process_type`, `attempts`, and the HTTP code embedded in `last_error` — these drive the §5 decision.

---

## 4. Diagnosis — Find the Cause

Run against the **WMS v2 tenant DB** (read-only).

**4.1 — Find every held aggregate (terminal blocker → held siblings):**

```sql
SELECT
    blk.aggregate_type,
    blk.aggregate_id,
    blk.id            AS blocking_id,
    blk.process_type  AS blocking_process,
    blk.attempts      AS blocking_attempts,
    LEFT(blk.last_error, 160) AS blocking_last_error,
    held.id           AS held_id,
    held.process_type AS held_process,
    held.status       AS held_status
FROM outbox_message blk
JOIN outbox_message held
  ON held.aggregate_type = blk.aggregate_type
 AND held.aggregate_id   = blk.aggregate_id
 AND held.id > blk.id
WHERE blk.status = 'FAILED_TERMINAL'
  AND held.status IN ('PENDING', 'FAILED_RETRY', 'IN_FLIGHT')
ORDER BY blk.aggregate_id, blk.id;
```

Each row = a terminal blocker (`blocking_id`) and an event it is holding (`held_id`). For
`aggregate_type = 'CUSTOMER_ORDER'`, `aggregate_id` is the `customerorder.id`.

**4.2 — Inspect the full chain for one aggregate** (order-of-`id` is the OMS delivery order):

```sql
SELECT id, process_type, status, attempts, next_attempt_at, sent_at,
       LEFT(last_error, 160) AS last_error
FROM outbox_message
WHERE aggregate_type = :agg_type   -- e.g. 'CUSTOMER_ORDER'
  AND aggregate_id   = :agg_id
ORDER BY id;
```

**4.3 — Read the HTTP code on the blocker** (decides re-drive vs mark-SENT):

| `last_error` shows | Meaning | Likely path |
|---|---|---|
| `HTTP 404` | OMS endpoint not found — wrong `destination_url` / sysprop, or OMS not deployed | **Re-drive** after the URL/deploy is fixed |
| `HTTP 400` / `HTTP 422` | OMS rejected the **payload** as invalid | **Mark-SENT** (re-sending the same body re-fails) **unless** OMS ships a fix → then re-drive |
| no code / `attempts>=5` exhausted | transient errors (timeout, 5xx, connect) that ran out of retries | **Re-drive** once OMS is healthy again |

---

## 5. Recovery Actions

**Decide first** (from §4.3 + OMS-side parcel state):

- Root cause resolved **and** OMS still needs this event → **§5.1 Re-drive**.
- Event is undeliverable (persistent 400/422) **and** OMS does not need it / has been reconciled → **§5.2 Mark-SENT**.
- Unsure whether OMS needs the event, or OMS state is ambiguous → **§6 Escalate** before touching anything.

> Both actions target the **blocker** row (`:blocking_id` from §4). Releasing it (to `SENT`, or to `PENDING`
> that then reaches `SENT`) lets the dispatcher claim the held siblings on its next tick (~15 s). Both UPDATEs
> bump the JPA `version` column (`@Version` optimistic lock on `OutboxMessage`) and run inside a transaction
> per runbook convention.

### 5.1 Re-drive — retry delivery of the terminal row

**Precondition (REQUIRED):** the terminal cause is fixed — OMS endpoint reachable, `destination_url`/sysprop corrected, or OMS deployed a handler for this `process_type`. **Re-driving an unchanged 400/422 payload just re-fails and re-holds the chain.**

```sql
BEGIN;

-- 1. confirm you have the intended terminal blocker
SELECT id, status, process_type, attempts, LEFT(last_error, 200) AS last_error
FROM outbox_message
WHERE id = :blocking_id
FOR UPDATE;

-- 2. reset it for immediate re-dispatch on the next tick
UPDATE outbox_message
SET status          = 'PENDING',
    attempts        = 0,
    next_attempt_at = NOW(),
    last_error      = NULL,
    modified_at     = NOW(),
    version         = version + 1
WHERE id = :blocking_id
  AND status = 'FAILED_TERMINAL';     -- guard: only act on a still-terminal row
-- expect: UPDATE 1

COMMIT;   -- ROLLBACK if the row count is not exactly 1
```

The dispatcher (every 15 s) will claim it; the idempotency key is unchanged so OMS de-dups a prior partial. If it succeeds → `SENT` → the held siblings flow automatically. If it goes terminal **again**, re-driving will not help — switch to §5.2 or §6.

### 5.2 Mark-SENT — abandon delivery, release the gate

**Precondition (REQUIRED):** confirmed that OMS does **not** need this event, **or** the OMS-side parcel/order has been manually reconciled. This **permanently abandons** delivery of the blocker event; it exists only to release the held siblings.

```sql
BEGIN;

SELECT id, status, process_type, LEFT(last_error, 200) AS last_error
FROM outbox_message
WHERE id = :blocking_id
FOR UPDATE;

UPDATE outbox_message
SET status      = 'SENT',
    sent_at     = NOW(),
    modified_at = NOW(),
    version     = version + 1,
    last_error  = COALESCE(last_error, '') ||
                  ' | MANUAL mark-SENT by <operator> 2026-MM-DD per runbook wms2-unstick-held-outbox-aggregate: <reason / OMS reconciliation ref>'
WHERE id = :blocking_id
  AND status = 'FAILED_TERMINAL';
-- expect: UPDATE 1

COMMIT;   -- ROLLBACK if the row count is not exactly 1
```

The marked-`SENT` row becomes eligible for the normal 7-day `SENT` retention cleanup — that is expected.

---

## 6. Escalation

- **WMS:** on-call engineer → **Nam Park** (SBDEV-2381 owner) for any ambiguity on which path to take.
- **OMS:** if the blocker is a persistent **400/422** for a valid event, the root cause is an OMS contract/handler issue — raise with **David Oppenheim** (the paired OMS stale-event ticket, SBDEV-2381 §10). Do **not** mark-SENT a needed event without OMS reconciliation.
- **Systemic:** if §4.1 returns many aggregates at once, treat it as an OMS incident (outage / bad deploy producing first-attempt 4xx), not per-row repair — see §8.

---

## 7. Verification — Confirm Resolved

1. **No blocker remains** for the aggregate — re-run §4.1 (or §4.2): there should be **0** `FAILED_TERMINAL` rows holding siblings for that `aggregate_id`.
2. **Held chain drains** — within ~15–30 s (1–2 dispatcher ticks) the previously held rows move `PENDING → IN_FLIGHT → SENT`:
   ```sql
   SELECT id, process_type, status, sent_at
   FROM outbox_message
   WHERE aggregate_type = :agg_type AND aggregate_id = :agg_id
   ORDER BY id;
   ```
   All should reach `SENT` (and, if re-driven, the blocker too).
3. **OMS reflects the correct final state** — confirm the parcel/order status in OMS (coordinate with OMS, same as [[wms2-resend-picking-finished-notification]] §7).
4. **Alert clears** (once the stuck-aggregate metric is wired — §8).

---

## 8. Post-incident

- **Wire the alert (paired prerequisite — SBDEV-2381 Prereq #8).** This runbook assumes a per-tenant gauge,
  `wms2.outbox.stuck_aggregate` (+ `…oldest_age_seconds`), that counts aggregates with a `FAILED_TERMINAL` row
  holding higher-`id` un-`SENT` siblings (the §4.1 shape), tagged `tenant`+`facility`. **Implementation is
  planned in [[260614-outbox-stuck-aggregate-metric]]** (piggybacks the dispatcher loop, sysprop-gated default
  OFF). Until that plan ships and the alert is enabled, run the §4.1 query on a schedule as interim detection.
  The alert must carry **tenant + facility** so the operator knows which DB to open, and **must aggregate
  `max by (tenant, facility)`** (drop `instance`) — only the active dispatcher replica exports real rows and a
  just-demoted replica can export a stale row for ≤1 tick, so `sum`/`count` would flap on lock migration. Pair
  it with the existing dispatcher-liveness signal (`wms2.outbox.tick_duration`): this gauge is only as fresh as
  the dispatcher's last tick.
- **Bulk events.** When an OMS outage stuck many aggregates, after the root cause is fixed you may re-drive in
  bulk — the §5.1 `UPDATE` **without** the `id` filter, scoped by `status = 'FAILED_TERMINAL'` and a
  `modified_at` window — but only once OMS is confirmed healthy, and review the matched set first.
- **Do not relitigate the design.** Fail-closed (`FAILED_TERMINAL` in the gate) is the intended SBDEV-2381
  trade. Removing it to "auto-unstick" reintroduces the out-of-order regression. Record recurring terminal
  `process_type`s and push the fix to the OMS contract instead.

---

## 9. Related Docs

- [[SBDEV-2381-wms-parcel-status-out-of-order]] — the plan that introduced the fail-closed gate (§9 R2, §10 decisions 6–7); this runbook is its §10 open-question deliverable.
- [[wms2-resend-picking-finished-notification]] — sibling runbook for a *dropped* (never-enqueued) notification (different failure mode).
- [[wms2-oms-integration-map]] — WMS→OMS notification path, outbox dispatcher.
- [[wms2-scheduled-jobs-catalog]] — `OutboxDispatcherJob` (every 15 s, advisory lock `100008L`, batch 10, max-attempts 5, retention 7 d).

**Code anchors (re-verify if these move):** `repo/jpa/OutboxMessageRepository.java` `findAndClaimPending` gate (lines 38–44), retention comment (line 72) · `service/job/OutboxDispatchService.java` `dispatchOne` (130–167), `isTerminal` (200–202) · `model/OutboxMessage.java` `Status` enum (line 38), `@Version` (line 88) · `application.properties` `app.cron.outbox-dispatcher` / `max-attempts` (113–116).
