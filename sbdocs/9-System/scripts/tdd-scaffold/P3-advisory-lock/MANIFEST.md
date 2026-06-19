# TDD-Gate Scaffold — P3 "Replace pg_advisory_lock for test portability" (v2/wms2-api)

Pre-implementation scaffold for plan
`sbdocs/1-Projects/wms2/plan/260421-v2-replace-pg-advisory-lock.md`.
Nothing here has been copied into `v2/wms2-api/src/`; no `mvn` was run. This directory mirrors the
eventual `src` layout so the files are copy-ready. The gate is **RED** until P3 is implemented;
**GREEN == acceptance** of the §6 criteria.

---

## 1. Files in this scaffold

### Production skeletons (bodies throw `UnsupportedOperationException("TDD gate: not implemented")`)

| Scaffold path | Copies to |
|---|---|
| `main/java/net/aim_ai/wms/service/JobLockService.java` | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/JobLockService.java` |
| `main/java/net/aim_ai/wms/service/InMemoryJobLockService.java` | `…/src/main/java/net/aim_ai/wms/service/InMemoryJobLockService.java` |
| `main/java/net/aim_ai/wms/service/PostgresAdvisoryJobLockService.java` | `…/src/main/java/net/aim_ai/wms/service/PostgresAdvisoryJobLockService.java` |
| `main/java/net/aim_ai/wms/config/ScheduledJobConfig.java` | `…/src/main/java/net/aim_ai/wms/config/ScheduledJobConfig.java` |

Notes:
- `JobLockService` carries **all 8** `JobLockId` constants verbatim (`ORDER_RELEASE=100001L` …
  `OUTBOX_DISPATCHER=100008L`, `// SBDEV-2221` comment kept, private ctor) — copied exactly from the
  current `AdvisoryLockService.JobLockId`.
- `PostgresAdvisoryJobLockService` is the renamed `AdvisoryLockService` (the legacy file is then
  deleted). It keeps the constructor `@Qualifier("landlordDataSource") DataSource` and the
  `ThreadLocal<Connection>` field. The GREEN step restores the **raw-JDBC pinning body verbatim** —
  do NOT revert to `@Transactional`/EntityManager (plan §2.1 lock-leak).
- `ScheduledJobConfig.jobLockEngineCheck` uses the positive allowlist `Set.of("integration",
  "integration-pg")` via `Environment.getActiveProfiles()`. The GREEN-step body is in the file's
  Javadoc.

### Failing tests

| Scaffold path | Copies to | Kind |
|---|---|---|
| `test/java/net/aim_ai/wms/unit/service/InMemoryJobLockServiceTest.java` | `…/src/test/java/net/aim_ai/wms/unit/service/InMemoryJobLockServiceTest.java` | unit |
| `test/java/net/aim_ai/wms/unit/config/JobLockEngineCheckTest.java` | `…/src/test/java/net/aim_ai/wms/unit/config/JobLockEngineCheckTest.java` | unit |
| `test/java/net/aim_ai/wms/service/PostgresAdvisoryJobLockServiceIT.java` | `…/src/test/java/net/aim_ai/wms/service/PostgresAdvisoryJobLockServiceIT.java` | Testcontainers IT (only IT) |

---

## 2. Retarget checklist — existing tests that mock `AdvisoryLockService` (do NOT write these into src now)

These are existing src tests that must have their mock/import target changed from
`net.aim_ai.wms.service.AdvisoryLockService` → `net.aim_ai.wms.service.JobLockService`, and any
`AdvisoryLockService.JobLockId.*` reference → `JobLockService.JobLockId.*`. Assertions unchanged.
Verified by `grep -rl AdvisoryLockService src/test` against HEAD on 2026-06-17.

The 8 job classes from §2.4 map to these **actual** test class names found in
`src/test/java/net/aim_ai/wms/unit/schedulejob/`:

