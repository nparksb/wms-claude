---
title: "Replace pg_advisory_lock for test portability — v2/wms2-api"
ticket: ""
ticket_url: ""
type: refactor
priority: medium
status: reviewed
project: [wms2-api]
version: v2
requester: "nam.park@siteboss.net"
created: 2026-04-21
updated: 2026-06-22
related:
  - ./260420-v2-port-plpgsql-functions-to-java.md
  - ./260420-v2-integration-tests-h2-migration-report.md
  - ../../../3-Resources/architecture/wms2-scheduled-jobs-catalog.md
tags:
  - plan
  - reviewed
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
**Status:** REVIEWED (2026-06-22) — approved; lock confirmed load-bearing for outbox + REST-idempotency paths (rollup §9 D2), parallel/rename-first (D6)
**Date:** 2026-04-21

> **Re-grounding note (2026-06-17):** Re-verified against HEAD on 2026-06-17; current state below reflects the live code, not the 2026-04-21 snapshot. Since the original draft the lock surface grew from 5 jobs to **8** (SBDEV-2221 added `OUTBOX_DISPATCHER`, plus `STALE_CLUB_BATCH_CLEANUP` and `CLEANUP_REST_IDEMPOTENCY`), the production `AdvisoryLockService` was rewritten to a **raw-JDBC ThreadLocal-connection-pinning** implementation (no longer `@PersistenceContext`/`@Transactional`), a reflection-based contract test now references `AdvisoryLockService.JobLockId`, and at least the outbox path now runs `@Scheduled` on **all** replicas — making the lock load-bearing, not merely defensive (see §2.3). Every numbered claim below has been re-checked against current line numbers.

---

## 1. Problem Statement

`AdvisoryLockService.java:59,95` uses PostgreSQL-only `pg_try_advisory_lock(?)` / `pg_advisory_unlock(?)` built-ins (positional `?` params over raw JDBC, not JPQL named params). **Eight** scheduled jobs call it:

- `OrderReleaseJob` (lock id `100001`)
- `ReplenishOrderJob` (`100002`)
- `CleanUpOldMessagesJob` (`100003`)
- `StockSummaryExportJob` (`100004`)
- `ReleaseExpiredPickingOrdersFromUserJob` (`100005`)
- `StaleClubBatchCleanupJob` (`100006`)
- `RestIdempotencyCleanupJob` (`100007`)
- `OutboxDispatcherJob` (`100008` — SBDEV-2221)

This blocks the H2 migration goal in two ways:

1. **H2 doesn't implement `pg_try_advisory_lock`.** Any integration test that reaches a scheduled-job entry point (directly or via a scenario test) throws `org.h2.jdbc.JdbcSQLSyntaxErrorException` when the job's first `tryLock` call runs. The test can't even get past the mutex guard.
2. **H2-profile tests can't exercise the jobs at all** until the lock call is replaceable. This closes off the scenario-test layer recommended in the H2 migration plan §5.1.

The service is also a minor irritant architecturally: the only cross-replica synchronization mechanism in the codebase is coupled to PostgreSQL and is invisible to observability tooling (no metric for lock-held time, no alert on lock contention).

**Goal:** Make `AdvisoryLockService` engine-agnostic so scheduled-job tests run on H2, with zero behavior change in production PostgreSQL deployments. ShedLock / true multi-replica cron is out of scope — see §8.

---

## 2. Current Architecture

### 2.1 The service today

`src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java` (129 lines). The real implementation is **raw JDBC with a ThreadLocal-pinned physical connection** — NOT `@PersistenceContext`/`@Transactional`/`EntityManager`. The class Javadoc states explicitly that the ThreadLocal exists to avoid the lock-leak that `@Transactional` causes by returning the connection to the pool between `tryLock()` and `unlock()`:

