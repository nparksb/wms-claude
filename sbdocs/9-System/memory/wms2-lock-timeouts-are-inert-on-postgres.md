---
name: wms2-lock-timeouts-are-inert-on-postgres
description: The five jakarta.persistence.lock.timeout settings in wms2-api had NO effect (dialect discards positive values); FIXED by SBDEV-3250 via SET LOCAL lock_timeout — which bounds each lock ACQUISITION, not the statement
metadata:
  type: project
---

**SBDEV-3250, filed 2026-09-07.** wms2-api configures a pessimistic-lock timeout in **five** places
and **not one works**: `PickingorderRepository` (1000), `CustomerorderBatchRepository`,
`BillofladingRepository`, `StockunitRepository` (5000 each), plus the global
`spring.jpa.properties.jakarta.persistence.lock.timeout=5000` at `application.properties:85`.

**A row-lock wait in wms2-api is unbounded**, and it holds a tenant Hikari connection for the
duration.

Three instruments:
1. **Behaviour** — held a `Pickingorder` row 30s in one tx, ran a move in another. Expected failure
   at ~1s per the ADR. The move **waited 30.92s and then succeeded**.
2. **Mechanism** — `hibernate-core 6.6.39` `PostgreSQLDialect.withTimeout(String,int)` branches only
   on `supportsNoWait()` (**0** / NO_WAIT) and `supportsSkipLocked()` (**-2**). Any other value
   returns the lock string UNCHANGED. PostgreSQL has no `FOR UPDATE` timeout clause; a bound needs
   `SET lock_timeout`, and the only `connectionInitSql` (`TenantDynamicRoutingDataSource:227`) sets
   the **timezone**.
3. **Server** — `wsl-wineco-uat`: `pg_settings.lock_timeout = 0`, `source = default`.

⚠ **This corrects [[wms1-has-no-lock-timeout-or-leak-detection]]**, which said "v2 has a global 5s
bound". The property exists; the bound does not. **0 and -2 are the only values the dialect honours**
and no site uses either.

`PickLineRealignmentIT.ac6_moveDoesNotYieldToInFlightPick_lockTimeoutIsInert` **pins the defect on
purpose** and goes red when SBDEV-3250 lands — that is the signal, not a breakage.


---

## FIXED 2026-09-07 (SBDEV-3250) — and three things the fix taught

**The bound now comes from `LockTimeoutHibernateJpaDialect`**, a `HibernateJpaDialect` subclass seated
on the **tenant `EntityManagerFactory`**, issuing `SET LOCAL lock_timeout` at transaction begin.
`wms.tenant.lock-timeout-ms`, default **10000**.

1. **⚠ `lock_timeout` bounds each lock ACQUISITION, not the statement or the transaction.** A
   statement locking N rows waits up to N × the bound. The population, derived rather than recalled
   (an earlier note said "two sites" and "13 of 15", which cannot both be true):
   **15 `@Lock` methods = 11 single-row + 4 multi-row** (`findAllByIdForUpdate`,
   `CustomerorderPositionRepository.findByOrderIdForUpdate`,
   `CustomerorderCancellationLogRepository.findPendingReversalsForUpdateByCustomerorderId`,
   `LocationRepository.getAvailableTransferLanesForUpdate` — the last locks EVERY free transfer lane);
   **2 native `FOR UPDATE`** (`getStockUnitsByItemDataIdForUpdate`, no LIMIT; `OutboxMessageRepository`
   is `SKIP LOCKED` so never waits); and **~31 bulk `@Modifying` UPDATE/DELETEs**, which lock per
   matched row exactly as `FOR UPDATE` does. So N × bound is the NORMAL case for bulk writes.
   The honest guarantee: no single acquisition waits longer than the bound; statement and transaction
   time are unbounded. `statement_timeout` would fix that and caps every query including the
   cursor-streaming exports — a real decision, deliberately not taken.
2. **Seat it on the EMF, never on the transaction manager.** `JpaTransactionManager` implements
   `InitializingBean`; its `afterPropertiesSet()` re-reads the dialect off the `EntityManagerFactoryInfo`
   and overwrites whatever the `@Bean` method set. Setting it on the TM compiles, wires, and does
   nothing. That same line is what propagates the EMF's dialect to the TM — the EMF is the supported input.
3. **`SET LOCAL lock_timeout` is PostgreSQL-only and H2 REJECTS it.** Because it runs at transaction
   *begin*, the rejection fails BEGIN, surfacing as `CannotCreateTransactionException` on tests that
   mention nothing about locking — it broke **18 H2 classes**. The dialect gates on
   `spring.jpa.database-platform` being assignable to `PostgreSQLDialect`.

**⚠ RETRACTED — the "six unbounded bare-@Transactional methods" claim was FALSE.** They resolve to
`tenantTransactionManager`, not landlord. See [[wms2-bare-transactional-differs-by-package]]. Deleting
`transactionManagerRef` does not silently fall back to `@Primary` either — it throws
`NoSuchBeanDefinitionException`. **Three review passes asserted the false version and none ran it**;
two instruments settled it in ten minutes.

**A swallowed lock failure poisons a shared transaction.** PostgreSQL aborts the whole transaction on
any statement error (later statements get `25P02`), so `catch (Exception)` around a lock that runs in a
*joined* transaction turns one contended row into a cascade of misleading WARNs plus a commit failure.
Rethrow `PessimisticLockingFailureException` when the transaction is not yours; swallowing is only
correct when the callee opened its own (`REQUIRES_NEW`, or no outer tx).

Origin of the false claim: archived plan `SBDEV-2575` — *"The hint demonstrably works in this exact
PG/Hibernate stack — no need to hedge."* It propagated into five documents.

Related: [[wms2-test-resources-shadows-main-application-properties]],
[[wms2-requires-new-in-lock-holding-tx-deadlock]].
