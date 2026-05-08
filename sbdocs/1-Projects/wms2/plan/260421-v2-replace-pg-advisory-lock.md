---
title: "Replace pg_advisory_lock for test portability — v2/wms2-api"
ticket: ""
ticket_url: ""
type: refactor
priority: medium
status: draft
project: [wms2-api]
version: v2
requester: "nam.park@siteboss.net"
created: 2026-04-21
updated: 2026-04-21
related:
  - ./260420-v2-port-plpgsql-functions-to-java.md
  - ./260420-v2-integration-tests-h2-migration-report.md
  - ../../../3-Resources/architecture/wms2-scheduled-jobs-catalog.md
tags:
  - plan
  - draft
  - wms2
  - refactor
  - testing
  - scheduled-jobs
  - distributed-lock
  - h2
---

# Replace pg_advisory_lock for test portability — v2/wms2-api

**Ticket:** — (to be filed) — owner: nam.park@siteboss.net
**Project:** wms2-api | **Version:** v2 | **Type:** refactor
**Priority:** medium
**Status:** DRAFT — pending review
**Date:** 2026-04-21

---

## 1. Problem Statement

`AdvisoryLockService.java:37,54` uses PostgreSQL-only `pg_try_advisory_lock(:lockId)` / `pg_advisory_unlock(:lockId)` built-ins. Five scheduled jobs call it:

- `OrderReleaseJob` (lock id `100001`)
- `ReplenishOrderJob` (`100002`)
- `CleanUpOldMessagesJob` (`100003`)
- `StockSummaryExportJob` (`100004`)
- `ReleaseExpiredPickingOrdersFromUserJob` (`100005`)

This blocks the H2 migration goal in two ways:

1. **H2 doesn't implement `pg_try_advisory_lock`.** Any integration test that reaches a scheduled-job entry point (directly or via a scenario test) throws `org.h2.jdbc.JdbcSQLSyntaxErrorException` when the job's first `tryLock` call runs. The test can't even get past the mutex guard.
2. **H2-profile tests can't exercise the jobs at all** until the lock call is replaceable. This closes off the scenario-test layer recommended in the H2 migration plan §5.1.

The service is also a minor irritant architecturally: the only cross-replica synchronization mechanism in the codebase is coupled to PostgreSQL and is invisible to observability tooling (no metric for lock-held time, no alert on lock contention).

**Goal:** Make `AdvisoryLockService` engine-agnostic so scheduled-job tests run on H2, with zero behavior change in production PostgreSQL deployments. ShedLock / true multi-replica cron is out of scope — see §8.

---

## 2. Current Architecture

### 2.1 The service today

`src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java`:

```java
@Service
public class AdvisoryLockService {
    @PersistenceContext(unitName = "landlord")
    private EntityManager entityManager;

    @Transactional("landlordTransactionManager")
    public boolean tryLock(long lockId) {
        Boolean acquired = (Boolean) entityManager
            .createNativeQuery("SELECT pg_try_advisory_lock(:lockId)")
            .setParameter("lockId", lockId)
            .getSingleResult();
        // ...
    }

    @Transactional("landlordTransactionManager")
    public void unlock(long lockId) {
        entityManager
            .createNativeQuery("SELECT pg_advisory_unlock(:lockId)")
            .setParameter("lockId", lockId)
            .getSingleResult();
    }

    public static final class JobLockId {
        public static final long ORDER_RELEASE = 100001L;
        public static final long REPLENISH_ORDER = 100002L;
        public static final long CLEAN_UP_MESSAGES = 100003L;
        public static final long STOCK_SUMMARY_EXPORT = 100004L;
        public static final long RELEASE_EXPIRED_PICKING = 100005L;
    }
}
```

Key semantics to preserve:

- **Non-blocking.** `tryLock` returns immediately — `true` if acquired, `false` if held by another session.
- **Session-scoped lock.** Released when the JDBC connection returns to the pool (so JVM crashes don't leak locks).
- **Landlord DB.** Bound to the landlord persistence unit (`@PersistenceContext(unitName = "landlord")`) and landlord TM. All five job callers resolve the landlord datasource, not a tenant.
- **Try/finally pattern.** Every caller follows `if (!tryLock(...)) return; try { … } finally { unlock(...); }`.

### 2.2 Caller pattern (representative — `ReplenishOrderJob`)

```java
if (!advisoryLockService.tryLock(AdvisoryLockService.JobLockId.REPLENISH_ORDER)) {
    return;   // another replica / session holds it, skip this tick
}
try {
    // … business work …
} finally {
    advisoryLockService.unlock(AdvisoryLockService.JobLockId.REPLENISH_ORDER);
}
```

All 5 jobs look identical here.

### 2.3 Why it exists today

From `docs/plan/partial/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md:219`:

> **Deployment decision:** Only ONE replica will run with `app.cron=true` (confirmed by team). This eliminates duplicate job execution without code changes. ShedLock / advisory locks remain a future hardening option if the cron replica needs failover capability.

So in production today, the advisory lock is **defensive**, not load-bearing. Only one replica runs the jobs; there's no other session to race. The lock protects against:

- Developer accidentally setting `app.cron=true` on two replicas.
- Future failover scenario (multi-replica cron) if the deployment constraint is ever relaxed.
- Manual invocation of a job while a scheduled run is in flight (rare).

### 2.4 Affected locations

| # | File | Line | Description |
|---|---|---|---|
| 1 | `src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java` | 21-72 | Concrete class (to become an interface + impl) |
| 2 | `src/main/java/net/aim_ai/wms/schedulejob/OrderReleaseJob.java` | 61, 102 | `tryLock` / `unlock` call sites |
| 3 | `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java` | 84, 174 | Same |
| 4 | `src/main/java/net/aim_ai/wms/schedulejob/CleanUpOldMessagesJob.java` | 38, 79 | Same |
| 5 | `src/main/java/net/aim_ai/wms/schedulejob/StockSummaryExportJob.java` | 64, 114 | Same |
| 6 | `src/main/java/net/aim_ai/wms/schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java` | 46, 91 | Same |
| 7 | `src/test/java/net/aim_ai/wms/unit/schedulejob/*` | — | Existing job unit tests; verify they still pass with the abstraction |

---

## 3. Design / Proposed Fix

### 3.1 Strategy — interface + two implementations, profile-selected

Extract an interface, keep the current SQL path as the production default, add an in-memory implementation for H2-profile tests. Minimum-viable change; no new tables, no new dependencies.

#### 3.1.1 New interface

```java
package net.aim_ai.wms.service;

public interface JobLockService {
    boolean tryLock(long lockId);
    void unlock(long lockId);

    final class JobLockId {
        public static final long ORDER_RELEASE = 100001L;
        public static final long REPLENISH_ORDER = 100002L;
        public static final long CLEAN_UP_MESSAGES = 100003L;
        public static final long STOCK_SUMMARY_EXPORT = 100004L;
        public static final long RELEASE_EXPIRED_PICKING = 100005L;
        private JobLockId() {}
    }
}
```

#### 3.1.2 Production implementation — unchanged SQL

Rename `AdvisoryLockService` → `PostgresAdvisoryJobLockService`, implement `JobLockService`, keep the `pg_try_advisory_lock` / `pg_advisory_unlock` native queries. Activated when not running the H2 test profile:

```java
@Service
@Profile("!h2")  // or: @ConditionalOnProperty(name = "wms.job-lock.engine", havingValue = "postgres", matchIfMissing = true)
public class PostgresAdvisoryJobLockService implements JobLockService {
    // body identical to current AdvisoryLockService
}
```

Prefer `@ConditionalOnProperty` over profile-based activation — it's explicit and allows unit tests to override without touching profiles. Default: `postgres`.

#### 3.1.3 Test/H2 implementation — in-memory

```java
@Service
@ConditionalOnProperty(name = "wms.job-lock.engine", havingValue = "in-memory")
public class InMemoryJobLockService implements JobLockService {
    private final ConcurrentMap<Long, Boolean> heldLocks = new ConcurrentHashMap<>();

    @Override
    public boolean tryLock(long lockId) {
        return heldLocks.putIfAbsent(lockId, Boolean.TRUE) == null;
    }

    @Override
    public void unlock(long lockId) {
        heldLocks.remove(lockId);
    }
}
```

**What this is and isn't:**

- **Is:** a per-JVM mutex. Adequate for tests where one JVM runs both the job and the assertion.
- **Isn't:** a distributed lock. Never deploy this to production. The `@ConditionalOnProperty` guard + an explicit warning log at startup (see §3.2) prevent accidental prod activation.

### 3.2 Safety: fail-loud if misconfigured

Add a startup check so a misconfigured prod doesn't silently run with the in-memory lock:

```java
@Bean
ApplicationRunner jobLockEngineCheck(
        @Value("${wms.job-lock.engine:postgres}") String engine,
        @Value("${spring.profiles.active:}") String activeProfiles,
        JobLockService jobLockService) {
    return args -> {
        if ("in-memory".equals(engine) && !activeProfiles.contains("h2") && !activeProfiles.contains("test")) {
            throw new IllegalStateException(
                "wms.job-lock.engine=in-memory is only valid in test/h2 profiles. " +
                "In production, locks MUST be postgres-backed.");
        }
        LOG.info("Job lock engine: {} (impl: {})", engine, jobLockService.getClass().getSimpleName());
    };
}
```

### 3.3 Call-site changes

All 5 job classes change **one type** — `AdvisoryLockService advisoryLockService` → `JobLockService jobLockService` — and update the `JobLockId` import path from `AdvisoryLockService.JobLockId` to `JobLockService.JobLockId`. Logic is unchanged.

### 3.4 Why not ShedLock?

ShedLock is the right answer for "make cron safe on multiple replicas" and was proposed in archived plans (`260424-REPLENISHMENT_PERFORMANCE_PLAN.md:992-1024`, `260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md:270`). It's **not** the right answer for this plan's goal:

- ShedLock needs a new Flyway migration for its lock table — more surface for the H2 migration to cope with.
- ShedLock's JDBC provider works on both PG and H2, but requires H2 PG-compat mode — same constraint we already have to handle for repo SQL.
- ShedLock changes cron-boundary semantics (locks at schedule-time, not work-time) which needs its own test + soak cycle.
- Current prod deployment (one replica runs cron) doesn't need distributed-lock correctness to change.

Decision: **defer ShedLock to a separate plan** only if/when "multi-replica cron" is a requirement. Today's goal is test compat, and the interface we introduce here makes a ShedLock migration trivial later (add a third impl, no caller changes).

### 3.5 Alternative considered — a DB table-based lock

Replace `pg_advisory_lock` with a row in a new `scheduled_job_lock(lock_id PK, locked_at, expires_at)` table, using `INSERT … WHERE expires_at < now()` semantics. Works on both engines with dialect tweaks (PG `ON CONFLICT`, H2 `MERGE INTO`).

**Rejected because:**
- Adds schema surface (new migration, new entity) for a problem that already has a sufficient solution in prod.
- Introduces a new failure mode: a crashed replica holds the lock until `expires_at`. Current advisory lock releases automatically on connection return.
- More complex than necessary for a test-compat goal.

Preserve the option: if ShedLock is later chosen, it's effectively this design done well.

---

## 4. V1/V2 Applicability

V2-only. V1/wms-api does **not** use `pg_advisory_lock` — scheduled jobs in v1 rely on the single-replica deployment assumption alone, without even the defensive lock. No port needed.

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| Advisory lock | Not present | Present in `AdvisoryLockService` | V2-only refactor |
| Scheduled jobs | Same 5 conceptual jobs (`OrderRelease`, `Replenish`, etc.) | Same | Patterns / lock keys don't cross versions |
| Test impact | Tests don't touch this path | Tests on H2 need this refactor | V2-only benefit |

### What does NOT need porting

V1's scheduled-job tests already run (no advisory lock to trip over); they're not part of this scope.

---

## 5. Implementation Checklist

Estimated effort: **1–2 engineering days** for code change + review; test validation is the hour-consuming part.

- [ ] Create `JobLockService` interface in `net.aim_ai.wms.service`. Move `JobLockId` into it.
- [ ] Rename `AdvisoryLockService` → `PostgresAdvisoryJobLockService`; add `implements JobLockService`; add `@ConditionalOnProperty(name = "wms.job-lock.engine", havingValue = "postgres", matchIfMissing = true)`.
- [ ] Add `InMemoryJobLockService` with `@ConditionalOnProperty(name = "wms.job-lock.engine", havingValue = "in-memory")`.
- [ ] Update the 5 scheduled-job classes: change the field type to `JobLockService`; update `JobLockId` import paths (5 files × 2 references each = 10 sites).
- [ ] Add the startup-safety `ApplicationRunner` bean in a config class (e.g., `ScheduledJobConfig`).
- [ ] Add `wms.job-lock.engine=in-memory` to the H2 test profile (`application-integration.properties` once it exists; otherwise inject via `H2TestExtension`).
- [ ] Update existing unit tests for the 5 jobs — the mocked `AdvisoryLockService` mock target changes to `JobLockService`.
- [ ] Add two focused tests for the lock services themselves (see §6).
- [ ] Grep the codebase for `AdvisoryLockService` after rename — confirm zero stragglers.
- [ ] Smoke-test a local run with `wms.job-lock.engine=postgres` against a real PostgreSQL dev DB; verify `pg_locks` shows the lock when held (`SELECT * FROM pg_locks WHERE locktype='advisory'`).
- [ ] Document the engine property in `application.properties` and `application_dev.properties` (commented default: `wms.job-lock.engine=postgres`).
- [ ] Code review.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| Postgres impl — lock acquired by single caller | `tryLock(100)` twice in same JVM but different DB connections | First `true`, second `false` (PG holds lock session-scoped) |
| Postgres impl — lock released on unlock | `tryLock(100)` → `unlock(100)` → `tryLock(100)` same session | All three calls succeed |
| In-memory impl — single JVM contention | `tryLock(100)` then `tryLock(100)` from another thread without unlock | First `true`, second `false` |
| In-memory impl — release behavior | `tryLock(100)` → `unlock(100)` → `tryLock(100)` | All three succeed |
| Job test — lock contention path | Set up `InMemoryJobLockService`; prime the lock; call job entry point | Job short-circuits (returns without running work), per existing try/fail-skip pattern |
| Job test — happy path | Job entry point with free lock | Work executes, lock released in finally |
| Startup safety | Boot app with `wms.job-lock.engine=in-memory` and profile != test | `ApplicationRunner` throws, context fails — regression-safe |

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `PostgresAdvisoryJobLockServiceIT` (new, Testcontainers-only) | `tryLock_sameSession_acquiresOnce` | PG-specific semantics validated |
| `PostgresAdvisoryJobLockServiceIT` | `tryLock_differentConnection_contends` | Real advisory-lock contention |
| `InMemoryJobLockServiceTest` (new, unit) | `tryLock_thenTryLock_returnsFalse` | Self-consistency |
| `InMemoryJobLockServiceTest` | `unlock_thenTryLock_returnsTrue` | Release works |
| `InMemoryJobLockServiceTest` | `concurrent_tryLocks_exactlyOneWinner` | Thread-safe with `ConcurrentHashMap.putIfAbsent` |
| `JobLockEngineCheckTest` (new, unit) | `inMemory_outsideTestProfile_throws` | Fail-loud guard |
| Existing `OrderReleaseJobTest`, `ReplenishOrderJobTest`, `CleanUpOldMessagesJobTest`, `StockSummaryExportJobTest`, `ReleaseExpiredPickingOrdersFromUserJobTest` | — | **Update mock target from `AdvisoryLockService` to `JobLockService`.** Assertions unchanged. |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=*JobLockService*` | | |
| `mvn test -Dtest=*Job*` (existing job tests + new) | | |
| `mvn verify -Dtest=PostgresAdvisoryJobLockServiceIT` | | |
| `mvn verify` (full, postgres profile) | | |
| `mvn verify` (H2 profile, once H2 plan Phase 1 lands) | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Cross-JVM contention test for `InMemoryJobLockService` | By design it's per-JVM. Deploying it cross-replica is what the `ApplicationRunner` guard blocks. |
| Soak test of `PostgresAdvisoryJobLockService` under concurrent load | Implementation is unchanged from today's `AdvisoryLockService`; prod behavior has been stable. |
| Lock reentrancy | Current callers never re-enter. Not introducing new semantics. |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | **Yes — the `InMemoryJobLockService` implementation** | Guarded against prod use by `@ConditionalOnProperty` + startup `ApplicationRunner` check. Production uses `PostgresAdvisoryJobLockService` which holds state in the DB, not the JVM. |
| 2 | **Connection pool math** | Change per-request DB connection usage? | No | Same one-statement landlord query per `tryLock`/`unlock`. |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` / cron job? | No | Only the lock mechanism inside existing jobs changes. |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls? | No | Each lock op is a single stmt, session-scoped release. |
| 5 | **Request affinity** | Assume a follow-up request lands on the same replica? | No | Scheduled jobs are not request-scoped. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics? | No change from today | Today's behavior: if the lock holder crashes, the lock auto-releases on connection return — safe for retry. Preserved. |
| 7 | **Tenant context** | Use `TenantContext` / `ThreadLocal` across async boundaries? | No | Runs on landlord DB; tenant-context-irrelevant. |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock across replicas? | **Refactors the existing distributed lock** | Production impl (`PostgresAdvisoryJobLockService`) is byte-identical semantics to today. Prod deployment still relies on the single-replica-cron rule. ShedLock for true multi-replica cron is out of scope (see §8). |
| 9 | **Cache invalidation** | Write to an entity that is cached? | No | — |
| 10 | **External notifications** | Send HTTP / message inside a transaction? | No | — |

### Evidence (fill in for any "Yes" row)

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 1 | Guard bean `jobLockEngineCheck` throws on in-memory + non-test profile | `src/main/java/net/aim_ai/wms/config/ScheduledJobConfig.java` (new, Phase 1) |
| 1 | `JobLockEngineCheckTest.inMemory_outsideTestProfile_throws` | new unit test |
| 8 | `PostgresAdvisoryJobLockServiceIT` reproduces current advisory-lock behavior | new IT |

---

## 8. Notes

### Rollback

Interface + profile-selected bean means rollback is trivial:

- **Dev/test:** flip `wms.job-lock.engine=postgres` and restart.
- **Production:** no operational rollback needed — prod defaults to `postgres` and never changes.
- **Code rollback:** single revert — the refactor is additive (new interface, renamed class); the 5 job-site changes are type swaps that compile without behavior change.

### Future: ShedLock migration (separate plan, NOT this plan)

If multi-replica cron becomes a requirement, add a third impl:

```java
@Service
@ConditionalOnProperty(name = "wms.job-lock.engine", havingValue = "shedlock")
public class ShedlockJobLockService implements JobLockService { … }
```

Plus a Flyway migration for the ShedLock table. Call sites don't change — that's the point of introducing the interface now. Estimate: 2–3 days once ShedLock dependency and soak window are agreed.

Referenced prior work:
- `v2/wms2-api/docs/plan/completed/260424-REPLENISHMENT_PERFORMANCE_PLAN.md:992-1052` — concrete ShedLock sketch.
- `v2/wms2-api/docs/plan/partial/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md:219,270` — deployment context.

### Observability upside (free)

Because the engine is now an injected `JobLockService`, adding Micrometer metrics for lock-held time, acquire-failure count, and per-job lock duration is a one-line bean wrapper (`TimedJobLockService` decorator). Not in this plan's scope but trivially enabled.

### Sanity check: existing scheduled jobs are accounted for

The architecture doc `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md` should list all scheduled jobs. Verify parity with the 5 `JobLockId` constants during implementation — if a sixth job exists without an advisory lock, decide whether it should gain one.

### Out of scope

- ShedLock integration (see above).
- Changing the `app.cron=true`-single-replica deployment model.
- Adding new scheduled jobs.
- Per-tenant lock granularity (today's locks are global across all tenants for a given job type — per-tenant locks would be a separate design).
- Observability hooks (future ticket).

### Decisions needed before kickoff

- Approve interface name: `JobLockService` (proposed). Alternatives: `DistributedLockService`, `SchedulerMutexService`.
- Approve property name: `wms.job-lock.engine` (proposed). Alternatives: `wms.scheduler.lock-engine`, `wms.job.lock.impl`.
- Confirm no production deployment requires `in-memory` engine (it shouldn't — the guard will block it if it tries).
- Confirm test profile injection strategy: property file vs `H2TestExtension` programmatic injection. Either works; tied to H2 plan's Phase 1 decision on whether `application-integration.properties` exists.