```java
@Service
public class AdvisoryLockService {

    private static final Logger LOG = LoggerFactory.getLogger(AdvisoryLockService.class);

    private final DataSource landlordDataSource;

    /** Holds the raw connection between tryLock() and unlock() on the same thread. */
    private final ThreadLocal<Connection> lockedConnection = new ThreadLocal<>();

    public AdvisoryLockService(@Qualifier("landlordDataSource") DataSource landlordDataSource) {
        this.landlordDataSource = landlordDataSource;
    }

    public boolean tryLock(long lockId) {
        try {
            Connection conn = landlordDataSource.getConnection();
            try (PreparedStatement ps = conn.prepareStatement("SELECT pg_try_advisory_lock(?)")) {
                ps.setLong(1, lockId);
                try (ResultSet rs = ps.executeQuery()) {
                    rs.next();
                    boolean acquired = rs.getBoolean(1);
                    if (acquired) {
                        lockedConnection.set(conn);   // PIN the physical connection
                    } else {
                        conn.close();                 // not acquired → return immediately
                    }
                    return acquired;
                }
            } catch (SQLException e) {
                conn.close();
                throw e;
            }
        } catch (SQLException e) {
            LOG.error("Failed to acquire advisory lock {}", lockId, e);
            return false;
        }
    }

    public void unlock(long lockId) {
        Connection conn = lockedConnection.get();     // retrieve the pinned connection
        if (conn == null) { /* warn: tryLock not called / already released */ return; }
        try (PreparedStatement ps = conn.prepareStatement("SELECT pg_advisory_unlock(?)")) {
            ps.setLong(1, lockId);
            try (ResultSet rs = ps.executeQuery()) { rs.next(); /* warns if returns false */ }
        } catch (SQLException e) {
            LOG.error("Failed to release advisory lock {}", lockId, e);
        } finally {
            lockedConnection.remove();                // clear ThreadLocal
            try { conn.close(); } catch (SQLException ignored) {}  // return conn to pool
        }
    }

    public static final class JobLockId {
        public static final long ORDER_RELEASE = 100001L;
        public static final long REPLENISH_ORDER = 100002L;
        public static final long CLEAN_UP_MESSAGES = 100003L;
        public static final long STOCK_SUMMARY_EXPORT = 100004L;
        public static final long RELEASE_EXPIRED_PICKING = 100005L;
        public static final long STALE_CLUB_BATCH_CLEANUP = 100006L;
        public static final long CLEANUP_REST_IDEMPOTENCY = 100007L;
        public static final long OUTBOX_DISPATCHER = 100008L; // SBDEV-2221
        private JobLockId() {}
    }
}
```

Key semantics to preserve:

- **Non-blocking.** `tryLock` returns immediately — `true` if acquired, `false` if held by another session.
- **Session-scoped lock pinned by a ThreadLocal connection.** The physical JDBC connection acquired in `tryLock()` is stashed in a `ThreadLocal<Connection>` and only returned to the pool in `unlock()`. **This pinning MUST be preserved.** A naive rewrite back to `@PersistenceContext`/`@Transactional` + `EntityManager.createNativeQuery` would reintroduce the exact lock-leak the current code was written to fix: under `@Transactional`, the connection is returned to the pool when the method returns, so the subsequent `pg_advisory_unlock` runs on a *different* physical connection and the PG session-level lock is never actually released (leaks until that original connection is reused or the backend dies). The proposed prod impl below keeps this body verbatim.
- **Auto-release on connection loss.** Because the lock is a PG *session*-level lock tied to the pinned connection, a JVM crash (or the connection dying) releases it server-side automatically — locks don't survive a dead replica. **The in-memory test impl does NOT preserve this** (see §3.1.3 / §5 / §7).
- **Landlord DB.** Bound to the landlord datasource via constructor injection of `@Qualifier("landlordDataSource") DataSource`. All eight job callers run against the landlord datasource, not a tenant.
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

All 8 jobs look identical here (the `JobLockId` constant differs per job).

### 2.3 Why it exists today — and why it is now load-bearing for the outbox path

The 2026-04-21 draft asserted the lock was purely *defensive* because "only one replica runs `app.cron=true`". **That framing is now only partially true** and must not be carried forward unqualified. Re-grounding against HEAD found two distinct scheduling mechanisms:

1. **`SchedulingConfiguration`** (`@ConditionalOnProperty(name="app.cron", havingValue="true")`, `src/main/java/net/aim_ai/wms/schedulejob/SchedulingConfiguration.java:24`) programmatically registers **6** jobs (`cleanUpOldMessages`, `orderRelease`, `replenish`, `stockSummaryExport`, `releaseExpiredPickingOrdersFromUser`, `staleClubBatchCleanup`) only when `app.cron=true`. For these, the original single-replica-cron framing still holds: in prod only one replica has `app.cron=true`, so the lock is defensive.

