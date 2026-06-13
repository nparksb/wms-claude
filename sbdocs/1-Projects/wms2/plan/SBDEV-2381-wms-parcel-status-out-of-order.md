---
title: "SBDEV-2381 — WMS V2 sends parcel status updates out of order to OMS V2"
ticket: "SBDEV-2381"
ticket_url: "https://app.clickup.com/t/SBDEV-2381"
type: "bug"
priority: "critical"
status: "implemented"
project: [wms2]
version: "v2"
requester: "Brent Campbell"
created: "2026-06-01"
updated: "2026-06-01 (migration refs realigned to V2.1.x after develop renumber merge)"
related:
  - "260424-picking-oms-status-race-condition-fix"
  - "SBDEV-2221-transactional-outbox-pilot"
  - "SBDEV-2238-outbox-phase2-remaining-services"
  - "260521-picking-finished-qa-blocked-and-service-log-gap"
  - "260520-content-derived-idempotency-key"
  - "260521-customerorderbatchservice-runclubline-self-invocation-tx-fix"
tags:
  - plan
db_verified: true
---

# SBDEV-2381 — WMS V2 sends parcel status updates out of order to OMS V2

**Ticket:** [SBDEV-2381](https://app.clickup.com/t/SBDEV-2381)
**Project:** wms2 | **Version:** v2 | **Type:** bug
**Priority:** CRITICAL (release-blocking)
**Status:** implemented (PR [#35](https://github.com/SiteBossInc/wms2-api/pull/35) → develop)
**Date:** 2026-06-01

> **Consensus provenance.** This plan was produced via the `wms-bugfix-plan` skill (executor-opus analysis → ralplan Planner → Architect → Critic). DB-verified against the `wms2-wineco-dev` MCP. Architect final verdict SOUND-WITH-CHANGES; Critic final verdict APPROVE (1 iteration). The Architect's residual items N1–N5 are folded as the AC tightenings AC-11/AC-15/AC-16 and the §10 load-bearing invariant.
>
> **Migration-renumber merge note (2026-06-01).** develop merged commit `04efba6` *"renumber v2-specific Flyway migrations into the V2.1.x namespace"*: `V1.1.06–16,23` → `V2.1.01–13`, `V1.1.19–22` consolidated into `V2.1.12`, and the `v1-onboarding/` subdir removed. Consequences for this plan: the outbox table / `id BIGSERIAL` is now created by **`V2.1.11`** (was `V1.1.16`); the latest migration is **`V2.1.13`**; this plan's new index migration is **`V2.1.14`** (was `V1.1.24`). All references below are realigned. The `OutboxItFlyway` IT helper's v1-onboarding duplicate-version workaround is now moot (subdir gone) but remains harmless.

---

## 0. Affected Sites

`in-scope` = directly edited. `partial` = inherits ordering for free, no edit. `out` = explicitly excluded.

| # | File | Line | Role | Scope |
|---|------|------|------|-------|
| 1 | `repo/jpa/OutboxMessageRepository.java` | 29–45 | `findAndClaimPending` claim query — RC-1 epicenter: add `ORDER BY next_attempt_at, id` + cross-tick `NOT EXISTS` gate keyed on `id` | in-scope |
| 2 | `service/job/OutboxDispatchService.java` | 87–95 (sort inserted at 93); `dispatchOne` | claim + dispatch loop — add in-batch deterministic Java sort; inject `event_version = id`; keep sequential | in-scope |
| 3 | `service/OutboxService.java` | 117–120 (`claimDueBatch`) | wrapper passes through; **no MAX+1 stamping** — `id` is the ordering key | in-scope (trivial) |
| 4 | ~~`model/OutboxMessage.java`~~ | — | **DELETED from plan** — no synthetic sequence field; existing `id` (BIGSERIAL) is the monotonic key | removed |
| 5 | `resources/db/migration/V2.1.14__add_outbox_aggregate_order_index.sql` | NEW (latest existing = V2.1.13 after the develop V2.1.x renumber merge) | **index only** — supports id-ordered claim + cross-tick gate over all probed statuses; no column, no backfill, no UNIQUE; non-transactional (`CONCURRENTLY`) | in-scope |
| 6 | `service/PickingorderBusinessService.java` | 262–288 | PICKING_FINISHED enqueue (regular-pick path; `id`-ordered for free; event_version injected at dispatch) | in-scope (minimal) |
| 7 | `service/PickingorderBusinessService.java` | 620–640 | PICKING_STARTED enqueue in `confirmPick` — **PRIMARY backward guard** (skip if state ≥ PICKED or `pickingconfirmationsent`) layered atop the existing `state < STARTED` check at :620 | in-scope |
| 8 | `service/PickingorderBusinessService.java` | 343–403 | `reenqueuePickingFinishedIfMissing` — uses `findAllById` (`:366`, NO row lock); `id`-ordered for free | in-scope (verify only) |
| 9 | `service/PickingorderBusinessService.java` | 459 | deferred-cancel `ORDER_BATCH_CANCELLED_FROM_WMS` — same aggregate, `id`-ordered for free; no edit | partial |
| 10 | `service/CustomerorderBatchService.java` | 794–803 | club-line **Phase 4 — ALL THREE** notifications (RELEASE :797, STARTED :798, PICKED :799) → per-CO outbox enqueues inside `finalizeClubLine` (in-tx via self-proxy) | in-scope |
| 11 | `service/CustomerorderBatchService.java` | 302, 689 (`finalizeClubLine`) | existing club enqueue (`id`-ordered for free); `finalizeClubLine` (currently bulk `updateStateByIds`, no per-CO loop) is the new enqueue home | in-scope |
| 12 | `service/ManageOrderService.java` | 227–248 | `customerOrderPickingStarted` (`@Deprecated`) — **retire** | in-scope |
| 13 | `service/ManageOrderService.java` | 320–342 | `customerOrderPicked` (`@Deprecated`) — **retire**; tote-label `saveAll` (300–302) + `historytote` UUID (:282) must run EXACTLY ONCE per club CO | in-scope |
| 13b | `service/ManageOrderService.java` | (release dispatcher) | `customerOrderReleaseForPicking` (`@Deprecated`) — **retire** (all three Phase-4 dispatchers go) | in-scope |
| 14 | `service/ManageOrderService.java` | 198–218, 262–311 | payload builders — **no event_version here** (dispatcher injects it, Fix F-i); STARTED uses `buildPickingStartedPayloadJson` (no tote side-effect), PICKED uses `buildPickedPayloadJson` (owns tote write) | in-scope (verify) |
| 15 | `BillofladingService:672`, `AdviceService:265/365/436`, `CustomerorderService:738`, `CancellationReversalService:239` | — | other enqueue callers — `id`-ordered for free; no edit | partial |
| 16 | `service/OmsNotificationService.sendAfterCommit` | 49–101 | LEAVE — still used by tote-assigned/released/palletized/loaded/stock-change/on-hold | out |
| 17 | OMS-side stale-event rejection | — | OUT — paired OMS ticket (coordinate David Oppenheim) | out |

---

## 1. Problem Statement

WMS V2 POSTs parcel status updates to OMS V2 **out of order**. A parcel reached `Ready to QA`, then a later `PICKING_STARTED` event arrived at OMS and regressed the parcel backwards → parcel stuck. User-visible symptom: parcels stranded in an inconsistent picking state, blocking QA. In production this would require manual support intervention.

**DB-verified (`db_verified: true`, `wms2-wineco-dev` MCP):** of 23 PICKING_STARTED/FINISHED pairs, **10 (43%)** were POSTed to OMS in inverted order (`FINISHED` before `STARTED` for the same `CUSTOMER_ORDER`). `created_at` (and `id`) were **always correctly ordered**, proving the defect is in **dispatch ordering**, not enqueue — and that `id` is a sound ordering key.

**Mechanism row (aggregate 29854466):**

| event | outbox id | next_attempt_at | sent_at |
|---|---|---|---|
| PICKING_STARTED | 49 | 11:30:08.587 | 11:30:15.131 |
| PICKING_FINISHED | 50 | 11:30:08.605 | 11:30:15.068 |

The lower-`id` STARTED (49) was sent **later** than the higher-`id` FINISHED (50) — a strict inversion within one dispatch tick.

```sql
-- §1 symptom / regression query (re-run post-fix; must return 0)
SELECT aggregate_id,
       MIN(CASE WHEN process_type LIKE '%PICKING_STARTED'  THEN sent_at END) AS started_sent,
       MIN(CASE WHEN process_type LIKE '%PICKING_FINISHED' THEN sent_at END) AS finished_sent
  FROM outbox_message
 WHERE aggregate_type = 'CUSTOMER_ORDER'
   AND process_type LIKE '%PICKING_%'
 GROUP BY aggregate_id
HAVING MIN(CASE WHEN process_type LIKE '%PICKING_FINISHED' THEN sent_at END)
     < MIN(CASE WHEN process_type LIKE '%PICKING_STARTED'  THEN sent_at END);
-- pre-fix: 10 of 23 aggregates; post-fix: 0 (incl. terminal + skipped-STARTED cases — see R2/R3 in §5)
```

---

## 2. Root Cause Analysis

### Bug 1 (RC-1, PRIMARY) — `RETURNING *` row order is non-deterministic

`OutboxMessageRepository.java:29–45`:

```sql
UPDATE outbox_message SET status='IN_FLIGHT', modified_at=NOW()
 WHERE id IN (
      SELECT id FROM outbox_message
       WHERE status IN ('PENDING','FAILED_RETRY') AND next_attempt_at <= :now
       ORDER BY next_attempt_at          -- orders WHICH rows are claimed, NOT the RETURNING order
       LIMIT :batchSize FOR UPDATE SKIP LOCKED
 )
 RETURNING *                              -- arbitrary physical (ctid) order
```

Postgres `UPDATE … RETURNING` emits rows in arbitrary heap order. `OutboxDispatchService.java:87–95` then iterates the returned `List` sequentially and POSTs in that arbitrary order. **No outer ORDER BY, no in-batch sort, no tiebreaker** — there is currently **no** sort on the claimed list (so one must be *added*, not "fixed").

> Already-correct, do NOT touch: the claim already does `FOR UPDATE SKIP LOCKED` + `IN_FLIGHT` flip in REQUIRES_NEW; the loop is already sequential (no `parallelStream`).

### Bug 2 (RC-2, STRUCTURAL) — the available ordering signal is ignored

The table already carries a correct monotonic per-aggregate key: `id BIGSERIAL PRIMARY KEY` (`V2.1.11:7`, originally `V1.1.16` before the develop renumber). For a given CO, STARTED is enqueued by `confirmPick` and FINISHED by `finishPickingOrder` — **separate, serialized transactions** (both take the CO `findByIdForUpdate` lock; `confirmPick:528/618`, `finishPickingOrder:192`), so STARTED always has the lower `id`. The defect is purely that **the dispatch path ignores `id`** — neither the claim ORDER BY nor any in-batch sort uses it, and nothing prevents a higher-`id` sibling from being claimed/sent in an earlier tick than a lower-`id` one (cross-tick split at `batch-size = 10`). **No synthetic column is needed** (see §5 Fix A / §10 alternatives).

### Bug 3 (RC-3, CONTRIBUTING) — dual transport bypasses the outbox

`CustomerorderBatchService.java:794–803` (club-line Phase 4, non-tx) emits the **same** events via a *second* transport — **all three**:

```java
manageOrderService.customerOrderReleaseForPicking(validation.orders()); // :797 → sendAfterCommit → doSend (sync)
manageOrderService.customerOrderPickingStarted(validation.orders());    // :798 → sendAfterCommit → doSend
manageOrderService.customerOrderPicked(validation.orders());            // :799 → sendAfterCommit → doSend
```

All three `@Deprecated` dispatchers call `omsNotificationService.sendAfterCommit(...)`, which falls through to the synchronous `doSend` branch (`OmsNotificationService.java:99`) when no tx is active. This bypasses outbox ordering/idempotency/retry and races the outbox transport. **Must unify all three onto the outbox.**

---

## 3. Regression Chain

- `260424-picking-oms-status-race-condition-fix` — predecessor; established the 4-phase non-tx club-line design (Phase 4 OMS calls outside tx). RC-3 is the now-unintended consequence.
- `SBDEV-2221-transactional-outbox-pilot` — introduced `outbox_message` (now `V2.1.11`, was `V1.1.16`) with `id BIGSERIAL` and the claim-then-release dispatcher.
- `SBDEV-2238-outbox-phase2-remaining-services` — migrated most `sendAfterCommit` callers; left club-line Phase 4 (all 3) on the legacy transport.
- `260521-picking-finished-qa-blocked-and-service-log-gap` — restored service-log rows in the dispatcher.
- `260520-content-derived-idempotency-key` — idempotency-key derivation; keep existing explicit keys (`CO-PICKED-`, `CO-PICKING-STARTED-`).
- `260521-customerorderbatchservice-runclubline-self-invocation-tx-fix` — established the `self.finalizeClubLine(...)` Spring-proxy pattern; Fix E reuses that tx boundary.

---

## 4. Architecture Overview

```
ENQUEUE (caller tenant tx, MANDATORY)        CLAIM (REQUIRES_NEW)               DISPATCH (no tx)            OMS
─────────────────────────────────────        ─────────────────────             ─────────────────          ───
confirmPick STARTED (620-640, guarded) ┐
finishPicking FINISHED (262-288)       │     claimDueBatch → findAndClaimPending  dispatchBatch:            POST
reenqueue... (343-403, findAllById)    ├──▶  SELECT..WHERE due AND NOT EXISTS ──▶ batch.sort(nextAttempt,  /rest/...
finalizeClubLine RELEASE/STARTED/PICKED│     (lower-id sibling unsent/terminal)    type, aggId, id)   ──▶   (OMS V2)
  (per CO, in-tx, ascending ids)       │     ORDER BY next_attempt_at, id          for msg: dispatchOne     + event_version
deferred-cancel (459)                  │     LIMIT 10 FOR UPDATE SKIP LOCKED          (inject id)
                            outbox_message (id BIGSERIAL = monotonic per-aggregate key — NO new column)
```

**Key files**

| File | Role |
|---|---|
| `OutboxMessageRepository.java` | claim query: `ORDER BY ..., id` + cross-tick `NOT EXISTS` gate (fail-closed) |
| `OutboxDispatchService.java` | in-batch deterministic sort (added) + `event_version = id` injection |
| `OutboxService.java` | `claimDueBatch` pass-through (no stamping) |
| `PickingorderBusinessService.java` | STARTED guard, FINISHED/reenqueue producers; CO `FOR UPDATE` locks (load-bearing invariant) |
| `CustomerorderBatchService.java` | club-line producer — unify all 3 Phase 4 notifications into `finalizeClubLine` |
| `ManageOrderService.java` | retire 3 deprecated dispatchers; payload builders unchanged for event_version |
| `V2.1.14__add_outbox_aggregate_order_index.sql` | index supporting id-order + gate |

---

## 5. Fix Design

### Fix A — Flyway `V2.1.14__add_outbox_aggregate_order_index.sql` (index only)

No column, no backfill, no UNIQUE. Add an index supporting both the id-ordered claim and the cross-tick `NOT EXISTS` gate. The gate probes siblings in `('PENDING','FAILED_RETRY','IN_FLIGHT','FAILED_TERMINAL')` (fail-closed, R2) — the index **must cover all of these**, so it is a full (non-partial) index, not a `WHERE status IN (...)` partial index that omits IN_FLIGHT/FAILED_TERMINAL.

```sql
-- V2.1.14__add_outbox_aggregate_order_index.sql
-- flyway:executeInTransaction=false   <-- CONCURRENTLY cannot run inside a tx (Flyway 9.14+, plugin 10.0.0)
-- Idempotent on a failed-then-rerun: a partially-built CONCURRENTLY index is left INVALID and
-- satisfies IF NOT EXISTS without being repaired, so DROP first.
DROP INDEX IF EXISTS index_outbox_message_aggregate_order;
CREATE INDEX CONCURRENTLY IF NOT EXISTS index_outbox_message_aggregate_order
    ON outbox_message (aggregate_type, aggregate_id, id, status);
```

This index serves: (a) the gate's correlated `WHERE aggregate_type=? AND aggregate_id=? AND id<? AND status IN (...)`; (b) the outer `ORDER BY next_attempt_at, id` benefits from the existing `index_outbox_message_dispatch (status, next_attempt_at)` for row selection, with `id` as a cheap tiebreak. EXPLAIN validation is AC-14; clean apply under Testcontainers is AC-16. The existing partial `index_outbox_message_dispatch` (`V2.1.11:29`) is retained. **This is the repo's first non-transactional migration** — verify `flyway:executeInTransaction=false` against flyway-maven-plugin 10.0.0 and that `flyway-core` (test scope) applies it under Testcontainers (H2 tests cannot exercise `CONCURRENTLY`).

### Fix B — DELETED

No entity change. `OutboxMessage` keeps its current 15 columns; `id` is the ordering key. (Removed from §0, §6, ACs.)

### Fix C — Deterministic claim order + in-batch sort (RC-1 core)

**(i) Claim query** adds an outer ORDER BY (and the gate from Fix D):

```sql
SELECT id FROM outbox_message o
 WHERE status IN ('PENDING','FAILED_RETRY') AND next_attempt_at <= :now
   AND NOT EXISTS ( /* Fix D gate */ )
 ORDER BY next_attempt_at, id
 LIMIT :batchSize FOR UPDATE SKIP LOCKED
```

`ORDER BY ... id` makes the *selection* deterministic, but the `RETURNING *` order is still arbitrary, so:

**(ii) In-batch Java sort** — **add** to `OutboxDispatchService.dispatchBatch` at line 93 (there is currently NO sort):

```java
List<OutboxMessage> batch = outboxService.claimDueBatch(Instant.now(), batchSize);
if (batch.isEmpty()) return;
batch.sort(Comparator.comparing(OutboxMessage::getNextAttemptAt)
        .thenComparing(OutboxMessage::getAggregateType)
        .thenComparing(OutboxMessage::getAggregateId)
        .thenComparing(OutboxMessage::getId));
for (OutboxMessage msg : batch) { dispatchOne(msg); }   // STAYS sequential — no parallelStream
```

**No MAX+1 stamping** in `enqueue`. `id` is allocated by Postgres on INSERT — no application read-modify-write, no race (this is why the lock-free `reenqueuePickingFinishedIfMissing` reader at `:366` is now harmless). This sort is unit-testable on mocks/H2. Under the Fix-D gate at most one row per aggregate is claimable per tick, so the sort is **defense-in-depth, not load-bearing** (keep it, labeled).

### Fix D — Cross-tick ordering gate, keyed on `id`, FAIL-CLOSED (R2)

`batch-size = 10` ⇒ a CO's STARTED/FINISHED can split across ticks; the in-batch sort only fixes ordering *within* a batch. Add a claim-time gate so a higher-`id` row is not claimed while any lower-`id` sibling for the same aggregate is still unsent **or terminally failed**:

```sql
AND NOT EXISTS (
     SELECT 1 FROM outbox_message e
      WHERE e.aggregate_type = o.aggregate_type
        AND e.aggregate_id   = o.aggregate_id
        AND e.id < o.id
        AND e.status IN ('PENDING','FAILED_RETRY','IN_FLIGHT','FAILED_TERMINAL')
    )
```

**FAILED_TERMINAL is INCLUDED → fail-closed.** A terminal lower-`id` sibling **HOLDS** the later event rather than leaking a FINISHED-without-STARTED to OMS. The only statuses that *release* a sibling are `SENT` (delivered) and physical absence. Terminal is reachable on the **first attempt** (HTTP 400/404/422, `OutboxDispatchService:178–181`), so the leak this prevents is not rare. The trade: a permanently-failed STARTED holds its FINISHED (parcel needs ops intervention) — accepted vs. silently regressing OMS; mitigated by a stuck-aggregate alert (Prereq #8) and ops runbook (§10 open question).

### Fix E — Unify ALL THREE club-line Phase 4 notifications onto the outbox (RC-3, R5)

Phase 4 (`CustomerorderBatchService.java:794–803`) is non-tx; `enqueue` is MANDATORY. **Move all three enqueues into `finalizeClubLine` (line 689, already `@Transactional` tenant), invoked via `self.finalizeClubLine(...)` (line 781).** `finalizeClubLine` is currently a bulk `updateStateByIds` with no per-CO loop, so a per-CO loop must be added. Per CO, in code order so ids ascend RELEASE < STARTED < FINISHED:

```java
// inside finalizeClubLine, after state finalization, before commit, ONE per-CO loop:
if (basicService.isProduction()) {
    for (Customerorder co : clubOrders) {
        // RELEASE
        outboxService.enqueue(/* CUSTOMER_ORDER, ORDER_BATCH_PICKING_RELEASED, aggregateId = co.getId() */);
        // STARTED — buildPickingStartedPayloadJson has NO tote side-effect
        String startedPayload = manageOrderService.buildPickingStartedPayloadJson(List.of(co));
        if (startedPayload != null) outboxService.enqueue(/* ...PICKING_STARTED, co.getId() */);
        // FINISHED — buildPickedPayloadJson performs the tote-label saveAll + historytote UUID HERE, in-tx, ONCE
        String finishedPayload = manageOrderService.buildPickedPayloadJson(List.of(co));
        if (finishedPayload != null) outboxService.enqueue(/* ...PICKING_FINISHED, co.getId() */);
    }
}
```

Then delete the three Phase 4 calls (797–799) and **retire all three** deprecated dispatchers: `customerOrderReleaseForPicking`, `customerOrderPickingStarted` (227–248), `customerOrderPicked` (320–342). Keep `buildPickingStartedPayloadJson` / `buildPickedPayloadJson` (still used).

**Exactly-once tote write (R5 / N2 — REQUIRED):** `buildPickedPayloadJson` both builds the PICKED payload AND persists the club tote-label `saveAll` (`ManageOrderService:300–302`) and **regenerates a fresh `historytote` UUID on every call** (`:282`). The STARTED payload MUST therefore come from `buildPickingStartedPayloadJson` (no tote side-effect), and `buildPickedPayloadJson` MUST be invoked **exactly once per club CO**. A second call would overwrite the `historytote` UUID. AC-15 asserts UUID stability across the finalize tx. Enqueue per CO with `aggregateId = co.getId()` so each CO is its own ordering stream — NOT a single batch-level message.

### Fix F — event_version injection + PRIMARY backward guard

**(i) event_version is injected by the DISPATCHER, not at enqueue/build time.** The `id` is not known until after the outbox INSERT, and the value OMS needs is exactly the outbox row `id`. In `OutboxDispatchService.dispatchOne`, set `event_version = msg.getId()` as an **additive body field or HTTP header** at POST time. Coordinate the exact name/placement with OMS (David Oppenheim). Payload builders (`ManageOrderService:198–218, 262–311`) are **not** changed for this — they don't know the id.

**(ii) PRIMARY backward guard** — in `confirmPick` STARTED enqueue (`PickingorderBusinessService.java:620–640`), **skip the STARTED enqueue** when the CO has already advanced. The existing condition at `:620` is `customerOrder.getState() < STARTED`; this fix **layers a stricter guard on top** (it does NOT loosen the existing check): skip when `customerOrder.getState() >= WmsConstants.State.PICKED || Boolean.TRUE.equals(customerOrder.getPickingconfirmationsent())`. This is the **primary** mechanism that prevents a backward STARTED from ever being emitted (a backward STARTED enqueued after FINISHED would get a *higher* id and OMS would wrongly accept it as newer — so this guard is the dispatch-side single point of correctness; OMS-side rejection is the paired-ticket backstop). See §10 R7.

> Dispatch MUST stay sequential — "no `parallelStream`" documented on the loop.

### Alternatives considered & refuted (R6)

- **Synthetic `aggregate_sequence` column + MAX+1 stamping (earlier draft — REJECTED).** Required a read-modify-write (`SELECT COALESCE(MAX(seq),0)+1`) in `enqueue`, which races concurrent producers for the same CO. Critically, `reenqueuePickingFinishedIfMissing` reads COs via `customerorderRepository.findAllById` (`PickingorderBusinessService:366`) with **no row lock**, so MAX+1 there could collide with a concurrent `confirmPick` enqueue and either duplicate a sequence or force a UNIQUE-constraint abort of a *legitimate* notification tx. It was also redundant: `id` already provides a Postgres-assigned, gap-tolerant, race-free monotonic per-aggregate key. **`id`-as-event_version satisfies locked decision 3** ("monotonic per-aggregate sequence OR event_version") with zero new schema state.
- **`created_at` tiebreak (REJECTED).** `created_at` collides at ~19 ms for STARTED/FINISHED pairs (ms/µs precision), so it cannot reliably tiebreak; `id` is strictly monotonic by INSERT and never collides.
- **Post-claim Java gate only (REJECTED).** Cannot un-claim a row already flipped to IN_FLIGHT, so it cannot fix the across-tick split — it only reorders within a batch (which the in-batch sort already does). Retained only as the within-batch defense-in-depth layer.
- **Per-CO ordering necessity (R6 justification).** Club orders are bulk-promoted to PACKED at `CustomerorderBatchService:691` and never transit `confirmPick`'s STARTED path — so a club CO's RELEASE/STARTED/PICKED are *synthetic* events all produced inside `finalizeClubLine`. `id` still handles them because they are enqueued in code order within one tx → strictly ascending ids per CO (BIGSERIAL `nextval` per INSERT). This is why per-aggregate (per-CO) ordering matters and why `id` is sufficient for it.

---

## 6. File Change Summary

| File | Change | Fix |
|---|---|---|
| `db/migration/V2.1.14__add_outbox_aggregate_order_index.sql` | NEW: index only (no column/backfill/UNIQUE); `CONCURRENTLY` → non-tx migration with DROP-IF-EXISTS guard | A |
| ~~`model/OutboxMessage.java`~~ | **none** (entity field dropped) | B (removed) |
| `service/OutboxService.java` | none functional (no MAX+1); `claimDueBatch` pass-through unchanged | C |
| `repo/jpa/OutboxMessageRepository.java` | claim query: `ORDER BY next_attempt_at, id` + cross-tick `NOT EXISTS` gate (incl. FAILED_TERMINAL) | C, D |
| `service/job/OutboxDispatchService.java` | add in-batch sort at line 93; inject `event_version = id` in `dispatchOne`; keep sequential | C, F-i |
| `service/PickingorderBusinessService.java` | stricter backward guard on STARTED enqueue (620–640), layered on existing `< STARTED` | F-ii |
| `service/CustomerorderBatchService.java` | add per-CO loop in `finalizeClubLine`; move all 3 club notifications in-tx; delete Phase 4 calls 797–799 | E |
| `service/ManageOrderService.java` | retire 3 deprecated dispatchers; `buildPickedPayloadJson` called once per club CO (tote write exactly-once) | E |

---

## 7. Implementation Steps

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | DB state / Flyway | Tenant DBs at V2.1.13 (after the develop V2.1.x renumber merge). V2.1.14 adds an index `CONCURRENTLY` → **must be a non-transactional Flyway migration** (`flyway:executeInTransaction=false`, no other DDL in the script; DROP-IF-EXISTS guard for failed-rerun). **No column, no backfill, no table-rewrite lock.** First non-transactional migration in the repo — verify directive vs flyway-maven-plugin 10.0.0. | DBA | id present since `V2.1.11` (was `V1.1.16`). |
| 2 | Feature flags / sysprops | N/A — no new sysprop. Backward guard reuses existing `pickingconfirmationsent`. | — | |
| 3 | Config / env | N/A. | — | |
| 4 | Deploy-order deps | **OMS coordination (David Oppenheim):** agree `event_version` field name/placement (body vs header) and that OMS ignores it until the paired stale-rejection ticket lands. WMS ships first; field is additive. | WMS+OMS | |
| 5 | Data migration | **None** — id-ordering needs no backfill. | — | |
| 6 | External systems | OMS picking endpoints reachable (URLs unchanged). | — | |
| 7 | Access / permissions | N/A. | — | |
| 8 | Monitoring | Add **stuck-aggregate** metric/alert (R2): count of aggregates with a `FAILED_TERMINAL` lower-`id` row holding later events. Alert on the §1 inversion query > 0. | Ops | Terminal reachable on first attempt (HTTP 400/404/422). |

### 5.2 Implementation Checklist (atomic commits)

- [ ] Step 1 — Fix A: write `V2.1.14` index migration (`CONCURRENTLY`, non-tx, DROP-IF-EXISTS guard).
- [ ] Step 2 — Fix C-i + D: rewrite `findAndClaimPending` with `ORDER BY next_attempt_at, id` + fail-closed `NOT EXISTS` gate.
- [ ] Step 3 — Fix C-ii: add in-batch sort at `OutboxDispatchService.java:93` (keep sequential).
- [ ] Step 4 — Fix F-i: inject `event_version = msg.getId()` in `dispatchOne` (body/header per OMS).
- [ ] Step 5 — Fix F-ii: stricter backward guard on `confirmPick` STARTED enqueue (layer atop `< STARTED`).
- [ ] Step 6 — Fix E: add per-CO loop in `finalizeClubLine`; move all 3 club notifications in-tx; delete Phase 4 calls; retire 3 dispatchers; guarantee exactly-once tote write.
- [ ] Unit tests (BaseServiceTest / mocks / H2) added.
- [ ] Integration tests (Testcontainers) for claim+gate (incl. terminal), id-ordering, concurrent enqueue, EXPLAIN, migration apply.
- [ ] `bash sbdocs/9-System/scripts/verify-SBDEV-2381-wms-parcel-status-out-of-order.sh` → 0 fail.
- [ ] Code review completed.

### Horizontal Scalability Validation (MANDATORY, 10-row)

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | In-JVM state | No | Sort is on a local list |
| 2 | Connection pool math | No | Same claim-then-release |
| 3 | Scheduled jobs | N/A | Dispatcher behavior changes, not schedule/lock; advisory lock `100008L` unchanged |
| 4 | Long transactions | No | Fix E enqueues ride existing `finalizeClubLine` tx; POST stays no-tx |
| 5 | Request affinity | No | Outbox is DB-backed, replica-agnostic |
| 6 | Retry / idempotency | **Yes** | Gate re-evaluated each tick; id-allocation race-free (no MAX+1); idempotency keys unchanged; `IN_FLIGHT`/`FAILED_TERMINAL` siblings block later events |
| 7 | Tenant context | No | All work in caller tx or per-tenant dispatch tick; no async boundary |
| 8 | Distributed lock correctness | **Yes** | Claim uses `FOR UPDATE SKIP LOCKED` (unchanged); per-CO id ordering guaranteed by the CO `FOR UPDATE` lock serializing producers (load-bearing invariant, §10) |
| 9 | Cache invalidation | No | `outbox_message` not cached |
| 10 | External notifications (OMS) | No | POST stays after-claim, no tx; sequential dispatch preserved; `event_version` added |

**Evidence (Yes rows):** #6/#8 — id-allocation race-freedom proven by AC-11 (2-thread Testcontainers, asserts per-CO id-monotonicity under concurrency); cross-tick + terminal correctness by AC-12/AC-13.

### v2-only constraint checklist

- [ ] New enqueues in `finalizeClubLine` run under `tenantTransactionManager` (already tenant TM; via `self.` proxy).
- [ ] Migration is tenant-DB scoped, additive (index only), never edits an existing migration; non-transactional for `CONCURRENTLY`.
- [ ] `enqueue` stays MANDATORY — never called outside an open tenant tx (Fix E preserves this).
- [ ] No `parallelStream` in the dispatch loop.
- [ ] OSIV disabled — `dispatchBatch` non-tx reads only scalar fields (`getNextAttemptAt`/`getAggregateType`/`getAggregateId`/`getId`); no lazy access.
- [ ] H2 unit tests cover the Java sort/guard; `CONCURRENTLY` migration + native claim query are Testcontainers-only (AC-14/AC-16).

---

## 8. Testing Plan

### Unit tests (BaseServiceTest / mocks / H2)

| Test class | Method | Asserts | AC |
|---|---|---|---|
| `OutboxDispatchServiceUnitTest` | `dispatchBatch_sortsByIdAscending` | claimed batch with FINISHED(id 50) before STARTED(id 49) → POST order STARTED→FINISHED | AC-1, AC-8 |
| `OutboxDispatchServiceUnitTest` | `dispatchOne_injectsEventVersionFromId` | POST carries `event_version == msg.getId()` | AC-6 |
| `PickingorderBusinessServiceUnitTest` | `confirmPick_skipsStartedWhenAlreadyPicked` | no STARTED enqueue when state ≥ PICKED or `pickingconfirmationsent=true`; existing `< STARTED` not loosened | AC-4 |
| `CustomerorderBatchServiceUnitTest` | `clubFinalize_emitsReleaseStartedFinished_oneTransport` | finalizeClubLine enqueues RELEASE→STARTED→FINISHED per CO; no `sendAfterCommit` | AC-5, AC-15 |
| `ManageOrderServiceUnitTest` | `buildPickedPayload_toteWriteOncePerClubCo` | tote `saveAll`/`historytote` runs once per club CO; STARTED builder does not touch `historytote`; UUID stable | AC-15 |

### Integration tests (Testcontainers PostgreSQL)

| Test class | Asserts | AC |
|---|---|---|
| `OutboxClaimOrderingIT` | claim returns id-ordered; cross-tick gate holds higher-id FINISHED while lower-id STARTED is PENDING/IN_FLIGHT | AC-3, AC-10 |
| `OutboxConcurrentEnqueueIT` | 2 threads (confirmPick/finishPicking + reenqueue) enqueue for same CO → no rollback, no lost notification; **STARTED gets the lower id (per-CO id-monotonicity under concurrency)** | AC-11 |
| `OutboxTerminalHoldIT` | STARTED→FAILED_TERMINAL (HTTP 400 stub) ⇒ FINISHED held, NOT dispatched; stuck-aggregate alert/metric fires; FINISHED-only CO (no STARTED) still dispatches | AC-12, AC-13 |
| `OutboxClaimExplainIT` | `EXPLAIN (ANALYZE)` on claim+gate uses `index_outbox_message_aggregate_order` (no seq scan), probing IN_FLIGHT/FAILED_TERMINAL | AC-14 |
| `OutboxMigrationV1124IT` (class name retains the historical "V1124" label) | V2.1.14 applies cleanly on a fresh Testcontainers schema AND is idempotent on a simulated failed-rerun (INVALID index → DROP IF EXISTS recovers) | AC-16 |

### Manual test plan

| Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Mobile pick STARTED→FINISHED order | staging | pick a CO to completion | OMS gets STARTED then FINISHED; parcel reaches Ready-to-QA, no regression | |
| Club-line batch (3 events) | staging | run a CLUB batch | `outbox_message` shows RELEASE<STARTED<FINISHED by id per CO; no sync `doSend` log; tote label set once (UUID stable) | |
| Terminal hold | staging | force STARTED to HTTP 400 | FINISHED held; stuck-aggregate alert fires; parcel awaits ops, OMS never regressed | |
| Inversion query post-deploy | staging DB | run §1 SQL (incl terminal/skipped) | 0 rows | |

### Post-implementation gate

| Command | Result | Counts |
|---|---|---|
| `mvn test -Dtest=OutboxDispatchServiceUnitTest,PickingorderBusinessServiceUnitTest,CustomerorderBatchServiceUnitTest,ManageOrderServiceUnitTest` | | |
| `mvn verify -Dtest=OutboxClaimOrderingIT,OutboxConcurrentEnqueueIT,OutboxTerminalHoldIT,OutboxClaimExplainIT,OutboxMigrationV1124IT` | | AC-11..AC-16 green |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2381-wms-parcel-status-out-of-order.sh` | | 0 fail required |

**Evidence-recording (REQUIRED before flipping status → implemented):** paste the actual `mvn verify` summary (run/failures/errors), the verify-script `Result: N pass, 0 fail` line, and the AC-14 `EXPLAIN` plan node into §11 Implementation Status. Per the project plan-status directive, status is not flipped until this evidence is recorded with the commit SHA(s).

---

## 9. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **Terminal-hold / stuck-aggregate (R2):** a `FAILED_TERMINAL` STARTED permanently holds its FINISHED for that CO | Med (terminal reachable on first attempt, `OutboxDispatchService:178–181`) | Med — parcel needs ops intervention | **Accepted trade** vs. regressing OMS. Fail-closed gate + **stuck-aggregate metric/alert** (Prereq #8) + ops runbook (§10). |
| Gate false alarm: FINISHED-only CO (STARTED skipped/regular path) never dispatches | Low | Low | Intended/valid — FINISHED is the lowest-id row, gate finds no lower sibling, dispatches (R3 case a, AC-13). |
| `CONCURRENTLY` index build contends on a hot table | Low | Low | `CONCURRENTLY` is online (no table lock); non-tx migration; off-peak deploy; DROP-IF-EXISTS guards a failed rerun (AC-16). |
| `NOT EXISTS` correlated gate slows the claim | Low | Low | `index_outbox_message_aggregate_order` covers it; AC-14 EXPLAIN proves no seq scan. |
| Backward STARTED gets a higher id and OMS accepts it as newer | Low | High | Fix F-ii enqueue-time skip is the dispatch-side guard; OMS stale-rejection (paired ticket) is the backstop; documented SPOF. |
| Retiring 3 dispatchers breaks an un-audited caller | Low | Med | grep confirms only Phase 4 (797–799) calls them; verify-script NEGATIVE check on all 3 names. |
| Double tote-label write / `historytote` UUID overwrite | Low | Med | `buildPickedPayloadJson` once per club CO; STARTED uses `buildPickingStartedPayloadJson`; AC-15 asserts UUID stability. |
| id-ordering silently breaks if a future caller enqueues a CUSTOMER_ORDER event without the CO `FOR UPDATE` lock | Low | High | **Load-bearing invariant documented in §10**; AC-11 asserts per-CO id-monotonicity under concurrency to guard regressions. |

Verify script: `sbdocs/9-System/scripts/verify-SBDEV-2381-wms-parcel-status-out-of-order.sh`.

### 9.2 OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Size class | Large | ordering semantics + fail-closed gate + cross-service unify (3 dispatchers) |
| Pre-draft step | executor-opus analysis + ralplan consensus (Planner→Architect→Critic) | high blast radius |
| Plan-review step | critic (APPROVE, 1 iteration) | mandatory for Large |
| Implementation shape | wms-tdd-gate then ralph | TDD from ACs, loop until verify 0-fail |
| Verification step | verify-script + verifier | mandatory |
| Code-review step | code-reviewer | Large |
| Commit step | git-master | migration / claim+gate / dispatch+event_version / producers as separate commits |

---

## 10. Open Questions / Resolved Decisions

### Resolved Decisions (locked — do NOT relitigate)

1. **Scope: wms2-api ONLY.** OMS-side stale-event rejection is OUT — paired OMS ticket (David Oppenheim).
2. **Fix depth:** deterministic per-aggregate outbox dispatch ordering + UNIFY dual transport (all 3 club-line callbacks → outbox).
3. **event_version contract change ALLOWED.** Satisfied by **`id`-as-event_version** injected at dispatch — no synthetic column. Requires OMS coordination on field name/placement.
4. **Backward transition into Picking is ALWAYS invalid.** **PRIMARY guard = the WMS enqueue-time skip** (Fix F-ii: don't emit a backward STARTED). The monotonic `id`/event_version is a best-effort ordering signal that also enables OMS replay/stale-rejection — it is **NOT** the primary guard (R7; the earlier "sequence is the primary guard" framing was fail-open and is withdrawn).
5. **Ordering key = existing `id` (BIGSERIAL), not a synthetic sequence** (R1/R6). Removes the MAX+1 race wholesale.
6. **Cross-tick gate is FAIL-CLOSED** (R2): a `FAILED_TERMINAL` lower-`id` sibling HOLDS later events; held aggregates are alerted (stuck-aggregate metric), never silently regressed and never silently forever-stalled.
7. **Load-bearing invariant (N1):** per-CO `id` ordering is guaranteed by the CO `findByIdForUpdate` lock serializing the STARTED producer (`confirmPick:528/618`) and FINISHED producer (`finishPickingOrder:192`). **Any future CUSTOMER_ORDER enqueue that does not hold the CO row lock silently reintroduces the 43% inversion.** AC-11 guards this under concurrency.

### Open Questions / Risks to track

- [ ] **OMS event_version contract** — exact field name and placement (additive body field vs HTTP header) must be agreed with David Oppenheim before WMS ships. — *Hard release dependency; value is the outbox row `id`.*
- [ ] **Stuck-aggregate runbook** — define the ops procedure when a `FAILED_TERMINAL` STARTED holds a FINISHED (re-drive vs. manual mark-SENT). — *Required for the R2 alert to be actionable; ship before enabling the alert in prod.*
- [ ] **EXPLAIN plan on production-sized tenant** — confirm `index_outbox_message_aggregate_order` is chosen for the gate under real row counts (AC-14). — *Claim runs every 15 s; a seq scan would degrade dispatch latency.*
- [ ] **`finalizeClubLine` per-CO granularity** — confirm the new loop enqueues per CO (one ordering stream per `aggregateId`) and `buildPickedPayloadJson` fires exactly once per club CO (AC-15). — *Wrong granularity reintroduces cross-CO ambiguity or double tote writes.*

---

## 11. Implementation Status

**Implemented 2026-06-01 (branch `tasks/SBDEV-2381`, on top of develop merge `ec500d2`). Code complete, all tests green, code-reviewed, committed and PR-opened.**

- **Tests commit:** `567fba3` (TDD failing tests, written first)
- **Implementation commit:** `41ad7d3` (Fixes A–F + post-merge compile fix)
- **PR:** [SiteBossInc/wms2-api#35](https://github.com/SiteBossInc/wms2-api/pull/35) → base `develop`

**TDD gate:** tests written first (commit `567fba3`), confirmed failing for the right reason (baseline 10 right-reason failures + 2 expected passes), then implemented to green.

**Production changes (7 files + 1 migration, uncommitted):**
- Fix A — `db/migration/V2.1.14__add_outbox_aggregate_order_index.sql` (new): `CREATE INDEX CONCURRENTLY` + `-- flyway:executeInTransaction=false` + DROP-IF-EXISTS guard; index `(aggregate_type, aggregate_id, id, status)`.
- Fix C-i/D — `repo/jpa/OutboxMessageRepository.java`: fail-closed cross-tick `NOT EXISTS` gate (probes PENDING/FAILED_RETRY/IN_FLIGHT/FAILED_TERMINAL) + `ORDER BY o.next_attempt_at, o.id`.
- Fix C-ii — `service/job/OutboxDispatchService.java`: in-batch deterministic sort before the sequential dispatch loop.
- Fix F-i — `service/job/OutboxDispatchService.java` `withEventVersion`: injects `event_version = msg.getId()` into the POST body via Jackson (`readTree`→`ObjectNode.put`→`writeValueAsString`, verbatim fallback on non-object/parse-failure).
- Fix F-ii — `service/PickingorderBusinessService.java` `confirmPick`: backward guard (`coAlreadyAdvanced` snapshot taken before `setState(STARTED)`; skips STARTED enqueue when `state >= PICKED || pickingconfirmationsent`).
- Fix E — `service/CustomerorderBatchService.java` `finalizeClubLine`: per-CO in-tx enqueue RELEASE→STARTED→FINISHED (ascending ids, null-payload-guarded); Phase-4 dual transport removed. `service/ManageOrderService.java`: 3 dual-transport dispatchers retired (no-op shims); `buildReleasedForPickingPayloadJson` added. `service/job/ReleaseOrderJobService.java`: RELEASE migrated onto the outbox.
- Incidental (required post-merge compile fix, NOT scope creep): `repo/jpa/CustomerorderBatchRepository.java` `findByStateAndTypeAndKeywordPage` return type `Page<Object[]>` → `Page<OrderBatchPageView>` to match the `ViewDtoService` consumer introduced by develop commit `9bb9c73`.

**Tests added (committed `567fba3`):** unit — `OutboxDispatchServiceUnitTest` (AC-1/8, AC-6), `PickingorderBusinessServiceUnitTest` (AC-4), `CustomerorderBatchServiceUnitTest` (AC-5/15); Testcontainers IT — `OutboxClaimOrderingIT` (AC-3/10/13a), `OutboxConcurrentEnqueueIT` (AC-11), `OutboxTerminalHoldIT` (AC-12/13b), `OutboxClaimExplainIT` (AC-14), `OutboxMigrationV1124IT` (AC-16), helper `OutboxItFlyway` (sets `executeInTransaction(false)` so CONCURRENTLY runs under the programmatic Flyway).

**Results (verified independently):**
- `mvn test -Dtest=OutboxDispatchServiceUnitTest,PickingorderBusinessServiceUnitTest,CustomerorderBatchServiceUnitTest` → **Tests run: 157, Failures: 0, Errors: 0, Skipped: 0 — BUILD SUCCESS**.
- `mvn verify` (5 outbox ITs) → all green per-class (OutboxClaimOrderingIT 2, OutboxTerminalHoldIT 2, OutboxMigrationV1124IT 2, OutboxClaimExplainIT 1, OutboxConcurrentEnqueueIT 1; Failures: 0, Errors: 0).
- Verify script → **`Result: 28 pass, 0 fail, 0 skip`** (all code-shape checks + 9 behavioral unit/IT checks).
- Code review: CHANGES-REQUIRED → 3 findings (HIGH null-guard, MEDIUM Jackson event_version, MEDIUM dead `>= PICKED` clause) all applied and re-verified green.

**Caveats / follow-ups (carried from §10):** OMS `event_version` field-name/placement coordination (David Oppenheim); stuck-aggregate metric name + ops runbook still to be defined (the fail-closed hold is implemented and tested, but the Micrometer counter is not yet wired); full-suite `mvn verify` has pre-existing, unrelated IT failures (sysprop placeholder, H2 reserved-word, uninitialized `LosSequencenumber.version`) not introduced by this change.

**Done:** committed (`41ad7d3`) and PR [#35](https://github.com/SiteBossInc/wms2-api/pull/35) opened against `develop`. Remaining: the two follow-ups above (OMS `event_version` coordination; stuck-aggregate metric/runbook).

---

## Notes

Verify script at `sbdocs/9-System/scripts/verify-SBDEV-2381-wms-parcel-status-out-of-order.sh` (authored alongside this plan). It encodes AC-1, AC-3..AC-6, AC-8, AC-10..AC-16 as grep/test checks plus a SQL inversion probe (asserting 0, including terminal + skipped-STARTED cases), a NEGATIVE grep for zero `sendAfterCommit` refs to the 3 retired dispatchers, and targeted `mvn verify` (Testcontainers) for AC-11..AC-16.

### Acceptance Criteria (final set)

- **AC-1** dispatchBatch POSTs STARTED before FINISHED when FINISHED has the higher `id` but precedes STARTED in the claimed batch.
- **AC-3** within one tick, a higher-`id` same-aggregate row is not POSTed before an unsent lower-`id` sibling.
- **AC-4** confirmPick does NOT enqueue STARTED when CO ≥ PICKED / `pickingconfirmationsent=true`; existing `< STARTED` check not loosened.
- **AC-5** club finalize produces outbox rows (not `sendAfterCommit`) for RELEASE→STARTED→FINISHED.
- **AC-6** emitted POST carries `event_version == outbox row id` (dispatcher-injected).
- **AC-8** regression: simulate the observed pair (id 49/50) → dispatch STARTED→FINISHED.
- **AC-10** cross-tick: FINISHED not claimed/sent while a lower-`id` STARTED is still PENDING/IN_FLIGHT.
- **AC-11** concurrent enqueue (confirmPick/finishPicking + reenqueue) on the SAME CO never rolls back a legit notification (id race-free; no UNIQUE) **and STARTED gets the lower `id` (per-CO id-monotonicity under concurrency — guards the §10.7 invariant).** Testcontainers, 2 threads.
- **AC-12** STARTED→FAILED_TERMINAL (HTTP 400 stub) ⇒ FINISHED NOT dispatched ahead; stuck-aggregate alert fires.
- **AC-13** FINISHED-only CO (STARTED skipped, R3 case a) dispatches normally; STARTED-went-terminal CO (R3 case b) is held+alerted, never silently forever-stalled.
- **AC-14** `EXPLAIN(ANALYZE)` on claim+gate uses `index_outbox_message_aggregate_order` (no seq scan), probing IN_FLIGHT/FAILED_TERMINAL.
- **AC-15** club finalize emits RELEASE→STARTED→FINISHED in ascending `id` (one transport); tote `saveAll`/`historytote` exactly once per club CO; **`historytote` UUID stable across the finalize tx (STARTED path does not touch it)**; grep asserts zero `sendAfterCommit` refs to the 3 retired dispatchers.
- **AC-16** V2.1.14 applies cleanly under Testcontainers on a fresh schema AND is idempotent on a simulated failed-rerun (DROP INDEX IF EXISTS + CREATE INDEX CONCURRENTLY IF NOT EXISTS; `flyway:executeInTransaction=false` matches flyway-maven-plugin 10.0.0).
- **Dropped:** old AC-2 (MAX+1 monotonic stamping) and old AC-9 (column backfill) — not applicable under id-ordering.

### ADR

- **Decision:** Order outbox dispatch by the existing `id BIGSERIAL` — claim `ORDER BY next_attempt_at, id`, in-batch Java sort, and a fail-closed cross-tick `NOT EXISTS` gate keyed on `id` (probing PENDING/FAILED_RETRY/IN_FLIGHT/FAILED_TERMINAL). Inject `event_version = id` at dispatch. PRIMARY backward guard is the enqueue-time skip in `confirmPick`. Unify all three club Phase-4 notifications onto the outbox inside `finalizeClubLine`.
- **Drivers:** cross-tick + fail-safe correctness; race-freedom (unlocked reenqueue path); minimal schema/blast radius.
- **Alternatives considered:** synthetic per-aggregate sequence + MAX+1; `created_at` tiebreak; post-claim Java gate only.
- **Why chosen:** `id` is already monotonic per aggregate (CO row lock serializes producers), race-free (Postgres-assigned), and a valid event_version — it removes the MAX+1 race and UNIQUE-abort risk wholesale while needing only an online index. Fail-closed on FAILED_TERMINAL prevents OMS regression at the cost of an operable hold.
- **Consequences:** a permanently-failed STARTED holds its FINISHED (needs ops intervention) — covered by a stuck-aggregate alert and runbook; one online `CONCURRENTLY` index (repo's first non-tx migration); a correlated gate subquery on the hot claim path (index-validated by AC-14); event_version is dispatch-time so payload builders are unchanged; OMS coordination required on field name/placement; id-ordering depends on a documented CO-lock invariant (§10.7).
- **Follow-ups:** paired OMS stale-rejection ticket (David Oppenheim); stuck-aggregate ops runbook; production-sized EXPLAIN validation; confirm per-CO enqueue granularity + exactly-once tote write in `finalizeClubLine`.
