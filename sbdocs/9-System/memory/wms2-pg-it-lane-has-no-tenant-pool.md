---
name: wms2-pg-it-lane-has-no-tenant-pool
description: "wms2-api PG IT lane has NO tenant connection pool — N threads = N server connections; \"Hikari pool of 5\" diagnoses there are wrong; limit is postgres max_connections"
metadata:
  node_type: memory
  type: project
  originSessionId: 6aa2670b-eed0-4a5e-bab9-37b3afb51578
  modified: 2026-10-09T14:45:38.463Z
---

In wms2-api's Postgres IT lane, `PostgresTestSupportConfig` replaces `tenantDynamicRoutingDataSource` with a Mockito mock whose `getConnection()` opens a fresh `DriverManager` connection every call. There is **no Hikari pool** on the tenant side, so `spring.datasource.hikari.maximumPoolSize=5` in test properties configures nothing on that path.

Consequence: a test running N threads holds N server connections on top of every cached Spring context's connections. SequenceTransactionServiceConcurrencyIT's 50 threads failed on the 2-vCPU CI runner with `FATAL: sorry, too many clients already` (CI runs 34275022182, 34277643352) — SBDEV-3258 had recorded it as a Hikari acquisition timeout, and that misdiagnosis was copied into 5 places before a re-review lane caught it (SBDEV-3294, 2026-10-09). Fixed by `AppPostgresDBContainer.MAX_CONNECTIONS = 300` (`-c max_connections=300`), pinned by `PostgresTestHarnessPinTest.sharedContainerRaisesMaxConnections`.

**Why:** "the pool is too small" is the obvious reading of `CannotCreateTransactionException` under threads, and it is wrong in this lane — it sends you toward lowering thread counts or tagging tests out of CI instead of a one-line harness fix.

**How to apply:** for any connection/acquisition failure in a many-threaded PG IT, grep the log for `too many clients` vs `Connection is not available` before diagnosing; reproduce by lowering MAX_CONNECTIONS (at 40 the 50-thread test reds with 105 "too many clients"). Related: [[concurrent-maven-one-worktree-false-reds]], [[wms2-concurrency-it-fixture-traps]].