| # | Job class (§2.4) | Test class(es) referencing `AdvisoryLockService` | What changes |
|---|---|---|---|
| 1 | `OrderReleaseJob` | `OrderReleaseJobTest` (field type), `OrderReleaseJobMetricsUnitTest` (import + `JobLockId.ORDER_RELEASE`), `OrderReleaseJobStreamingTest` (`@Mock` field) | type swap + `JobLockId` path |
| 2 | `ReplenishOrderJob` | `ReplenishOrderJobTest` (field type), `ReplenishOrderJobMetricsUnitTest` (import + `JobLockId.REPLENISH_ORDER`), `ReplenishOrderJobPaginationTest` (`@Mock`), `ReplenishOrderJobConnectionBudgetTest` (`@Mock`) | type swap + `JobLockId` path |
| 3 | `CleanUpOldMessagesJob` | `CleanUpOldMessagesJobTest` (FQN field type), `CleanUpOldMessagesJobMetricsUnitTest` (import + `JobLockId.CLEAN_UP_MESSAGES`) | type swap + `JobLockId` path |
| 4 | `StockSummaryExportJob` | `StockSummaryExportJobTest` (FQN field), `StockSummaryExportJobUnitTest` (import + field), `StockSummaryExportJobMetricsUnitTest` (import + `JobLockId.STOCK_SUMMARY_EXPORT`), `StockSummaryExportJobBulkInsertTest` (`@Mock`), `StockSummaryExportJobOmsDecouplingTest` (`@Mock`) | type swap + `JobLockId` path |
| 5 | `ReleaseExpiredPickingOrdersFromUserJob` | `ReleaseExpiredPickingOrdersFromUserJobTest` (FQN field), `ReleaseExpiredPickingOrdersFromUserJobMetricsUnitTest` (import + `JobLockId.RELEASE_EXPIRED_PICKING`) | type swap + `JobLockId` path |
| 6 | `StaleClubBatchCleanupJob` | `StaleClubBatchCleanupJobUnitTest` (import + field + `JobLockId.STALE_CLUB_BATCH_CLEANUP` in `when`/`verify`) | type swap + `JobLockId` path |
| 7 | `RestIdempotencyCleanupJob` | `RestIdempotencyCleanupJobUnitTest` (import + `mock(AdvisoryLockService.class)` + reflection `JobLockId.CLEANUP_REST_IDEMPOTENCY` + Javadoc) | type swap + `JobLockId` path + reflection target + Javadoc |
| 8 | `OutboxDispatcherJob` | `OutboxDispatcherJobUnitTest` (import + `mock(AdvisoryLockService.class)` ×2 + reflection `JobLockId.OUTBOX_DISPATCHER` + Javadoc) | type swap + `JobLockId` path + reflection target + Javadoc |

> Note: several jobs have multiple test files that touch the lock (e.g. `StockSummaryExportJob` has
> 5). Retarget **every** file in the right-hand column, not just one per job. `OutboxDispatcherJobUnitTest`
> and `RestIdempotencyCleanupJobUnitTest` additionally read `JobLockId` **via reflection**, so their
> reflection lookup class and surrounding Javadoc must move to `JobLockService.JobLockId` too.

### Contract-test retarget

- `src/test/java/net/aim_ai/wms/unit/service/AdvisoryLockServiceJobLockIdContractTest.java`
  (SBDEV-2222 TDD gate) reflectively reads `AdvisoryLockService.JobLockId.class.getField(
  "CLEANUP_REST_IDEMPOTENCY")` at **line 29** plus an `import` at **line 3**. Both must change to
  `JobLockService.JobLockId`. The public/static/final/`long`/`100007L` assertions are unchanged
  (plan §3.6). Without this it **fails to compile** after the rename. (Optionally rename the test
  class/`@DisplayName`; not required for green.)

---

## 3. Activation steps (run by the implementer, NOT by this scaffold)

1. `cd v2/wms2-api && git checkout develop && git pull && git checkout -b SBDEV-XXXX-job-lock-engine`
   (branch off `develop`).
2. Copy `main/java/...` skeletons into `src/main/java/...` and `test/java/...` into
   `src/test/java/...` (paths in §1). Delete the legacy
   `src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java` once the rename + interface land.