2. **`@EnableScheduling` is unconditional on ALL replicas** (`src/main/java/net/aim_ai/wms/config/SchedulingEnablementConfig.java` — explicitly documented: "Enables the Spring scheduling infrastructure on ALL replicas (unconditionally)"). The two `@Scheduled`-annotated jobs — `OutboxDispatcherJob` (`@Scheduled(cron = "${app.cron.outbox-dispatcher:*/15 * * * * *}")`, default 15 s baked in, **no `app.cron` gate**) and `RestIdempotencyCleanupJob` (`@Scheduled(cron = "${app.cron.cleanup-rest-idempotency}")`) — therefore fire on **every** replica, not just the cron replica. For these, the advisory lock is the **only** thing preventing N-replica duplicate execution. `OutboxDispatcherJob`'s own Javadoc confirms this: "acquires an advisory lock so only one replica runs per tick". For the outbox dispatcher the lock is **load-bearing, not defensive** — see Open Question Q1.

The originally-cited deployment note still reads:

> **Deployment decision:** Only ONE replica will run with `app.cron=true` (confirmed by team). This eliminates duplicate job execution without code changes. ShedLock / advisory locks remain a future hardening option if the cron replica needs failover capability.
> — `docs/plan/partial/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md:219`

…but that note predates SBDEV-2221's `@Scheduled` outbox/idempotency jobs, which deliberately run everywhere and rely on the lock. So the lock today protects against:

- **(Load-bearing)** N-replica duplicate dispatch of the outbox and idempotency-cleanup `@Scheduled` jobs, which run on every replica by design.
- **(Defensive)** Developer accidentally setting `app.cron=true` on two replicas (for the 6 `SchedulingConfiguration` jobs).
- **(Defensive)** Future failover scenario (multi-replica cron) if the deployment constraint is ever relaxed.
- **(Defensive)** Manual invocation of a job while a scheduled run is in flight (rare).

**Implication for this plan:** because the lock is load-bearing for the outbox path, the in-memory test substitute (§3.1.3) carries a higher correctness bar than the original draft assumed — any test that exercises the outbox dispatcher under the in-memory engine must not silently leak a lock across tests (see §3.1.3 auto-release caveat and §5 reset hook).

> **Open Question Q1 (outbox lock load-bearing):** `@EnableScheduling` running unconditionally + `OutboxDispatcherJob` having no `app.cron` gate strongly implies the outbox dispatcher runs on all replicas and depends on the advisory lock for single-flight correctness. This was inferred from `SchedulingEnablementConfig`, the missing gate, and the job's own Javadoc — but the **production deployment topology** (how many replicas, whether something external still pins outbox dispatch to one pod) was not independently confirmed. If the outbox path is genuinely multi-replica, the lock is correctness-critical and the in-memory engine must never reach a multi-replica path (the §3.2 guard already blocks prod use; this raises the bar on test fidelity). Confirm replica count / outbox topology with the deploy owner before treating the in-memory impl as a drop-in.

### 2.4 Affected locations

