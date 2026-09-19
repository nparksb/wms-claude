---
name: wms1-has-no-lock-timeout-or-leak-detection
description: v1/wms-api has NO lock timeout, NO Hikari leakDetectionThreshold and OSIV defaulted ON — so any row-lock contention is an unbounded silent hang; v2 has a global 5s bound on every pessimistic lock
metadata:
  type: reference
---

Measured 2026-08-25 at `v1.26.47` and `wms2-api origin/develop`. This is the single biggest reason a
v1 defect presents as "spinner forever, no log line" while the same defect in v2 presents as a
catchable error — do not assume a v1 hang and a v2 hang are the same severity.

**v1 (`v1/wms-api`) — nothing bounds a lock wait.**
- `StockunitRepository:30` and `PickingorderRepository:139` use `@Lock(PESSIMISTIC_WRITE)` with **no**
  `javax.persistence.lock.timeout` `@QueryHint`.
- `grep -rn "lock_timeout|statement_timeout|javax.persistence.lock.timeout" src/main/` → **zero hits**.
- `application.properties` sets only `hikari.connectionTimeout=20000` and `hikari.maximumPoolSize=5`.
  **No `leakDetectionThreshold`** — a connection pinned by a wedged transaction produces no WARN at all.
- `spring.jpa.open-in-view` is unset ⇒ Spring Boot's default **true**.
- Postgres cannot rescue it: when the holder is parked in Java rather than waiting on a lock, there is
  no cycle in the lock graph and the deadlock detector never fires.

**v2 (`v2/wms2-api`) — two independent bounds.**
- Per-query: `StockunitRepository:30` `jakarta.persistence.lock.timeout = 5000`; also Billoflading and
  CustomerorderBatch 5000, `PickingorderRepository:33` **1000**.
- **Global**: `application.properties:65 spring.jpa.properties.jakarta.persistence.lock.timeout=5000`
  covers every pessimistic lock including repositories with no `@QueryHints`. `open-in-view=false` at :55.
- Per-tenant Hikari (`TenantDynamicRoutingDataSource:86-89`): `maximumPoolSize` default **5** (same as
  v1 — the pool size is NOT the difference), `connectionTimeout` 30 s, `leakDetectionThreshold` 60 s.
  The "Apparent connection leak" WARN in the SBDEV-2575 report is that threshold firing, not a fault.

⚠️ **Unproven for v2:** nothing in the repo measures that the hint actually fires. PostgreSQL's
`FOR UPDATE` has only `NOWAIT`/`SKIP LOCKED` — no `WAIT n` — so whether Hibernate 6 on
`PostgreSQLDialect` emits `SET LOCAL lock_timeout` or silently drops the hint is empirical.
`git grep -l LockTimeoutException` finds no test asserting it fires. Prove it with two psql sessions
plus a hibernate-SQL log before leaning on it in a severity argument.

**Pool arithmetic that bites both, and bites v1 harder.** A `REQUIRES_NEW` opened while the outer tx is
suspended pins a **second** connection. `ReplenishOrderJob:89-93` documents peak 3 of 5 for the cron
alone. Two wedged v1 replenish requests (2 connections each) plus a cron run exceeds the pool, after
which unrelated endpoints fail at the 20 s `connectionTimeout` — i.e. one stuck SKU escalates to a
whole-warehouse outage, because v1 is one deployment per warehouse.

Adding `spring.datasource.hikari.leakDetectionThreshold=60000` plus a bounded
`javax.persistence.lock.timeout` to v1's two `findByIdForUpdate` repositories is the cheapest change
that converts every unbounded v1 hang into a diagnosable error. Relevant to
[[sbdev-3074-v1-replenish-movestock-hang]].

⚠ **CORRECTED 2026-09-07 — the v2 half of this was wrong.** v2's "global 5s bound" is a
`jakarta.persistence.lock.timeout` property that Hibernate's PostgreSQL dialect **silently
discards**. v2 row-lock waits are ALSO unbounded. See [[wms2-lock-timeouts-are-inert-on-postgres]]
(SBDEV-3250). The v1 half of this memory still stands.