3. Retarget the existing tests in §2 (8 jobs' test files + the contract test). Retarget the 8 job
   **production** classes per plan §2.4 (field + ctor param type, `JobLockId` path, the
   `RestIdempotencyCleanupJob:21` Javadoc).
4. Add `wms.job-lock.engine=in-memory` to `src/test/resources/application-integration.properties`
   and wire `InMemoryJobLockService.reset()` into the integration test base `@BeforeEach` (§3.1.3).
5. Run the gate:
   - **Unit (RED → GREEN):**
     `cd v2/wms2-api && mvn test -Dtest='InMemoryJobLockServiceTest+JobLockEngineCheckTest'`
   - **Testcontainers IT (RED → GREEN):**
     `cd v2/wms2-api && mvn verify -Dtest=PostgresAdvisoryJobLockServiceIT`
   - Regression sweep on the retargeted job tests:
     `cd v2/wms2-api && mvn test -Dtest='*JobLockId*+*Job*Test+*Job*UnitTest'`
6. **Gate semantics:** before P3 logic is implemented, all three new test files are **RED** — the
   unit/config tests fail at the `UnsupportedOperationException` from the skeleton bodies, and the IT
   fails the same way once it hits `tryLock`. The gate turns **GREEN** only when the §3.1.2 / §3.1.3 /
   §3.2 bodies are implemented. **GREEN == acceptance** of the §6 criteria. Do not start production
   logic until a reviewer has confirmed the tests fail for the right reason (skeleton stub, not a
   compile error).

---

## 4. Test → §6 criterion map (one line per test)

| Test class | Method | §6 criterion encoded |
|---|---|---|
| `InMemoryJobLockServiceTest` | `tryLock_thenTryLock_returnsFalse` | §6 row "In-memory impl — single JVM contention" (first `true`, second `false`) |
| `InMemoryJobLockServiceTest` | `unlock_thenTryLock_returnsTrue` | §6 row "In-memory impl — release behavior" (all succeed after unlock) |
| `InMemoryJobLockServiceTest` | `concurrent_tryLocks_exactlyOneWinner` | §6 test-table `concurrent_tryLocks_exactlyOneWinner` — thread-safe `ConcurrentHashMap.putIfAbsent`, exactly one winner |
| `InMemoryJobLockServiceTest` | `reset_freesLeakedLock_thenTryLockSucceeds` | §6 row "no auto-release / reset frees a leaked lock" + test-table `reset_freesLeakedLock_thenTryLockSucceeds` (§3.1.3 regression guard) |
| `JobLockEngineCheckTest` | `inMemory_outsideAllowlistedProfile_throws` | §6 row "Startup safety — disallowed profile" — `ApplicationRunner` throws `IllegalStateException` (§3.2) |
| `JobLockEngineCheckTest` | `inMemory_underIntegrationProfile_boots` | §6 row "Startup safety — allowlisted profile" — guard does not false-positive on `integration` (§3.2) |
| `PostgresAdvisoryJobLockServiceIT` | `tryLock_sameSession_acquiresOnce` | §6 test-table `tryLock_sameSession_acquiresOnce` — PG-specific semantics validated (verified via `pg_locks`) |
| `PostgresAdvisoryJobLockServiceIT` | `tryLock_differentConnection_contends` | §6 test-table `tryLock_differentConnection_contends` — real advisory-lock contention across two physical connections |
| `PostgresAdvisoryJobLockServiceIT` | `tryLock_pinsConnection_unlockReleasesSameConnection` | Plan §2.1 / §7 row 8 — encodes the ThreadLocal-connection-pinning "unlock releases on the same connection, no leak" semantic that MUST be preserved |

---

## 5. Constraints honored

- No file under `v2/wms2-api/src/` was created, modified, or deleted.
- No `mvn` command was run.
- All scaffold output lives under
  `sbdocs/9-System/scripts/tdd-scaffold/P3-advisory-lock/` (Obsidian vault — plain file writes).
- Test sources are syntactically valid Java that WILL compile against the skeletons once copied, so
  the RED failure is at the assertion / `UnsupportedOperationException`, not at compile time.