| # | File | Lines (tryLock / unlock + injection) | Description |
|---|---|---|---|
| 1 | `src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java` | 35-129 (class); `tryLock` line 56, `unlock` line 88; `JobLockId` 117-128 | Concrete class (to become an interface + impl); `JobLockId` to move into the new interface |
| 2 | `src/main/java/net/aim_ai/wms/schedulejob/OrderReleaseJob.java` | import 13; field 45; ctor param 54; tryLock 67; unlock 119 | `tryLock` / `unlock` call sites + type swap |
| 3 | `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java` | import 13; field 56; ctor param 72; tryLock 100; unlock 199 | Same |
| 4 | `src/main/java/net/aim_ai/wms/schedulejob/CleanUpOldMessagesJob.java` | import 10; field 28; ctor param 35; tryLock 46; unlock 98 | Same |
| 5 | `src/main/java/net/aim_ai/wms/schedulejob/StockSummaryExportJob.java` | import 19; field 56; ctor param 67; tryLock 82; unlock 147 | Same |
| 6 | `src/main/java/net/aim_ai/wms/schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java` | import 11; field 33; ctor param 41; tryLock 53; unlock 109 | Same |
| 7 | `src/main/java/net/aim_ai/wms/schedulejob/StaleClubBatchCleanupJob.java` | import 6; field 24; ctor param 29; tryLock 37; unlock 74 | Same |
| 8 | `src/main/java/net/aim_ai/wms/schedulejob/RestIdempotencyCleanupJob.java` | import 7; field 32; ctor param 36; tryLock 50; unlock 78 | Same (Javadoc at line 21 also names `AdvisoryLockService.JobLockId.CLEANUP_REST_IDEMPOTENCY` — update the comment too) |
| 9 | `src/main/java/net/aim_ai/wms/schedulejob/OutboxDispatcherJob.java` | import 11; field 35; ctor param 44; tryLock 59; unlock 110 | Same (load-bearing — see §2.3) |
| 10 | `src/main/java/net/aim_ai/wms/schedulejob/SchedulingConfiguration.java` | wildcard import `net.aim_ai.wms.service.*` (line 8) | Constructs 6 of the jobs; no direct `AdvisoryLockService` reference, but recompiles after the rename — verify |
| 11 | `src/test/java/net/aim_ai/wms/unit/service/AdvisoryLockServiceJobLockIdContractTest.java` | refs `AdvisoryLockService.JobLockId` at line 29 (`getField("CLEANUP_REST_IDEMPOTENCY")`) via reflection | **Will break on rename** — retarget to `JobLockService.JobLockId` (see §3.6, §5, §6) |
| 12 | `src/test/java/net/aim_ai/wms/unit/schedulejob/*` | — | Existing job unit tests; mocks of `AdvisoryLockService` retarget to `JobLockService` |

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
        public static final long STALE_CLUB_BATCH_CLEANUP = 100006L;
        public static final long CLEANUP_REST_IDEMPOTENCY = 100007L;
        public static final long OUTBOX_DISPATCHER = 100008L; // SBDEV-2221
        private JobLockId() {}
    }
}
```

All **8** constants must be carried across verbatim (same names, same `long` values) so the reflection-based contract test (§3.6) and every caller resolve the moved nested class without value drift. Keep the `// SBDEV-2221` comment on `OUTBOX_DISPATCHER`.

#### 3.1.2 Production implementation — current raw-JDBC body preserved verbatim

Rename `AdvisoryLockService` → `PostgresAdvisoryJobLockService`, implement `JobLockService`, and **keep the existing raw-JDBC ThreadLocal-connection-pinning body exactly as it is today** (`landlordDataSource.getConnection()` → `pg_try_advisory_lock(?)` → pin in `ThreadLocal<Connection>`; `unlock` retrieves the pinned connection, runs `pg_advisory_unlock(?)`, closes it, clears the ThreadLocal). Do **not** "simplify" it back to `@PersistenceContext`/`@Transactional`/`EntityManager` — that reintroduces the connection-return-to-pool lock-leak documented in §2.1.

Activation is by property only (there is **no `h2` profile** — the H2 test profile is named `integration`; see §3.2):

```java
@Service
@ConditionalOnProperty(name = "wms.job-lock.engine", havingValue = "postgres", matchIfMissing = true)
public class PostgresAdvisoryJobLockService implements JobLockService {
    // body identical to today's AdvisoryLockService:
    //   constructor injection of @Qualifier("landlordDataSource") DataSource,
    //   ThreadLocal<Connection> lockedConnection,
    //   raw PreparedStatement("SELECT pg_try_advisory_lock(?)") / pg_advisory_unlock(?)
}
```

