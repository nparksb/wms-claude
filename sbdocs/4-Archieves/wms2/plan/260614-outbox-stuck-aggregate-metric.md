---
title: "Outbox Stuck-Aggregate Metric — wire the SBDEV-2381 R2 alert signal (Prereq #8)"
ticket: ""
ticket_url: ""
type: "feature"
severity: "medium"
priority: "medium"
status: "archived"
archived: "2026-06-16"
archive_note: "Implemented + merged (PR #46, develop). Open follow-ups carried at archival: AC-7 production-sized EXPLAIN + ops alert-threshold confirmation (§10). Acceptance script retained at sbdocs/9-System/scripts/verify-260614-outbox-stuck-aggregate-metric.sh"
pr: "https://github.com/SiteBossInc/wms2-api/pull/46"
commit: "709ec61"
project: ["wms2-api"]
version: "v2"
requester: "Nam Park"
assignee: "Nam Park"
created: "2026-06-14"
updated: "2026-06-14"
db_verified: true
db_verified_note: >
  Touches a new read-only aggregate query over outbox_message. The dev-tenant DB MCP
  servers were not reachable in the authoring session; query-result correctness was instead
  verified against real PostgreSQL via OutboxStuckAggregateIntegrationTest (Testcontainers).
  The production-sized cost EXPLAIN remains an open follow-up (AC-7), mirroring how SBDEV-2381
  itself deferred its production EXPLAIN (that plan's §10 / AC-14). The query reuses the
  existing index `index_outbox_message_aggregate_order` (V2.1.14); no schema change.
related:
  - "[[SBDEV-2381-wms-parcel-status-out-of-order]]"
  - "[[wms2-unstick-held-outbox-aggregate]]"
  - "[[wms2-scheduled-jobs-catalog]]"
  - "[[wms2-oms-integration-map]]"
  - "[[wms2-caching-strategy]]"
tags:
  - plan
  - wms2
  - outbox
  - observability
  - metrics
  - micrometer
  - oms-integration
  - scheduled-job
---

# Outbox Stuck-Aggregate Metric — wire the SBDEV-2381 R2 alert signal (Prereq #8)

**Ticket:** (untracked — `260614-` dated plan)
**Project:** wms2-api | **Version:** v2 (Java 21 / Spring Boot 3.5.x) | **Type:** feature (observability)
**Priority:** Medium | **Severity:** MEDIUM (today the stuck-aggregate condition is silent; this makes it alertable)
**Status:** implemented (2026-06-14) — PR [#46](https://github.com/SiteBossInc/wms2-api/pull/46), commit `709ec61` → `develop`
**Date:** 2026-06-14
**db_verified:** false — see frontmatter note + AC-7 (production EXPLAIN is a pre-merge gate)

> **Review status (2026-06-14).** Initially drafted directly under the `wms-feature-plan` mechanical-addition
> exception, then **independently reviewed by `architect` (verdict: SOUND-WITH-CHANGES) and `critic` (verdict:
> APPROVE-WITH-CHANGES)** in a separate pass. Both confirmed the design is sound and the patterns correctly
> reused (`JobMetrics` gauge idiom; per-tenant `getSysvalue(...ACTIVATED_KEY)` gate; piggyback the
> advisory-locked dispatcher loop) and that the ralplan-skip was defensible — but the loop would have caught the
> defects below, which are now folded in: held-set must include `IN_FLIGHT` (R-A1); §2.4 over-claimed index
> coverage of the outer scan (R-A5/C1); age needs a clock-skew floor (R-A2); the sampling call-site must be
> inside the per-tenant try (R-A3); `register(rows, true)` overwrite must be explicit (R-A4); test-class names
> were wrong and the constructor change ripples into the existing `OutboxDispatcherJobUnitTest` (R-C2); and the
> verify script had over-claimable checks (R-M1). All blocking changes are applied in this revision. Goes
> through the normal `wms-tdd-gate` before implementation.

> **Why this exists.** SBDEV-2381 (merged, PR #35) made the outbox dispatcher **fail-closed**: a lower-`id`
> `FAILED_TERMINAL` row holds every later event for the same aggregate rather than leaking a
> FINISHED-without-STARTED to OMS (plan §9 R2, §10 decisions 6–7). The accepted cost is that a held aggregate
> needs **operator intervention** to clear — captured in runbook [[wms2-unstick-held-outbox-aggregate]]. That
> runbook is only actionable if an alert tells ops a hold exists. **SBDEV-2381 §11 / §10 left the metric
> un-wired** ("the fail-closed hold is implemented and tested, but the Micrometer counter is not yet wired").
> This plan wires it. It is the paired prerequisite (SBDEV-2381 Prereq #8) that must ship **before** the
> stuck-aggregate alert is enabled in prod.

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep over `v2/wms2-api/src` (`OutboxDispatcherJob`, `OutboxDispatchService`, `OutboxMessageRepository`, `JobMetrics`, `getSysvalue`, `MeterRegistry`).

| # | File:line | Construct | In-scope? | Phase |
|---|-----------|-----------|-----------|-------|
| 1 | `service/WmsConstants.java:~1030` (alongside the other `SYSTEM_PROPERTY_*_ACTIVATED_KEY` rows) | add the new sysprop gate key constant | **yes** | 1 |
| 2 | `repo/jpa/OutboxMessageRepository.java:20-76` (interface, after `deleteSentOlderThan`) | add `findStuckAggregateStats()` native projection query | **yes** | 1 |
| 3 | `repo/projection/OutboxStuckAggregateView.java` (NEW) | projection interface `getHeldAggregates()` / `getOldestAgeSeconds()` | **yes** | 1 |
| 4 | `service/job/OutboxDispatchService.java:13-86,122` (already injects `repo`, `meters`, `syspropService`) | add `sampleStuckAggregates()` — sysprop-gated; returns the projection (null when OFF); runs in tenant context | **yes** | 1 |
| 5 | `schedulejob/OutboxDispatcherJob.java:26-80` | register two `MultiGauge`s in ctor; sample per-tenant **inside** the existing try; `register(rows, true)` once after the loop; clear gauges on lock-busy early-return; **ctor signature unchanged** (already injects `meters`) | **yes** | 1 |
| 6 | `application.properties:113-116` (outbox block) | doc-only: note the metric is gated by sysprop, no new `app.*` key needed | **no** — config via sysprop, not properties | — |
| 7 | `unit/service/job/OutboxDispatchServiceUnitTest` (NEW) + `unit/schedulejob/OutboxDispatcherJobUnitTest` (EXISTING — extend) + `OutboxStuckAggregateIT` (Testcontainers) | gate, query, gauge registration, lock-busy clear, mixed/exception | **yes** | 1 |
| 8 | OMS-side / Grafana alert rule (`count>=1` OR `oldest_age_seconds>900`) | the actual alert wiring | **no** — ops/observability config, not wms2-api code; contract documented in §3.5 + runbook §8 | — |

Every in-scope row (1–5, 7) is covered in §3 / §5 and mapped to a check in the verify script.

---

## 1. Problem Statement

The SBDEV-2381 fail-closed gate (`OutboxMessageRepository.findAndClaimPending`, the `NOT EXISTS` clause at lines
38–44) makes a `FAILED_TERMINAL` row **permanently hold** every higher-`id` sibling for the same
`(aggregate_type, aggregate_id)` until an operator acts. A row reaches `FAILED_TERMINAL` on an OMS HTTP
**400/404/422** first response, or after `attempts >= app.outbox.dispatcher.max-attempts` (default 5)
(`OutboxDispatchService.isTerminal`, lines 200–202). Terminal rows are never auto-deleted
(`OutboxMessageRepository` line 72).

**Today this condition is invisible.** There is no metric for "an aggregate is held." Existing outbox metrics
(`wms2.outbox.dispatched{outcome}`, `wms2.outbox.tick_duration`) count *throughput*, not *stuck state* — a held
aggregate simply stops appearing in `dispatched{outcome=sent}` and nothing fires. The
[[wms2-unstick-held-outbox-aggregate]] runbook exists but has no trigger; divergence is found only when OMS or a
customer complains. **Goal:** emit a per-tenant gauge of held aggregates (and the age of the oldest held event)
so ops can alert on it and open the runbook with the tenant already identified.

---

## 2. Current Architecture

### 2.1 The dispatcher loop (where sampling will piggyback)

`OutboxDispatcherJob.dispatch()` (`schedulejob/OutboxDispatcherJob.java:46-80`):

```
@Scheduled(cron = "${app.cron.outbox-dispatcher:*/15 * * * * *}")   // every 15s
  tryLock(OUTBOX_DISPATCHER)  // advisory lock 100008L — only ONE replica per tick; early-return if busy
  for each TenantProfile (tenantDbConfigurationRepository.findAll()):
      TenantContext.setCurrentTenant(profile)        // routes to the tenant DB
      dispatchService.dispatchBatch()                // claim → POST → mark
      dispatchService.cleanupSent(RETENTION_DAYS)
      TenantContext.clear()
  tickSample.stop("wms2.outbox.tick_duration"); unlock
```

The job already injects `MeterRegistry meters` (line 34). It already iterates every tenant **inside the advisory
lock**, with tenant context set — the exact place a per-tenant count can be sampled with no new job, no new lock,
and no N-replica amplification.

### 2.2 The dispatch service (where the query call will live)

`OutboxDispatchService` (`service/job/OutboxDispatchService.java`) already injects everything needed:
`repo` (line 13), `meters` (16), and `syspropService` (18). `dispatchBatch()` (87) and `cleanupSent(int)` (122)
are the existing per-tenant entry points.

### 2.3 Existing metric & gate patterns (reused, not reinvented)

- **Gauge idiom** — `schedulejob/JobMetrics.java:21-25`: `Gauge.builder(name, stateObj, fn).register(registry)`
  for static gauges. For a *re-sampled, tenant-tagged set* the idiomatic Micrometer tool is `MultiGauge`
  (not yet used in the repo — this plan introduces it; it is the standard mechanism and avoids hand-rolling a
  `ConcurrentHashMap<tenant, AtomicLong>` + N gauge registrations).
- **Per-tenant sysprop gate** — e.g. `StaleClubBatchCleanupJob.java:55-56`,
  `ReplenishOrderJob.java:130-131`: `Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_*_ACTIVATED_KEY))`.
  `getSysvalue` is `@Cacheable("sysprops")` keyed by `facilityCode:key` (`SyspropService.java:95,288-289`), so a
  per-tenant per-tick read is cache-backed (no per-tick DB hit for the gate). Default-OFF falls out for free:
  an unset key yields a non-`true` value → `parseBoolean` → `false`.

### 2.4 Index available for the detection query

`index_outbox_message_aggregate_order ON outbox_message (aggregate_type, aggregate_id, id, status)`
(V2.1.14, SBDEV-2381). **This index serves only the inner correlated `EXISTS` lower-`id`-sibling probe**
(leading `aggregate_type, aggregate_id` equality + `id` range, with `status` as a covering column). It does
**not** drive the *outer* `held.status IN (...)` scan — `status` is the 4th column with no usable leading
predicate, so Postgres is expected to **sequentially scan** `outbox_message` to enumerate candidate held rows,
then index-probe the `EXISTS` per candidate. That is acceptable *because the table stays small* (SENT rows are
GC'd after 7 days — `OutboxMessageRepository:75`; held/terminal rows are rare), **not** because the index covers
the scan. Confirming that the seq-scan cost is acceptable at production row counts is exactly AC-7 (§2.5). A
partial index on `(aggregate_type, aggregate_id, id) WHERE status IN ('PENDING','FAILED_RETRY','IN_FLIGHT')` is
the documented fallback if AC-7 shows the outer scan dominating (§9).

### 2.5 DB state (NOT yet verified live — AC-7)

The dev-tenant DB MCP servers were not reachable during authoring. The detection query (§3.2) is read-only.
**AC-7 makes a production-sized `EXPLAIN (ANALYZE, BUFFERS)` a required pre-merge gate.** The correct assertion
(per architect review): the `EXISTS` sub-plan must use `index_outbox_message_aggregate_order`, and the **total**
cost/time must be acceptable at real row counts — **not** "no sequential scan" (a seq-scan of the small outer
held-row set is the expected and acceptable plan; asserting "no seq scan" would false-fail). If the outer scan
dominates at scale, add the partial index from §9.

---

## 3. Design

### 3.1 Sysprop gate (Affected site 1)

Add to `WmsConstants` next to the other `*_ACTIVATED_KEY` constants:

```java
public static final String SYSTEM_PROPERTY_OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED_KEY =
        "OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED";
```

Default OFF (no `los_sysprop` row needed to start). Enable per tenant after the AC-7 EXPLAIN passes for that
tenant — matching the cautious per-tenant rollout used by the cron jobs.

**No Flyway script is needed to populate the key — and adding one would be wrong.** The gate reads
default-OFF *because the row is absent*, via this chain:

- `syspropService.getSysvalue(key)` (`SyspropService.java:288-291`) delegates to
  `syspropRepository.findSysvalueBySyskey(key)`.
- That repository method (`SyspropRepository.java:29-31`) is a native scalar query
  (`select sysvalue from los_sysprop where syskey = :syskey and workstation = 'DEFAULT' order by client_id LIMIT 1`).
  With **no matching row it returns `null`** — a single-scalar Spring-Data query method returns `null` on no
  match (it does not throw).
- `Boolean.parseBoolean(null)` → `false`. So **absent row → gate OFF → no gauge emitted** (§3.3). The absence of
  the row *is* the OFF value; nothing needs to be seeded.

Three reasons a Flyway seed would be actively wrong here:
1. **It would defeat default-OFF.** A row is only inserted to turn the gate *on*; seeding one with `'false'` is
   pointless and seeding `'true'` flips the metric on before the AC-7 EXPLAIN gate.
2. **Migrations run per-tenant DB** (project CLAUDE.md: "Migrations run against tenant databases") — a blanket
   `INSERT` would force the metric ON for *every* tenant at once, the opposite of the per-tenant opt-in this plan
   mandates (§5.1, §8).
3. **`los_sysprop` is operator-managed config, not schema.** Like every other `*_ACTIVATED_KEY` gate
   (`STALE_CLUB_BATCH_CLEANUP_ACTIVATED`, `REPLENISHMENT_TIMER_ACTIVATED`, …), the row is created/flipped by an
   operator at rollout time, not seeded by migration.

**To enable it for a tenant** (after that tenant's AC-7 EXPLAIN passes), insert/update the row directly in that
tenant DB:

```sql
INSERT INTO los_sysprop (syskey, sysvalue, workstation, client_id)
VALUES ('OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED', 'true', 'DEFAULT', <client_id>);
```

Caveat: `getSysvalue` is `@Cacheable("sysprops")` keyed `facilityCode:key` (§2.3), so a newly-inserted row may
not take effect until that cache entry evicts/expires — identical to every other sysprop-gated cron job.

### 3.2 Detection query + projection (Affected sites 2, 3)

New projection `repo/projection/OutboxStuckAggregateView.java` (name follows the repo's `*View` projection
convention, e.g. `OrderContentsView`):

```java
public interface OutboxStuckAggregateView {
    long getHeldAggregates();     // distinct (aggregate_type, aggregate_id) currently held
    long getOldestAgeSeconds();   // age of the oldest held event by created_at; 0 when none
}
```

New repository method (native). `held` = a non-`SENT`, non-terminal row blocked by a lower-`id`
**`FAILED_TERMINAL`** sibling for the same aggregate:

```java
@Query(value = """
    SELECT COUNT(DISTINCT held.aggregate_type || ':' || held.aggregate_id) AS heldAggregates,
           COALESCE(CAST(GREATEST(0, EXTRACT(EPOCH FROM (NOW() - MIN(held.created_at)))) AS bigint), 0)
               AS oldestAgeSeconds
      FROM outbox_message held
     WHERE held.status IN ('PENDING','FAILED_RETRY','IN_FLIGHT')
       AND EXISTS (
             SELECT 1 FROM outbox_message blk
              WHERE blk.aggregate_type = held.aggregate_type
                AND blk.aggregate_id   = held.aggregate_id
                AND blk.id < held.id
                AND blk.status = 'FAILED_TERMINAL')
    """, nativeQuery = true)
OutboxStuckAggregateView findStuckAggregateStats();
```

**Two distinct status sets (architect review R-A1 — do not conflate):**
- **Blocker** (the `EXISTS` subquery): `blk.status = 'FAILED_TERMINAL'` only. A `PENDING`/`FAILED_RETRY`/`IN_FLIGHT`
  lower sibling is *transient* (self-resolves next ticks), so it must NOT count as a stuck-cause — alerting on
  it would page on normal in-flight ordering.
- **Held** (the outer row): `held.status IN ('PENDING','FAILED_RETRY','IN_FLIGHT')` — every non-`SENT`,
  non-terminal row is a held, undelivered event. The dispatch gate itself blocks claiming on `IN_FLIGHT`
  siblings (`OutboxMessageRepository:43`), so `IN_FLIGHT` belongs in the held set. (In practice a held row is
  almost always `PENDING` — it can't normally be claimed past the gate — but including `FAILED_RETRY`/`IN_FLIGHT`
  is defensive against reclaim/future paths and cannot create a false positive, since the `EXISTS` terminal
  filter still gates every match.)

**`GREATEST(0, …)`** floors the age against app-clock-vs-DB-clock skew: `created_at` is written by Spring's
`@CreatedDate` (app clock, `OutboxMessage:79-81`) while `NOW()` is the DB clock, so the interval could be
slightly negative; `COALESCE` alone would not guard a non-null negative.

**`aggregate_id` is NOT NULL** (`OutboxMessage:48` `@Column(name="aggregate_id", nullable=false)`), so the
`aggregate_type || ':' || aggregate_id` distinct-key never yields NULL (no silently-dropped rows).
(Documented trade on the age proxy — see §9.)

**Age semantics:** `oldest_age_seconds` is measured from the held event's `created_at` (how long an undelivered
event has existed). This is a simple, monotonic proxy for "how long has something been stuck"; an alternative
(age since the blocker went terminal) is rejected in §9 as marginally more accurate but more complex.

### 3.3 Sampling method on the dispatch service (Affected site 4)

```java
/** SBDEV-2381 Prereq #8: sample held-aggregate stats for the current tenant. Gated, read-only.
 *  Returns null when the gate is OFF (caller emits no gauge row for this tenant). */
public OutboxStuckAggregateView sampleStuckAggregates() {
    if (!Boolean.parseBoolean(syspropService.getSysvalue(
            WmsConstants.SYSTEM_PROPERTY_OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED_KEY))) {
        return null;   // gate OFF for this tenant → no gauge row emitted
    }
    return repo.findStuckAggregateStats();
}
```

**Must be called inside the job's per-tenant `try` block while `TenantContext` is set** (so it routes to the
tenant DB and a failure is isolated by the existing `catch`). The gate read is Caffeine-cached (§2.3). Note: the
gate's per-tenant correctness inherits the existing repo-wide assumption that `facilityCode` is unique across
tenants (the `sysprops` cache key is `facilityCode:key`, `SyspropService:288`) — every cron-job gate relies on
the same invariant, so this introduces no new risk.

### 3.4 Gauge registration in the job (Affected site 5)

Two `MultiGauge`s registered once (job is a `@Service` singleton), rows replaced each tick:

```java
private final MultiGauge stuckCountGauge;       // wms2.outbox.stuck_aggregate
private final MultiGauge stuckAgeGauge;         // wms2.outbox.stuck_aggregate.oldest_age_seconds

// in ctor (registered once — job is a @Service singleton):
this.stuckCountGauge = MultiGauge.builder("wms2.outbox.stuck_aggregate").register(meters);
this.stuckAgeGauge   = MultiGauge.builder("wms2.outbox.stuck_aggregate.oldest_age_seconds")
                                 .baseUnit("seconds").register(meters);
```

Control flow in `dispatch()` (ordering is load-bearing — architect R-A3, R-A4):

- **Lock-busy early-return** → before returning, clear both gauges: `stuckCountGauge.register(List.of(), true)`
  (and the age gauge) so a replica that is *not* the active dispatcher this tick does not export stale values.
  Each replica owns its own `MeterRegistry`/MultiGauge; only the lock holder produces real numbers; the lock can
  migrate between replicas across ticks. **Caveat (architect R-M2):** a just-demoted replica still exports its
  last rows until its *own* next tick clears them (≤1 tick / 15 s), so two replicas can briefly both export a
  series — the §3.5 alert MUST aggregate `max by (tenant, facility)` to neutralize this.
- **Active tick** → build `List<MultiGauge.Row<?>>` (one per gauge) as local lists. **Inside** the existing
  per-tenant `try` block (context set), after `dispatchBatch()`/`cleanupSent()`, call
  `dispatchService.sampleStuckAggregates()`; if non-null, append a row tagged
  `Tags.of("tenant", profile.getTenantName(), "facility", profile.getFacilityCode())` to each list (the query
  runs in-loop; only the `register(...)` happens after the loop). After the loop completes, once,
  `stuckCountGauge.register(countRows, true)` and `stuckAgeGauge.register(ageRows, true)`.
  The `true` overwrite flag is required: it removes rows for tenants no longer present and updates changed ones;
  the no-arg `register(rows)` defaults `overwrite=false` and would *accumulate* stale rows.

```
Tags: tenant = TenantProfile.getTenantName(), facility = TenantProfile.getFacilityCode()
Value: long (held count / epoch-seconds) → stored as Micrometer double; lossless at any realistic outbox size/age.
Cardinality: bounded by tenant×facility (the same set the dispatcher already iterates). No unbounded label.
Failure isolation: the sample call sits inside the per-tenant try/catch (OutboxDispatcherJob:65-74), so a count-
  query error for one tenant is logged and skipped without aborting the tick or corrupting the row lists.
```

### 3.5 Alert contract (what ops builds on this — site 8, doc-only)

| Metric | Type | Tags | Alert |
|---|---|---|---|
| `wms2.outbox.stuck_aggregate` | gauge | `tenant`, `facility` | `max by (tenant,facility) >= 1` sustained (e.g. 2 ticks) → page; payload carries `tenant`/`facility` → open runbook |
| `wms2.outbox.stuck_aggregate.oldest_age_seconds` | gauge | `tenant`, `facility` | `max by (tenant,facility) > 900` (15 min) → escalate (a genuinely stuck, not transient, hold) |

**Aggregation is mandatory (architect R-M2):** alerts MUST use `max by (tenant, facility)` (i.e. drop the
`instance` label). Each replica is a separate Prometheus target; only the active dispatcher exports real rows
and a just-demoted replica can export a stale row for ≤1 tick — a `sum`/`count` alert would double-count or
flap on lock migration, `max by (tenant,facility)` does not.

**Pair with a dispatcher-liveness alert (skeptic note):** this gauge is only as fresh as the dispatcher's last
tick. If the dispatcher itself wedges (the worst-case landlord-pool pin, `OutboxDispatcherJob:52-54`), the gauge
goes stale exactly when it matters. Rely on the existing `wms2.outbox.tick_duration` / dispatcher-liveness
signals as the companion alert — do not treat this gauge as a dispatcher-health proxy.

This matches [[wms2-unstick-held-outbox-aggregate]] §8. The Grafana/alert rule itself is ops config, out of this
plan's code scope.

---

## 4. File Change Summary

| File | Change | Description |
|---|---|---|
| `service/WmsConstants.java` | Modify | add `SYSTEM_PROPERTY_OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED_KEY` |
| `repo/projection/OutboxStuckAggregateView.java` | Add | projection interface (held count + oldest age) |
| `repo/jpa/OutboxMessageRepository.java` | Modify | add `findStuckAggregateStats()` native query |
| `service/job/OutboxDispatchService.java` | Modify | add gated `sampleStuckAggregates()` |
| `schedulejob/OutboxDispatcherJob.java` | Modify | register 2 MultiGauges in ctor body (no signature change); sample per tenant inside the try; clear on lock-busy |
| `unit/service/job/OutboxDispatchServiceUnitTest.java` | Add (none exists today) | gate ON/OFF behavior |
| `unit/schedulejob/OutboxDispatcherJobUnitTest.java` | **Modify (EXISTING)** | add gauge-row + clear-on-lock-busy + mixed/exception tests; its **2 existing tests must still pass**; switch its `mockMeters()` to a real `SimpleMeterRegistry` so `MultiGauge.register` works (a Mockito mock returns null) |
| `integration/.../OutboxStuckAggregateIT.java` | Add | Testcontainers PG — held count/age; reuse `OutboxTerminalHoldIT` seed + `OutboxItFlyway.migrateTopLevel`; EXPLAIN per `OutboxClaimExplainIT` |

No Flyway migration (see §3.1 — the gate reads default-OFF from the *absent* `los_sysprop` row;
`getSysvalue` → `null` → `Boolean.parseBoolean` → `false`; seeding a row via Flyway would be wrong).
No `application.properties` key. No schema change.

---

## 5. Phased Implementation Plan

Single phase (focused addition). `wms-tdd-gate` writes the failing tests from §7 first.

### 5.1 Prerequisites

| Prerequisite | Status |
|---|---|
| DB state / schema | **N/A** — no schema change; reuses `outbox_message` + V2.1.14 index |
| Feature flag / sysprop | **NEW** — `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` (default OFF); enable per tenant post-EXPLAIN |
| Config / env | **N/A** — no new `app.*` property |
| Deploy-order | None — additive; safe to deploy independently of any other plan |
| Data migration / backfill | **N/A** |
| External systems | **Grafana/alerting** (downstream) — alert rules per §3.5 are wired by ops *after* this ships; not a code dependency |
| Access | Prometheus scrape of `/actuator/prometheus` already in place (existing `wms2.outbox.*` metrics prove it) |
| Monitoring | This plan *is* the monitoring; AC-7 EXPLAIN before enabling per tenant |

### 5.2 Phase 1 — wire the metric

- **Goal:** per-tenant held-aggregate count + oldest-held age gauges, gated default-OFF.
- **Changes:** Affected sites 1–5 + tests (7).
- **Testing:** §7.
- **Risk:** Low — additive, gated OFF, read-only query inside the existing advisory-locked loop.
- **Branch:** `feature/260614-outbox-stuck-aggregate-metric`.
- **Effort:** ~0.5 day code + tests; EXPLAIN validation before enabling.

---

## 6. Backward Compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| Outbox dispatch behavior | claim→POST→mark | unchanged | none — sampling is read-only, after dispatch |
| Metrics surface | `wms2.outbox.dispatched`, `.tick_duration` | + `wms2.outbox.stuck_aggregate`, `.oldest_age_seconds` | additive |
| `outbox_message` schema | — | — | none |
| Sysprop set | existing | + one default-OFF key | additive |
| Advisory-lock tick cost | N tenants × (dispatch) | + one fast indexed count per *enabled* tenant | negligible vs the documented N×15s OMS-timeout worst-case pin (`OutboxDispatcherJob.java:52-54`); gauge OFF by default |

**What does NOT change:** the gate logic, dispatch ordering, retry/terminal semantics, the advisory lock id
(`OUTBOX_DISPATCHER` 100008L), the cron cadence, any HTTP contract with OMS, any DB schema.

---

## 7. Testing Strategy

**Unit — `OutboxDispatchServiceUnitTest` (NEW class):**
- `sampleStuckAggregates_gateOff_returnsNullNoQuery` — sysprop OFF → `repo.findStuckAggregateStats()` never called, returns null.
- `sampleStuckAggregates_gateOn_returnsRepoStats` — sysprop ON → returns repo projection.

**Unit — `OutboxDispatcherJobUnitTest` (EXISTING class — extend; its 2 current tests must still pass):**
- Switch the test's `mockMeters()` to a real `SimpleMeterRegistry` (a Mockito mock makes `MultiGauge.register` return null → NPE).
- `activeTick_registersRowPerEnabledTenant` — one MultiGauge row per enabled tenant, tagged `tenant`/`facility`; assert via `registry.find("wms2.outbox.stuck_aggregate").gauges()`.
- `lockBusy_clearsGauges` — when `tryLock` returns false, both gauges are registered empty (no stale export). **This is the behavioral proof for the clear-on-lock-busy logic** (the verify script's shape check is not sufficient on its own).
- `gateOffTenant_noRow` — a disabled tenant contributes no row.
- `mixedEnabledDisabled_onlyEnabledRows` — in one tick, enabled + disabled tenants → rows only for the enabled subset (architect R-M3).
- `tenantSampleThrows_tickNotAborted` — `sampleStuckAggregates()` throwing for one tenant is caught by the per-tenant try/catch; other tenants' rows still register (architect R-M3).

**Integration (Testcontainers PostgreSQL — NOT H2; the native query uses `EXTRACT(EPOCH …)` / `||` / `GREATEST`):**
Reuse the existing harness — `OutboxTerminalHoldIT` already seeds STARTED→`FAILED_TERMINAL` + held FINISHED, and `OutboxItFlyway.migrateTopLevel` applies the full migration set incl. V2.1.14; `OutboxClaimExplainIT` is the EXPLAIN-in-IT template.
- `OutboxStuckAggregateIT#heldByTerminalSibling_counted` — terminal STARTED + held later row for one CO → `heldAggregates=1`, `oldestAgeSeconds≈age(held.created_at)`. **✓ validated green against Testcontainers PG (2026-06-14 TDD-gate run).**
- `OutboxStuckAggregateIT#noTerminalBlocker_zero` — PENDING with no lower terminal sibling → `0/0`. **✓ green.**
- `OutboxStuckAggregateIT#distinctAggregates_counted` — two held COs (one held `IN_FLIGHT`) → `heldAggregates=2`. **✓ green.**
- `OutboxStuckAggregateIT#detectionQueryPlansCheaply` (AC-7 cost sanity) — at 5k rows the top-level plan cost stays small (no runaway). **TDD-gate finding:** Postgres plans this full-table `COUNT` + `EXISTS` as a **hash semi-join with a cheap `Seq Scan` on the tiny `FAILED_TERMINAL` set — it does NOT use `index_outbox_message_aggregate_order`, and that is correct & cheap**. An "index used" assertion would be wrong (consistent with §2.5). Authoritative AC-7 = the production-sized `EXPLAIN` (§10 open item). Note: the IT Flyway harness (`OutboxItFlyway`) does not create the `CONCURRENTLY` index (pre-existing limitation affecting `OutboxClaimExplainIT` too) — irrelevant here since PG semi-joins regardless.

> **DB verification (gate run):** the §3.2 query's **result correctness is now validated against real PostgreSQL** via `OutboxStuckAggregateIT` (Testcontainers) — this closes the authoring-time `db_verified:false` gap for query *results*. The remaining open item is the production-sized cost `EXPLAIN` (AC-7).

**Manual Test Plan:**

| Scenario | Environment | Steps | Expected | P/F |
|---|---|---|---|---|
| Gauge appears when enabled | dev tenant | set `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED=true`; seed a terminal-blocked CO (per runbook §4); scrape `/actuator/prometheus` | `wms2_outbox_stuck_aggregate{tenant,facility}=1`, `oldest_age_seconds>0` | |
| Clears after unstick | dev tenant | run runbook §5.2 mark-SENT on the blocker; wait 1–2 ticks; scrape | gauge → 0 | |
| OFF by default | dev tenant (no sysprop) | scrape without setting the key | no `stuck_aggregate` series for that tenant | |
| Prod EXPLAIN (AC-7) | prod-sized tenant | `EXPLAIN (ANALYZE, BUFFERS)` the §3.2 query | index used, no seq scan | |

Verify script: `sbdocs/9-System/scripts/verify-260614-outbox-stuck-aggregate-metric.sh`.

---

## 8. Rollout Plan

`feature/260614-outbox-stuck-aggregate-metric` → PR → `develop` → standard release. After merge: run AC-7 EXPLAIN
per tenant, then set `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED=true` tenant-by-tenant, then have ops enable the
§3.5 alert rules. No deploy-order coupling to other plans.

---

## 9. Alternatives Considered

| Option | Description | Why rejected |
|---|---|---|
| Separate `@Scheduled` probe job | Own job + new advisory lock id + cadence | More moving parts (a second lock, a second tick) for a count that the dispatcher loop already visits per tenant under lock. Requester chose piggyback (§10). |
| Every replica registers a query-backed gauge | Each replica samples on scrape | N×M query load and divergent per-replica values; needs no lock but breaks the single-writer invariant. Rejected for load + ambiguity. |
| Count-only (no age gauge) | Single gauge | Can't distinguish a 30-second blip from a day-old stall → noisy paging. Requester chose count + age (§10). |
| `process_type` tag on the count | Break down by event type | Useful but raises cardinality and wasn't requested; deferrable. The runbook §4.2 already lets ops see process_type during triage. |
| Age from blocker's terminal time | `NOW() - blk.modified_at` | Marginally more precise "stuck duration" but needs a second aggregate/join; `held.created_at` is simpler and monotonic. Rejected for complexity. |
| Counter instead of gauge | increment on detect | A stuck *state* is a level, not an event — a gauge is the correct instrument; a counter can't go back down when cleared. |
| Partial index `… WHERE status IN ('PENDING','FAILED_RETRY','IN_FLIGHT')` | index that also drives the outer held-row scan | **Deferred, not rejected** — only worth adding if AC-7 shows the outer seq-scan dominating at prod row counts (§2.4/§2.5). The table is small by design, so the plain V2.1.14 index is expected to suffice. Documented so the implementer has the fallback ready. |

---

## 10. Open Questions / Resolved Decisions

### Resolved (locked via requester Q&A 2026-06-14 — do NOT relitigate)

1. **Sampling model = piggyback on `OutboxDispatcherJob`** — sample inside the existing per-tenant loop (every 15s, advisory-locked 100008L); one replica samples; `MultiGauge` rows replaced each tick. No new job/lock.
2. **Metric shape = count + oldest-held age** — two gauges (`wms2.outbox.stuck_aggregate`, `…oldest_age_seconds`), tagged `tenant`+`facility`. Enables both `count>=1` and `age>15m` alerts.
3. **Rollout = sysprop-gated, default OFF** — `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED`, per-tenant opt-in after the AC-7 EXPLAIN.
4. **Blocker scope = `FAILED_TERMINAL` only** (not transient `PENDING`/`FAILED_RETRY`/`IN_FLIGHT` siblings) — only terminal holds are operator-actionable (§3.2).
5. **Held scope = `PENDING`/`FAILED_RETRY`/`IN_FLIGHT`** (architect R-A1) — every non-`SENT`, non-terminal row is a held event; `IN_FLIGHT` is included because the dispatch gate blocks on it (`OutboxMessageRepository:43`). Cannot false-positive (the `EXISTS` terminal filter gates every match). Runbook §4.1 query updated to match.
6. **Alert aggregation = `max by (tenant, facility)`** (architect R-M2) — mandatory to neutralize the ≤1-tick multi-replica staleness window; documented in §3.5 + runbook §8.
7. **Gauge freshness depends on dispatcher liveness** — paired with the existing `wms2.outbox.tick_duration`/liveness alert, not a substitute for it (§3.5).

### Open

- [ ] **AC-7 production EXPLAIN** — confirm the `EXISTS` sub-plan uses `index_outbox_message_aggregate_order` and total cost is acceptable at prod row counts before enabling the gate per tenant; if the outer scan dominates, add the §9 partial index. (Dev MCP was unreachable at authoring time.)
- [ ] **Alert thresholds** — §3.5 proposes `max by(tenant,facility) >= 1` (2-tick window) and `age > 900s`; ops to confirm final numbers when wiring Grafana.

---

## 11. Acceptance / Verification

- Verify script: `sbdocs/9-System/scripts/verify-260614-outbox-stuck-aggregate-metric.sh` — `Result: N pass, 0 fail` required before sign-off.
- All §7 unit + Testcontainers tests green via `mvn verify`.
- AC-7 EXPLAIN recorded here before flipping the sysprop in any environment.
- On completion, update this §11 with commit SHA(s), `mvn verify` summary, verify-script output, and the EXPLAIN plan node — then flip `status: draft → implemented` and link the PR (per the project plan-status directive).

### Implementation record (2026-06-14)

- **Status:** implemented · **Commit:** `709ec61` · **PR:** [SiteBossInc/wms2-api#46](https://github.com/SiteBossInc/wms2-api/pull/46) → `develop`.
- **Files:** `OutboxMessageRepository` (real `findStuckAggregateStats()` native query), `OutboxDispatchService` (gated `sampleStuckAggregates()`), `OutboxDispatcherJob` (two `MultiGauge`s + clear-on-lock-busy/empty-tenant), `WmsConstants` (gate key), new `OutboxStuckAggregateView`; tests `OutboxDispatchServiceUnitTest`, `OutboxDispatcherJobUnitTest`, `OutboxStuckAggregateIntegrationTest`.
- **Targeted tests:** `mvn test -Dtest=OutboxDispatchServiceUnitTest,OutboxDispatcherJobUnitTest,OutboxStuckAggregateIntegrationTest` → **Tests run: 24, Failures: 0, Errors: 0** (4 IT + 10 job + 10 service), BUILD SUCCESS.
- **Verify script:** `Result: 20 pass, 0 fail, 0 skip`.
- **Full suite:** 4202 run / **4 failures — all pre-existing on `develop`** (`BillofladingUnitTest` shipped-null, `RestExceptionHandlerUnitTest` OptionalGet, `UtilRestControllerUnitTest` ×2); zero new failures from this change.
- **Review:** architect SOUND-WITH-CHANGES → APPROVE; code-reviewer REQUEST CHANGES → **APPROVE** after fixes (0 CRITICAL; 2 MAJOR resolved: IT renamed `*IntegrationTest` so failsafe runs it; projection-binding documented against `CyclecountPositionListView` precedent — Spring-Data binding test deferred to SBDEV-2217 harness debt).
- **Query DB-validated** against real PostgreSQL via the Testcontainers IT (results); cost plans cheaply (~180 at 5k rows). **AC-7 production-sized EXPLAIN still open** before enabling the sysprop in prod.

### Horizontal Scalability Validation

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | In-JVM state | **Yes (handled)** | `MultiGauge` is per-replica; only the advisory-lock holder writes real rows; non-holders clear theirs on lock-busy (§3.4). Single-writer per tick. |
| 2 | Connection pool math | **Yes (negligible)** | +1 indexed count per *enabled* tenant inside the already-pinned advisory-lock window; default OFF. No new pool. |
| 3 | Scheduled jobs | **Yes** | Piggybacks the existing advisory-locked `OutboxDispatcherJob`; no new `@Scheduled`, no new lock id. |
| 4 | Long transactions | **No** | Read-only single query; no `@Transactional` added. |
| 5 | Request affinity | **N/A** | Background job. |
| 6 | Retry / idempotency | **N/A** | Read-only sampling; nothing mutated. |
| 7 | Tenant context | **Yes** | Query runs inside `TenantContext.setCurrentTenant(...)` already set by the loop; tags derive from the same `TenantProfile`. |
| 8 | Distributed lock correctness | **Yes** | Reuses `OUTBOX_DISPATCHER` (100008L); single-replica sampling guaranteed; stale-on-failover handled by clear-on-lock-busy. |
| 9 | Cache invalidation | **N/A** | Gate read uses existing `sysprops` Caffeine cache; no new cached entity. |
| 10 | External notifications | **No** | Emits a metric only; no OMS/HTTP call. |

### v2-only constraint checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled | **Yes** — projection query result is read inside the call; no lazy associations crossed. |
| 2 | Transaction manager | **N/A** — no write; no `@Transactional` added (read-only repo call). |
| 3 | `readOnly=true` | **N/A** — single repository query, no service-level tx wrapper introduced. |
| 4 | Caffeine invalidation | **N/A** — no cached entity written; gate read reuses `sysprops` cache. |
| 5 | Micrometer metrics | **Yes** — the deliverable; reuses `wms2.outbox.*` namespace + `MeterRegistry` already injected. |
| 6 | Jakarta namespace | **Yes** — new code is `jakarta.*`-native; no v1 port. |
| 7 | H2-compatible test SQL | **Yes (handled)** — native query uses `EXTRACT(EPOCH …)`/`||`; repo test is Testcontainers PG, not H2 (§7). |
| 8 | `BaseControllerTest` | **N/A** — no controller/endpoint added. |

### Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 1 | All callsites enumerated | ✓ §0 rows 1–5,7 → §3/§5; rows 6,8 excluded with rationale |
| 2 | Adjacent shapes | ✓ §2.3 — reuses `JobMetrics` gauge idiom + sysprop-gate pattern instead of new ones |
| 3 | Backward compatibility | ✓ §6 + "What does NOT change" |
| 4 | Concurrency | ✓ §3.4 single-writer MultiGauge + clear-on-lock-busy; HSV #1,#8 |
| 5 | Multi-tenant | ✓ §3.3/§3.4 tenant context + tenant/facility tags; HSV #7 |
| 6 | Error handling | ✓ gate returns null → no row; query failure is caught by the job's existing per-tenant `try/catch` (`OutboxDispatcherJob.java:69-71`) so one tenant's failure doesn't abort the tick |
| 7 | DB verified | ✗ — `db_verified: false`; live EXPLAIN deferred to AC-7 (dev MCP unreachable), rationale in frontmatter |
| 8 | Observability | ✓ the deliverable; §3.5 alert contract |
| 9 | Rollout / migration | ✓ §5.1 + §8; default-OFF sysprop, no Flyway |
| 10 | Test coverage | ✓ §7 unit + Testcontainers + manual + verify script |
| 11 | Cross-version (v1↔v2) | ✓ N/A — v1 has no outbox/SBDEV-2381 gate |
| 12 | Alternatives | ✓ §9 (six options) |