Use `@ConditionalOnProperty` (default `postgres` via `matchIfMissing = true`) — **not** `@Profile`. The earlier draft suggested `@Profile("!h2")`; that is removed entirely because **no `h2` profile exists** in this codebase. Property-based activation is also explicit and lets unit tests override the engine without touching `spring.profiles.active`.

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

    /**
     * TEST-ONLY. Clears all held locks. The in-memory impl has NO auto-release —
     * a lock leaked by one test (no unlock in finally, or a thrown assertion before
     * unlock) stays held and silently breaks the next test that needs that lock id.
     * Wire this into the integration test base / a @BeforeEach so each test starts clean.
     */
    public void reset() {
        heldLocks.clear();
    }
}
```

**What this is and isn't:**

- **Is:** a per-JVM mutex. Adequate for tests where one JVM runs both the job and the assertion.
- **Isn't:** a distributed lock. Never deploy this to production. The `@ConditionalOnProperty` guard + a fail-loud startup check (see §3.2) prevent accidental prod activation.
- **Does NOT preserve auto-release-on-crash.** The production PG impl releases the lock server-side when the pinned connection is lost (JVM crash, dead backend). The `ConcurrentHashMap` impl releases **only** on an explicit `unlock(lockId)`. Within a single test JVM this means a leaked lock (missing/short-circuited `finally`) persists across tests in the same JVM, producing **order-dependent flakiness**: a later test asking for the same lock id gets `false` and short-circuits instead of running its work.
- **Mitigation (required):** add the `reset()` hook above, invoke it per test (integration test base `@BeforeEach`, or a JUnit extension), and add a regression test asserting reset-between-tests actually frees a previously-held lock (see §6). Document the no-auto-release divergence wherever the in-memory engine is enabled.

### 3.2 Safety: fail-loud if misconfigured (positive allowlist, NOT substring scan)

Add a startup check so a misconfigured prod doesn't silently run with the in-memory lock. **The original draft's substring scan (`!activeProfiles.contains("h2") && !activeProfiles.contains("test")`) is wrong on two counts and must not be used:**

1. **It refers to a non-existent `h2` profile.** The H2/in-memory test profile in this codebase is named **`integration`** (`src/test/resources/application-integration.properties`; `BaseIntegrationTest`/`BaseRepositoryIntegrationTest`/etc. use `@ActiveProfiles("integration")`). There is no `h2` profile and no `test` profile. So the original guard would *wrongly throw* on a legitimate `integration`-profile run that sets `wms.job-lock.engine=in-memory`.
2. **Substring matching fails open.** `contains("test")` matches any prod profile name that merely *contains* the substring "test" (e.g. `latest`, `e2e-staging-test-shadow`), silently permitting the in-memory engine in production.

Replace it with a **positive allowlist** of profiles permitted to run the in-memory engine — reject the `in-memory` engine for anything not explicitly allowlisted, using exact membership (not substring):

```java
@Bean
ApplicationRunner jobLockEngineCheck(
        @Value("${wms.job-lock.engine:postgres}") String engine,
        Environment environment,
        JobLockService jobLockService) {
    // Exact profile names permitted to use the in-memory engine. Membership, not substring.
    Set<String> allowedInMemoryProfiles = Set.of("integration", "integration-pg");
    return args -> {
        if ("in-memory".equals(engine)) {
            boolean permitted = Arrays.stream(environment.getActiveProfiles())
                    .anyMatch(allowedInMemoryProfiles::contains);
            if (!permitted) {
                throw new IllegalStateException(
                    "wms.job-lock.engine=in-memory is only valid under the test profiles "
                    + allowedInMemoryProfiles + " (active: "
                    + Arrays.toString(environment.getActiveProfiles())
                    + "). In production, locks MUST be postgres-backed.");
            }
        }
        LOG.info("Job lock engine: {} (impl: {})", engine, jobLockService.getClass().getSimpleName());
    };
}
```

Notes:
- `integration` is confirmed present (the H2 integration profile). `integration-pg` is included as a forward-looking allowlist entry for a Postgres-backed integration variant; if it is not actually introduced, drop it — the allowlist must list **only profiles that should be allowed to run in-memory**. (As of HEAD only `integration` is confirmed; verify `integration-pg` before merging.)
- Use `Environment.getActiveProfiles()` (returns the exact profile array) rather than parsing the raw `spring.profiles.active` string, so the membership check is unambiguous.

### 3.3 Call-site changes

All **8** job classes change **one type** — `AdvisoryLockService advisoryLockService` → `JobLockService jobLockService` (field + constructor param) — and update the `JobLockId` reference path from `AdvisoryLockService.JobLockId.*` to `JobLockService.JobLockId.*`. Logic is unchanged. Also update the Javadoc in `RestIdempotencyCleanupJob.java:21` that names `AdvisoryLockService.JobLockId.CLEANUP_REST_IDEMPOTENCY`. Per-file line anchors are in the §2.4 table (rows 2–9).

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

### 3.6 Existing reflection-based contract test will break on the rename

`src/test/java/net/aim_ai/wms/unit/service/AdvisoryLockServiceJobLockIdContractTest.java` (the SBDEV-2222 TDD-gate test) reflectively reads `AdvisoryLockService.JobLockId`:

```java
field = AdvisoryLockService.JobLockId.class.getField("CLEANUP_REST_IDEMPOTENCY"); // line 29
```

Renaming `AdvisoryLockService` and moving `JobLockId` into the new `JobLockService` interface will break this test at **compile time** (the symbol `AdvisoryLockService` no longer exists). It must be updated as part of this change:

- Retarget the import and reflection lookup to `JobLockService.JobLockId.class.getField("CLEANUP_REST_IDEMPOTENCY")`.
- The remaining assertions (public/static/final/`long`/value `100007L`) are unchanged — they validate the moved constant just as well.
- Optionally broaden the test to assert all 8 constants, but that is out of scope; the minimum is keeping the existing test green against the new type.

This is tracked as an explicit checklist item in §5 and a test-plan row in §6.

---

## 4. V1/V2 Applicability

V2-only. V1/wms-api does **not** use `pg_advisory_lock` — scheduled jobs in v1 rely on the single-replica deployment assumption alone, without even the defensive lock. No port needed.

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| Advisory lock | Not present | Present in `AdvisoryLockService` (raw-JDBC ThreadLocal pinning) | V2-only refactor |
| Scheduled jobs | Some overlapping conceptual jobs (`OrderRelease`, `Replenish`, etc.) | **8** lock-protected jobs incl. v2-only `OutboxDispatcher` / `RestIdempotencyCleanup` (SBDEV-2221/2222) | Patterns / lock keys don't cross versions |
| Test impact | Tests don't touch this path | Tests on H2 need this refactor | V2-only benefit |

### What does NOT need porting

V1's scheduled-job tests already run (no advisory lock to trip over); they're not part of this scope.

---

## 5. Implementation Checklist

Estimated effort: **1–2 engineering days** for code change + review; test validation is the hour-consuming part.

- [ ] Create `JobLockService` interface in `net.aim_ai.wms.service`. Move `JobLockId` into it with **all 8** constants (values unchanged, keep `// SBDEV-2221` on `OUTBOX_DISPATCHER`).
- [ ] Rename `AdvisoryLockService` → `PostgresAdvisoryJobLockService`; add `implements JobLockService`; add `@ConditionalOnProperty(name = "wms.job-lock.engine", havingValue = "postgres", matchIfMissing = true)`. **Preserve the raw-JDBC ThreadLocal-connection-pinning body verbatim** — do NOT revert to `@PersistenceContext`/`@Transactional` (would reintroduce the lock leak, §2.1).
- [ ] Add `InMemoryJobLockService` with `@ConditionalOnProperty(name = "wms.job-lock.engine", havingValue = "in-memory")` **and a `reset()`/`clear()` method** (no auto-release, §3.1.3).
- [ ] Update **all 8** scheduled-job classes: change the field + constructor-param type to `JobLockService`; update `JobLockId` reference paths (8 files × 2 call sites = **16 sites**, plus the `RestIdempotencyCleanupJob:21` Javadoc). Line anchors in §2.4.
- [ ] Add the startup-safety `ApplicationRunner` bean (positive **allowlist** `{integration[, integration-pg]}`, exact membership via `Environment.getActiveProfiles()` — NOT a substring scan, NOT a non-existent `h2`/`test` profile) in a config class (e.g., `ScheduledJobConfig`).
- [ ] Add `wms.job-lock.engine=in-memory` to the integration test profile `src/test/resources/application-integration.properties` (it already exists; `@ActiveProfiles("integration")`).
- [ ] Wire `InMemoryJobLockService.reset()` into the integration test base / a `@BeforeEach` (or JUnit extension) so locks are cleared between tests.
- [ ] **Update `AdvisoryLockServiceJobLockIdContractTest`** (`src/test/java/net/aim_ai/wms/unit/service/AdvisoryLockServiceJobLockIdContractTest.java:29`) to reflect over `JobLockService.JobLockId` instead of `AdvisoryLockService.JobLockId` — otherwise it fails to compile after the rename (§3.6).
- [ ] Update existing unit tests for the 8 jobs — the mocked `AdvisoryLockService` mock target changes to `JobLockService`.
- [ ] Add focused tests for the lock services themselves, incl. a reset-between-tests assertion for the in-memory impl (see §6).
- [ ] Grep the codebase for `AdvisoryLockService` after rename — confirm zero stragglers (incl. the wildcard import in `SchedulingConfiguration.java:8` still resolves).
- [ ] Smoke-test a local run with `wms.job-lock.engine=postgres` against a real PostgreSQL dev DB; verify `pg_locks` shows the lock when held (`SELECT * FROM pg_locks WHERE locktype='advisory'`).
- [ ] Document the engine property in `application.properties` and `application_dev.properties` (commented default: `wms.job-lock.engine=postgres`).
- [ ] Resolve Open Question Q1 (§2.3): confirm outbox/idempotency replica topology with the deploy owner before treating the in-memory engine as a safe substitute on those paths.
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
| In-memory impl — no auto-release / reset frees a leaked lock | `tryLock(100)` (never unlock) → `reset()` → `tryLock(100)` | First `true`; without `reset()` the third call would be `false`; after `reset()` it is `true` (proves leaks persist absent reset, and reset clears them) |
| Job test — lock contention path | Set up `InMemoryJobLockService`; prime the lock; call job entry point | Job short-circuits (returns without running work), per existing try/fail-skip pattern |
| Job test — happy path | Job entry point with free lock | Work executes, lock released in finally |
| Contract test survives rename | Run `AdvisoryLockServiceJobLockIdContractTest` after retargeting to `JobLockService.JobLockId` | Compiles and passes; `CLEANUP_REST_IDEMPOTENCY == 100007L` |
| Startup safety — disallowed profile | Boot app with `wms.job-lock.engine=in-memory` and an active profile NOT in `{integration, integration-pg}` | `ApplicationRunner` throws, context fails — regression-safe |
| Startup safety — allowlisted profile | Boot with `wms.job-lock.engine=in-memory` and `@ActiveProfiles("integration")` | Context boots, in-memory engine permitted (proves the guard does not false-positive on the real test profile) |

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `PostgresAdvisoryJobLockServiceIT` (new, Testcontainers-only) | `tryLock_sameSession_acquiresOnce` | PG-specific semantics validated |
| `PostgresAdvisoryJobLockServiceIT` | `tryLock_differentConnection_contends` | Real advisory-lock contention |
| `InMemoryJobLockServiceTest` (new, unit) | `tryLock_thenTryLock_returnsFalse` | Self-consistency |
| `InMemoryJobLockServiceTest` | `unlock_thenTryLock_returnsTrue` | Release works |
| `InMemoryJobLockServiceTest` | `concurrent_tryLocks_exactlyOneWinner` | Thread-safe with `ConcurrentHashMap.putIfAbsent` |
| `InMemoryJobLockServiceTest` | `reset_freesLeakedLock_thenTryLockSucceeds` | Documents NO auto-release; `reset()` clears a lock leaked without `unlock()` (§3.1.3) |
| `JobLockEngineCheckTest` (new, unit) | `inMemory_outsideAllowlistedProfile_throws` | Fail-loud guard rejects in-memory under a non-allowlisted profile |
| `JobLockEngineCheckTest` | `inMemory_underIntegrationProfile_boots` | Guard does NOT false-positive on the real `integration` test profile (allowlist correctness) |
| **`AdvisoryLockServiceJobLockIdContractTest` (existing — MUST update)** | `jobLockId_should_declareCleanupRestIdempotencyConstant` | **Retarget reflection from `AdvisoryLockService.JobLockId` → `JobLockService.JobLockId` (line 29).** Without this the test fails to compile after the rename (§3.6). |
| Existing `OrderReleaseJobTest`, `ReplenishOrderJobTest`, `CleanUpOldMessagesJobTest`, `StockSummaryExportJobTest`, `ReleaseExpiredPickingOrdersFromUserJobTest`, `StaleClubBatchCleanupJobTest`, `RestIdempotencyCleanupJobTest`, `OutboxDispatcherJobTest` (whichever exist) | — | **Update mock target from `AdvisoryLockService` to `JobLockService`** across all 8 jobs. Assertions unchanged. |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=*JobLockService*` | | |
| `mvn test -Dtest=AdvisoryLockServiceJobLockIdContractTest` (retargeted) | | |
| `mvn test -Dtest=*Job*` (all 8 existing job tests + new) | | |
| `mvn verify -Dtest=PostgresAdvisoryJobLockServiceIT` | | |
| `mvn verify` (full, postgres profile) | | |
| `mvn verify -Dtest=...` (`integration` profile, once H2 plan Phase 1 lands) | | |

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
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | **Yes — the `InMemoryJobLockService` implementation** | Guarded against prod use by `@ConditionalOnProperty` + startup `ApplicationRunner` **allowlist** check (exact profile membership, §3.2). Production uses `PostgresAdvisoryJobLockService` which holds lock state in the PG session, not the JVM. **Caveat:** the in-memory impl has NO auto-release — a leaked lock persists for the JVM lifetime and causes order-dependent test flakiness; mitigated by the required `reset()` hook between tests (§3.1.3, §5). |
| 2 | **Connection pool math** | Change per-request DB connection usage? | No | Same one-statement landlord query per `tryLock`/`unlock`. |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` / cron job? | No | Only the lock mechanism inside existing jobs changes. |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls? | No | Each lock op is a single stmt, session-scoped release. |
| 5 | **Request affinity** | Assume a follow-up request lands on the same replica? | No | Scheduled jobs are not request-scoped. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics? | No change from today (prod) | Prod PG impl: if the lock holder crashes, the PG session-level lock auto-releases when the pinned connection is lost — safe for retry; preserved verbatim. The in-memory impl does **not** auto-release (test-only; see row 1 / §3.1.3). |
| 7 | **Tenant context** | Use `TenantContext` / `ThreadLocal` across async boundaries? | No | Runs on landlord DB; tenant-context-irrelevant. |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock across replicas? | **Refactors the existing distributed lock** | Production impl (`PostgresAdvisoryJobLockService`) keeps the current raw-JDBC ThreadLocal-pinning body verbatim — **byte-identical semantics for the PG prod path only**. The in-memory impl **diverges** (test-only: per-JVM, no auto-release) and must never run multi-replica (guarded, §3.2). The 6 `SchedulingConfiguration` jobs still rely on the single-replica-cron rule; **the outbox/idempotency `@Scheduled` jobs already run on all replicas and depend on the lock for single-flight** (see §2.3 + Open Question Q1) — for those the lock is load-bearing, not defensive. ShedLock for true multi-replica cron of the 6 gated jobs is out of scope (see §8). |
| 9 | **Cache invalidation** | Write to an entity that is cached? | No | — |
| 10 | **External notifications** | Send HTTP / message inside a transaction? | No | — |

### Evidence (fill in for any "Yes" row)

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 1 | Guard bean `jobLockEngineCheck` uses an exact-membership **allowlist** (`{integration, integration-pg}`) and throws on in-memory under any non-allowlisted profile | `src/main/java/net/aim_ai/wms/config/ScheduledJobConfig.java` (new, Phase 1) |
| 1 | `JobLockEngineCheckTest.inMemory_outsideAllowlistedProfile_throws` + `inMemory_underIntegrationProfile_boots` | new unit tests |
| 1 | `InMemoryJobLockService.reset()` cleared between tests; `reset_freesLeakedLock_thenTryLockSucceeds` proves no-auto-release behavior is contained | new unit test + integration base `@BeforeEach` |
| 8 | `PostgresAdvisoryJobLockServiceIT` reproduces current advisory-lock behavior (raw-JDBC ThreadLocal pinning, contention across connections) | new IT |
| 8 | `AdvisoryLockServiceJobLockIdContractTest` retargeted to `JobLockService.JobLockId` confirms all 8 lock-id constants survive the move | existing test (updated, §3.6) |
| 8 | Outbox/idempotency load-bearing path: confirm replica topology before relying on the lock | Open Question Q1 (§2.3) — pending deploy-owner confirmation |

---

## 8. Notes

### Rollback

Interface + profile-selected bean means rollback is trivial:

- **Dev/test:** flip `wms.job-lock.engine=postgres` and restart.
- **Production:** no operational rollback needed — prod defaults to `postgres` and never changes.
- **Code rollback:** single revert — the refactor is additive (new interface, renamed class); the 8 job-class changes (16 call sites) plus the retargeted contract test are type swaps that compile without behavior change.

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

The architecture doc `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md` should list all scheduled jobs. Verify parity with the **8** `JobLockId` constants (`ORDER_RELEASE`…`OUTBOX_DISPATCHER`, `100001`–`100008`) during implementation — if a ninth job exists without an advisory lock, decide whether it should gain one. Note that `TenantPoolEvictor` also uses `@Scheduled` but is intentionally unlocked (per-replica pool cleanup, runs everywhere by design — see `SchedulingEnablementConfig`).

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
- Confirm test profile injection strategy: `src/test/resources/application-integration.properties` already exists and is selected via `@ActiveProfiles("integration")`, so adding `wms.job-lock.engine=in-memory` there is the simplest path. Programmatic injection via `H2TestExtension` remains an option for tests that don't extend the integration base.
