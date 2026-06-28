---
title: "Port PL/pgSQL report functions to Java — v2/wms2-api"
ticket: ""
ticket_url: ""
type: refactor
priority: medium
status: reviewed
project: [wms2-api]
version: v2
requester: "nam.park@siteboss.net"
created: 2026-04-20
updated: 2026-06-22
related:
  - ./260420-v2-integration-tests-h2-migration-report.md
  - ../../../2-Areas/runbooks/wms1-cancel-packed-parcel.md
tags:
  - plan
  - reviewed
  - wms2
  - refactor
  - testing
  - plpgsql
  - h2
---

# Port PL/pgSQL report functions to Java — v2/wms2-api

**Ticket:** — (to be filed) — owner: nam.park@siteboss.net
**Project:** wms2-api | **Version:** v2 | **Type:** refactor
**Priority:** medium
**Status:** REVIEWED (2026-06-22) — approved; Phase A baseline gate cleared (13/13, see rollup §8/§9 D3)
**Date:** 2026-04-20

> **Re-grounding note (2026-06-17):** Re-verified against HEAD on 2026-06-17. On the `develop` baseline the Flyway head is `V2.1.14__add_outbox_aggregate_order_index.sql`. All facts, line numbers, bean names, and SQL-body claims below reflect that baseline. Re-derive the next-free migration number again at Phase D execution time — more migrations will likely land first.
>
> **⚠️ Cross-branch baseline — `feature/utc-timezone` (PR [#47](https://github.com/SiteBossInc/wms2-api/pull/47)) merges BEFORE this plan executes.** That branch adds `V2.1.15__add_api_timestamp_format_sysprop.sql` and `V2.1.16__replenishment_monitor_view_flag_based_classification.sql`, so post-merge the head is **`V2.1.16`** and the next free V2.1.x is **`V2.1.17`**. More importantly, `V1.2.05__utc_update_functions.sql` on that branch **drops and recreates all three report functions with `timestamptz` signatures** — this plan must baseline on the post-UTC bodies, not the April `V2.1.07`/`V1.1.04`/`V1.0.03` ones:
> - `stock_history(as_of_date timestamptz)` — `V1.2.05:47-103` (1 `USING` param)
> - `transaction_detail(varchar, varchar, timestamptz, timestamptz)` — `V1.2.05:111-467` (4 `USING` params)
> - `transaction_summary(varchar, timestamptz, timestamptz)` — `V1.2.05:475-606` (3 `USING` params)
>
> Consequences for the sections below: **(a)** the Java port copies the **`V1.2.05` `timestamptz` bodies** (the `''`-un-doubling + `$N`→named-param work is identical, just on the newer source); **(b)** the §3.6/§3.2.2 baseline cast is now **`::timestamptz`** (UTC Phase 2.10 already changed `ClientRepository.java:54-55,64-65` from `::timestamp without time zone` to `::timestamptz`) — Option A keeps `to_timestamp(...)::timestamptz` in the ported SQL; **(c)** the Phase D drop migration must drop the **`timestamptz`** signatures and the restore copies from **`V1.2.05`**. **§2.2, §2.3, §3.1, and §3.2 below have been fully re-baselined to `V1.2.05` line refs** (2026-06-17); the logic provenance is validated in §2.2.1 (each `V1.2.05` body is byte-identical to its latest pre-UTC source). Remaining `V1.0.03`/`V1.1.04`/`V2.1.07` mentions are historical provenance only.
>
> **⚠️ This is a dependency on an UNMERGED branch — hedge it, don't assert it.** `V1.2.05` lives only on `feature/utc-timezone` (PR #47); it is NOT on `develop` yet, and the §2.2.1 byte-diff was run once (2026-06-17) against the current branch tip. Two guards are MANDATORY before Phase A coding (also see §5 Phase A gate):
> 1. **Kickoff re-validation gate.** Re-run the §2.2.1 byte-diff against the **merged** `V1.2.05` on `develop` (and re-derive the `V1.2.05` line refs + the next-free drop/restore migration numbers). If PR #47 was altered in review, the provenance and line refs must be re-confirmed before any SQL is copied.
> 2. **Fallback if PR #47 is dropped or indefinitely stalled.** If `V1.2.05` never lands, baseline the port on the pre-UTC bodies instead — `transaction_detail` from `V2.1.07`, `transaction_summary` from `V1.1.04`, `stock_history` from `V1.0.03` — with **`timestamp`** (not `timestamptz`) signatures, and adjust §3.2.x line refs, the §3.2.2 cast (`::timestamp without time zone`), and the §3.5 Phase D drop signatures accordingly. The port logic is unchanged either way (§2.2.1 proves the bodies are identical); only the date types and file/line refs differ.

---

## 1. Problem Statement

`v2/wms2-api` ships three PL/pgSQL functions that make the entire integration-test suite PostgreSQL-dependent:

| Function | Defined | Signature | Last revision |
|---|---|---|---|
| `stock_history(timestamp)` | `V1.0.03__wms_functions.sql:13-71` | `(timestamp) → 8-col TABLE` | V1.0.03 |
| `transaction_detail(varchar, varchar, timestamp, timestamp)` | `V1.0.03` → `V1.1.04` → `V2.1.07` | `(…) → 24-col TABLE` | V2.1.07 |
| `transaction_summary(varchar, timestamp, timestamp)` | `V1.0.03` → `V1.1.04` | `(…) → 18-col TABLE` | V1.1.04 |

Consequences today:

- **H2 cannot run integration tests that touch reports.** H2 has no PL/pgSQL; Flyway migrations fail at H2 boot. This blocks Phase 2+ of the separate H2 migration plan ([260420-v2-integration-tests-h2-migration-report.md](./260420-v2-integration-tests-h2-migration-report.md)).
- **Testcontainers is the only way to verify report logic,** and Testcontainers needs a running Docker daemon. When Docker isn't up, `ClientRepositoryIntegrationTest.getTransactionDetail` is silently skipped.
- **The smoke test (`ClientRepositoryIntegrationTest:285`, originally `120db54`) is `@Disabled`** — its inline comment still blames a landlord-datasource env issue, but that wiring already shipped (the rest of the class boots green on H2); the **real residual blocker is the PL/pgSQL `transaction_detail()` function**, which H2 cannot run. Porting it to Java (this plan, Phase A) is what actually re-enables the test. See [the H2 migration plan §1.6/§3 Category E](./260420-v2-integration-tests-h2-migration-report.md).
- **Logic is hard to read, debug, and unit-test.** 350+ lines of dynamic SQL with 6-way UNIONs live inside the DB; the business rules they encode (zero-amount filter, canceled-order accounting, picking vs club split) can't be asserted without a round-trip.

Goal: Move the report SQL out of PL/pgSQL into Java, keep behavior byte-identical, enable H2 testability, and leave a clean rollback path.

---

## 2. Current Architecture

### 2.1 Call chain (production)

```
POST /rest/report/getTransactionReport
  └─ TransactionReportRestController.getTransactionReport()           :75-175
     └─ ClientRepository.getTransactionSummary(code, startStr, endStr) :49-56
        └─ native query → transaction_summary(:code, to_timestamp(:startStr), to_timestamp(:endStr))

POST /rest/report/getTransactionDetailedReport
  └─ TransactionReportRestController.getTransactionDetailedReport()   :177-322
     └─ ClientRepository.getTransactionDetail(code, sku, startStr, endStr) :58-66
        └─ native query → transaction_detail(:code, :sku, to_timestamp(:startStr), to_timestamp(:endStr))

(internal — unused by REST today, but publicly exposed)
StockViewRepository.stockHistoryAfterAsOfDate(Date asOfDate)            :61-63
  └─ native query → stock_history(:asOfDate)
```

### 2.2 Shape of each function (semantics to preserve)

| Function | What it does (semantically) | Sub-queries |
|---|---|---|
| `stock_history(as_of timestamptz)` | For each SKU with activity, compute total stock today + received / returned / shipped / adjusted since `as_of`, return the back-computed `historical_stock` (= `total_stock_today − received − returned + shipped − adjustments`) | 1 outer SELECT over `stock_view sv` LEFT JOIN **2** aggregate sub-SELECTs: one over `stockrecord` computing received/returned/adjustments (`sr.created > $1`), one over `billoflading_position` computing shipped (`bp.state='CLOSED' AND bp.created > $1`). Returns 8 cols (`shipped` is `BIGINT`). `V1.2.05:47-105` (body `58-101`) |
| `transaction_detail(client varchar, sku varchar, start timestamptz, end timestamptz)` | Timeline view: one row per movement (shipped / received / returned / putaway / replenished / adjusted / damaged / picked / QA / club-run / canceled) + BEGINNING + ENDING inventory rows. `transaction_date` return col is now **`timestamptz`** | **6 `UNION` branches** (`UNION`, **not** `UNION ALL` — dedup semantics) against `billoflading_position` (Shipped), `stockrecord` (the activity sub-SELECT `tr`), `stockrecord` again (Club Run, grouped), `stock_history($3)` (BEGINNING), `customerorder_position` state 800 (Canceled), `stock_history($4)` (ENDING), with `transaction_name` CASE labels and `ORDER BY client_name, sku, transaction_date`. `V1.2.05:111-470` (body `115-465`) |
| `transaction_summary(client varchar, start timestamptz, end timestamptz)` | Per-SKU rollup across the date range: beginning / received / returned / putaway / adjustments / damaged / depleted-picked / depleted-club / shipped / ending / net-change | **2 `UNION` branches** under an outer `GROUP BY`: a main aggregate over `stockrecord`/`billoflading_position`/`stockunit` joined to `stock_history($2)` (beginning) and `stock_history($3)` (ending), plus a Canceled branch over `customerorder_position` state 800. `order by wms_product_id`. `V1.2.05:475-609` (body `479-604`) |

Both `transaction_*` internally call `stock_history()` (inline in their SQL) — **note the `$N` indices differ**: `transaction_detail` calls `stock_history($3)`/`($4)` (its start/end are `$3`/`$4`), while `transaction_summary` calls `stock_history($2)`/`($3)` (its start/end are `$2`/`$3`). The inlined fragment must bind the correct named param in each context (see §3.2).

#### 2.2.1 Logic provenance — VALIDATED (port the latest body, no version regression)

The functions' logic evolved across migrations; porting an *older* body would silently regress. The full history and the validation result (diffed on 2026-06-17):

| Function | Migration history (logic changes) | Latest pre-UTC body | `V1.2.05` body vs latest source |
|---|---|---|---|
| `stock_history` | `V1.0.03` only | `V1.0.03` | **byte-identical** (diff: 0 lines) ✅ |
| `transaction_detail` | `V1.0.03` → `V1.1.04` (rewrite) → **`V2.1.07`** (zero-amount PICKING filter `sr.amount != 0`) | `V2.1.07` | **byte-identical** — the `… AND sr.amount != 0` filter is present at `V1.2.05:318` ✅ |
| `transaction_summary` | `V1.0.03` → **`V1.1.04`** (rewrite) | `V1.1.04` | **byte-identical** (diff: 0 lines) ✅ |

**Result:** `V1.2.05`'s provenance header ("verbatim, only signatures/returns changed") is **verified** — each EXECUTE body equals its latest pre-UTC source byte-for-byte; the *only* deltas are the function-signature lines (`timestamp`/`timestamp without time zone` → `timestamptz`) and `transaction_detail`'s `transaction_date` **return** column (`timestamp` → `timestamptz`). No migration after `V2.1.07` (other than `V1.2.05`) touches these functions (`V1.1.05` and `V2.1.08`–`V2.1.16` do not; `V1.2.01` only references them in comments). **Therefore the port baselines on `V1.2.05` and inherits the latest logic for every function — `transaction_detail` keeps the V2.1.07 zero-amount filter, `transaction_summary` the V1.1.04 rewrite, `stock_history` the V1.0.03 body — with no risk of resurrecting a superseded version.**

### 2.3 What's "dynamic" about the dynamic SQL — and the real porting hazard

> **Baseline: `V1.2.05__utc_update_functions.sql` (post-UTC, `timestamptz`).** All line refs in this section are to `V1.2.05` — the version that exists on `develop` once PR #47 merges. It carries the same logic as the pre-UTC `V1.0.03`/`V1.1.04`/`V2.1.07` bodies (the UTC migration's own header documents the provenance) with only the date param/return types widened to `timestamptz`.

**The shape is NOT conditional (verified against `V1.2.05`).** The bodies use `RETURN QUERY EXECUTE '…' USING $1, $2, …` but **do not build the query shape conditionally** — no `format()`, no `quote_ident`, no `IF/ELSIF` branching. Every branch executes on every call. In Java terms: plain parameterized native SQL, no `if/else` branching, no reflection needed.

**But "no conditional shape" does NOT make this a mechanical port — this is the PRIMARY correctness hazard of the whole plan.** Each function body is a single large SQL string passed to `EXECUTE … USING $1..$N`, and **inside that string every literal is written with DOUBLED single-quotes** because it is itself a quoted string literal. Examples from `V1.2.05`:

```
date_trunc(''second'', transaction_date)            -- V1.2.05:123
coalesce(CASE WHEN (sr.activitycode = ''RECEIVING'') -- V1.2.05:75,263,…
date_trunc(''DAY'', sr.modified)                    -- V1.2.05:333,363
```

Porting to a Java text block requires TWO transformations, and **a `$1→:param` swap alone is wrong**:

1. **Un-double every `''` → `'`.** Every doubled single-quote in the function body must collapse to a single quote when it becomes a real Java SQL string. Miss one and the SQL is malformed or silently changes a string literal.
2. **Map the positional `USING $N` params to named params.** `transaction_detail` binds **4** (`USING $1, $2, $3, $4;` at `V1.2.05:467`); `transaction_summary` binds **3** (`USING $1, $2, $3;` at `V1.2.05:606`); `stock_history` binds **1** (`USING $1;` at `V1.2.05:103`). Each `$N` may appear many times and must map to the same `:namedParam` everywhere. **Watch the inline-`stock_history` index shift** (§2.2): inside `transaction_detail` the inlined stock_history fragment uses `$3`/`$4`; inside `transaction_summary` it uses `$2`/`$3`.

A third, UTC-specific subtlety: the branches are joined by **`UNION` (dedup), not `UNION ALL`** — preserve `UNION` exactly (switching to `UNION ALL` would change row counts where two branches produce identical rows).

Because of (1)–(3), **the row-for-row parity integration test (§5 Phase A / §6) is the mandatory gate** — it is the only thing that proves the un-doubling, param-mapping, and `UNION` semantics were preserved.

**Good news that strengthens H2-portability (verified against `V1.2.05` 2026-06-17):**
- **ZERO `::` casts** in any of the three function bodies. The only cast anywhere is a single `CAST(sum(shipped) as int8)` at `V1.2.05:490` (in `transaction_summary`) — already ANSI form, H2-portable.
- Only standard constructs are used: `date_trunc('second' | 'DAY', …)` (in `transaction_detail` only), `coalesce`, `CASE WHEN`, `UNION`, `LEFT JOIN`, `INNER JOIN`, `GROUP BY`, `concat(...)`. All supported by H2 in `MODE=PostgreSQL`. (See §3.6 and the Phase A H2 spike.)
- **No `to_timestamp(...)` inside any function body** — the date-string parsing lives only in the JPA `@Query` wrapper, which UTC Phase 2.10 changed to cast `::timestamptz` (`ClientRepository.java:54-55,64-65`). See §3.2.2 / §3.3 and the TZ caveat in §3.6.
- ⚠️ **New H2-fidelity flag (timestamptz):** the params are now `timestamptz`. H2 `MODE=PostgreSQL` has `TIMESTAMP WITH TIME ZONE`, but H2 stores it as an offset value while PostgreSQL normalizes to a UTC instant — a genuine engine divergence that the H2 lane structurally cannot vet. The Phase A H2 spike (§5) must confirm `to_timestamp(...)::timestamptz` binds and compares correctly on H2, and the PG Testcontainers parity lane remains load-bearing for timestamptz fidelity (§3.0 fidelity caveat, §7.1-equivalent framing in the H2 plan).

### 2.4 Duplicated repository methods

`transaction_detail` and `transaction_summary` are each declared in **two** repositories with overlapping queries:

| Method | Repository A | Repository B |
|---|---|---|
| `transaction_detail` | `ClientRepository.getTransactionDetail` (takes String dates, calls `to_timestamp`) | `StockrecordRepository.transactionDetailByClientNumberAndSkuBetweenDates` (takes `Date`) |
| `transaction_summary` | `ClientRepository.getTransactionSummary` (takes String dates) | `StockrecordRepository.transactionSummaryByClientNumberBetweenDates` (takes `Date`) |

Only the `ClientRepository` flavor is wired to the REST endpoints today. The `StockrecordRepository` variants look dead. Consolidate during the port.

### 2.5 Tests

| Test | Covers | Status |
|---|---|---|
| `ClientRepositoryIntegrationTest.GetTransactionDetailSmokeTest` (line 285) | `transaction_detail()` callability | **@Disabled** — real blocker is the PL/pgSQL `transaction_detail()` dependency (the inline landlord-DS comment is stale; that wiring already shipped) |
| *(none)* | `transaction_summary()` | — |
| *(none)* | `stock_history()` | — |

### 2.6 Affected locations

| # | File | Line | Description |
|---|------|------|-------------|
| 0 | `src/main/resources/db/migration/V1.2.05__utc_update_functions.sql` | `stock_history` 47-105, `transaction_detail` 111-470, `transaction_summary` 475-609 | **CURRENT authoritative definition (post-UTC, `timestamptz`) — the port baselines on this file** (PR #47). §2.2.1 |
| 1 | `src/main/resources/db/migration/V1.0.03__wms_functions.sql` | 13-553 | *(historical)* all three functions originally created here; `stock_history` body still latest |
| 2 | `src/main/resources/db/migration/V1.1.04__wms_functions.sql` | 3-501 | *(historical)* `transaction_detail` + `transaction_summary` rewritten; `transaction_summary` body still latest |
| 3 | `src/main/resources/db/migration/V2.1.07__update_transaction_detail_pick_amount_filter.sql` | 9-368 | *(historical)* `transaction_detail` zero-amount filter; latest pre-UTC `transaction_detail` body |
| 4 | `src/main/java/net/aim_ai/wms/repo/jpa/ClientRepository.java` | 49-66 | `getTransactionSummary`, `getTransactionDetail` native queries |
| 5 | `src/main/java/net/aim_ai/wms/repo/jpa/StockrecordRepository.java` | 20-38 | Duplicate `transactionDetailByClientNumberAndSkuBetweenDates`, `transactionSummaryByClientNumberBetweenDates` — **zero callers** (grep-confirmed 2026-06-17), dead |
| 6 | `src/main/java/net/aim_ai/wms/repo/jpa/StockViewRepository.java` | 61-63 | `stockHistoryAfterAsOfDate` native query (corrected from 18-20) |
| 7 | `src/main/java/net/aim_ai/wms/controller/rest/TransactionReportRestController.java` | 76-322 | Two REST endpoints (`getTransactionReport` @76, `getTransactionDetailedReport` @178) calling the report methods |
| 8 | `src/test/java/net/aim_ai/wms/integration/repository/ClientRepositoryIntegrationTest.java` | 284-312 | `@Disabled` smoke test for `transaction_detail` |

---

## 3. Design / Proposed Fix

### 3.1 Strategy: "SQL moves, semantics don't"

Move each function body into a Java `@Service` that issues **parameterized native SQL** via Spring's `NamedParameterJdbcTemplate`. The SQL string is the existing function body, verbatim, with `$1/$2/…` → `:namedParam`, wrapped in `SELECT … FROM (…inner select…) AS t`. The result is mapped to the existing projection interfaces (`StockHistoryView`, `TransactionDetailView`, `TransactionSummaryView`) via `RowMapper<…>`.

**Why this and not a "rewrite in Java streams" approach:**

- The UNION queries are battle-tested production logic. Rewriting as Java loops/streams reintroduces dozens of subtle decision points (null handling, BigDecimal scale, date truncation) that the SQL already has right.
- 350 lines of SQL becomes ~350 lines of Java, with much worse readability and performance.
- The SQL uses no PostgreSQL-exclusive constructs once you strip the `LANGUAGE plpgsql` wrapper and the `EXECUTE … USING` indirection. It works on H2 in PostgreSQL-compat mode and on real PostgreSQL — **except** the `timestamptz` param/compare semantics introduced by the UTC migration, which the Phase A H2 spike must vet and the PG lane backstops (§2.3 H2-fidelity flag).

**What we DO rewrite in Java:** only the `stock_history()` + `transaction_*` composition (the DB function calls `stock_history()` inline). In Java, the services **MUST inline the same sub-SELECT** into the `transaction_*` queries:
- in `transaction_detail`: the `FROM stock_history($3) AS sh` (BEGINNING) / `FROM stock_history($4) AS sh` (ENDING) sites — `V1.2.05:392,458`;
- in `transaction_summary`: the `LEFT JOIN stock_history($2)` (beginning) / `LEFT JOIN stock_history($3)` (ending) sites — `V1.2.05:558,560`.

The inlined fragment is the same `stock_history` body in both, but the substituted param differs per call site (`$3`/`$4` in detail, `$2`/`$3` in summary — §2.2). This is a single round-trip, same cost as today, and preserves the exact null/ordering semantics.

> **DECISION (was "either/or" — now mandatory):** Inlining the sub-SELECT is the **only** acceptable approach. The rejected alternative — calling `stockHistoryService.forDate()` and joining results in-memory — is **rejected** because an in-memory join changes null-handling and row-ordering semantics relative to the DB's `LEFT JOIN … GROUP BY`, which would break the row-for-row parity gate (§5 Phase A / §6). Do not implement option (b).

### 3.0 Tenant datasource wiring — DESIGN DECISION (most important correctness point)

**The new report services MUST execute against the tenant routing datasource, not the `@Primary` landlord datasource.** This is not a fill-in-later detail — getting it wrong silently queries the WRONG database.

Why it matters:
- The existing report path runs through `ClientRepository` (a `net.aim_ai.wms.repo.jpa` repository). Per `TenantDatabaseConfig` (`@EnableJpaRepositories(... transactionManagerRef = "tenantTransactionManager")`), those repositories automatically resolve through the **tenant routing datasource / tenant transaction manager**.
- The report SQL reads **tenant** tables (`stockrecord`, `billoflading_position`, `customerorder_position`, `stock_view`). These live in the per-tenant databases.
- The application's `@Primary` datasource is the **landlord** side (tenant-config lookups only). A naive `new NamedParameterJdbcTemplate(dataSource)` that autowires the unqualified/`@Primary` bean would bind to the landlord DB and return zero rows or wrong data.

**Specification — inject the exact tenant routing bean.** The services must build their `NamedParameterJdbcTemplate` over the `tenantDynamicRoutingDataSource` bean — the same `DataSource` that `tenantEntityManagerFactory` is built on at `TenantDatabaseConfig.java:54-72` (note the `@Qualifier("tenantDynamicRoutingDataSource") DataSource routingDataSource` parameter at line 57). Concretely:

```java
public StockHistoryReportService(
        @Qualifier("tenantDynamicRoutingDataSource") DataSource routingDataSource) {
    this.jdbc = new NamedParameterJdbcTemplate(routingDataSource);
}
```

The bean type is `net.aim_ai.wms.landlord.config.TenantDynamicRoutingDataSource`; the bean name/qualifier is `tenantDynamicRoutingDataSource`. Routing keys are resolved from `TenantContext` per call, so the template inherits the same per-request tenant routing JPA repositories already get.

**Tests work on H2 with the same wiring.** `TestDatabaseConfig` (`src/test/java/net/aim_ai/wms/common/config/TestDatabaseConfig.java:25-45`) registers a `@Primary @Bean(name = "tenantDynamicRoutingDataSource")` mock whose `getConnection()` forwards to the landlord H2 instance. Because the services inject by the same qualifier, the identical wiring resolves to H2 in tests with no service-side change.

> **Fidelity caveat:** in the H2 lane the injected `tenantDynamicRoutingDataSource` is a Mockito mock that forwards to one H2 instance — it does **not** exercise real `TenantContext`-based routing-key resolution. So an H2 report test validates **SQL correctness + row-mapping only**, not that tenant routing resolves to the right per-tenant datasource. Real routing is covered by the Phase A parity IT on the PG Testcontainers lane (§5, §8 Q4), consistent with the §7.1 framing that the PG lane is load-bearing for fidelity.

### 3.2 Per-function design

#### 3.2.1 `StockHistoryReportService` (INTERNAL ONLY — no public endpoint)

> Per §8 open-Q1 (RESOLVED): `stock_history` has **no production caller** today and gets **no public REST endpoint**. Its SQL is needed only as the **inlined fragment** inside `transaction_detail` / `transaction_summary` (§3.1). This service, if created at all, is optional internal organization to hold the shared `SQL_STOCK_HISTORY` fragment — not a public surface. `StockViewRepository.stockHistoryAfterAsOfDate` is deleted (§3.4).

- Shared SQL fragment `SQL_STOCK_HISTORY` = the EXECUTE body of `stock_history()` from **`V1.2.05:59-101`** (function declared at `V1.2.05:47`; `USING $1;` at `V1.2.05:103`), with `$1` → `:asOfDate`, every `''` un-doubled to `'`, and no `RETURN QUERY EXECUTE` wrapper. (Body is byte-identical to the original `V1.0.03` stock_history — §2.2.1.)
- Date param: bind as a `String` consistent with Option A (§3.2.2) so the inlined `to_timestamp(...)` parse matches `transaction_detail`/`transaction_summary`. (`StockHistoryView` projection unchanged.)

#### 3.2.2 `TransactionDetailReportService`

- Input (Option A, §3.2.2): `String clientCode`, `String sku`, `String startDate`, `String endDate` (raw date strings, parsed by `to_timestamp(...)` inside the SQL — same as today)
- Output: `List<TransactionDetailView>`
- SQL constant = EXECUTE body of `transaction_detail()` from **`V1.2.05:116-465`** (function at `V1.2.05:111`; byte-identical to the latest pre-UTC `V2.1.07` body — it carries the zero-amount PICKING filter `sr.amount != 0` at `V1.2.05:318`, §2.2.1), with every `''` un-doubled to `'`. The 4 positional `USING $1,$2,$3,$4` params (`V1.2.05:467`) map to:
  - `$1` → `:clientCode`
  - `$2` → `:sku` (used as `i.item_nr LIKE $2`)
  - `$3` → `:startDate`
  - `$4` → `:endDate`
  - Inline calls to `stock_history($3)` / `stock_history($4)` (`V1.2.05:392,458`) become the body of stock_history with the param substituted (inline only — see §3.1 decision; the in-memory-merge alternative is rejected).
  - Preserve `ORDER BY client_name, sku, transaction_date` (`V1.2.05:465`) and the `UNION` (dedup) joins between the 6 branches.

##### Date-string parsing relocation — UNFLAGGED BEHAVIOR CHANGE with TZ risk (resolve before coding)

Today (post-UTC, on `feature/utc-timezone`), the date string is parsed **in the DB**: `ClientRepository.java:54-55,64-65` wraps the call in `to_timestamp(:startDate, 'YYYY-MM-DD hh24:mi:ss')::timestamptz` (UTC Phase 2.10 changed this from the old `::timestamp without time zone`). There is **no `to_timestamp` inside the function bodies** (verified) — the parse happens only in that JPA wrapper, and the result is now a `timestamptz` matching the `V1.2.05` function signatures.

Moving that parse into the controller via `LocalDateTime.parse(...)` / `DateTimeFormatter` is **NOT a free simplification**: it changes *where* and *in what zone* the string is interpreted. This repo has an **active UTC-timezone migration** (`sbdocs/2-Areas/wms-utc-timezone-migration/`) and a known live "wms2 UI wrong-tz" bug, so any shift in parse locus is high-risk against this plan's own contract ("behavior byte-identical").

**RESOLUTION — choose ONE, state it, and gate it:**

- **Option A (PREFERRED — preserves byte-identity):** Keep `to_timestamp(:startDate, 'YYYY-MM-DD hh24:mi:ss')::timestamptz` **inside the ported SQL string** and bind the raw `String` date params (same as the post-UTC production path). H2 must support both `to_timestamp` AND the `::timestamptz` cast in `MODE=PostgreSQL` — **confirm via the Phase A H2 spike (§5)**; this is the highest-risk H2 portability item now (see §2.3 timestamptz fidelity flag). This keeps the parse in the DB exactly as production does it — zero TZ-locus change. (If H2 chokes on `::timestamptz`, the portable form is `CAST(... AS TIMESTAMP WITH TIME ZONE)`, but verify the compare semantics still match PG in the spike.)
- **Option B (relocate to controller):** Parse to `LocalDateTime` in the controller and bind typed params. **Permitted only if** an explicit acceptance test proves controller-parsed `LocalDateTime` yields the IDENTICAL instant as the old DB `to_timestamp` path across a DST boundary (seed the same string, assert both code paths produce the same stored/compared instant for a spring-forward and a fall-back date). Without that test, Option B is not allowed.

**Chosen for this plan: Option A** (keep `to_timestamp` in the ported SQL). It is the lowest-risk path to byte-identity and removes the TZ-locus question entirely. Option B remains documented only as a fallback if the Phase A H2 spike (§5) shows `to_timestamp` misbehaves on H2 — in which case the DST acceptance test above becomes mandatory.

#### 3.2.3 `TransactionSummaryReportService`

- Input (Option A, §3.2.2): `String clientCode`, `String startDate`, `String endDate`
- Output: `List<TransactionSummaryView>`
- SQL constant = EXECUTE body of `transaction_summary()` from **`V1.2.05:480-604`** (function at `V1.2.05:475`, `USING $1, $2, $3;` at `V1.2.05:606` — **3** positional params; byte-identical to the latest pre-UTC `V1.1.04` body, §2.2.1), with every `''` un-doubled to `'`. The 3 `$N` map to `:clientCode`, `:startDate`, `:endDate`. **Note the inline-`stock_history` here uses `$2`/`$3`** (`LEFT JOIN stock_history($2)`/`($3)` at `V1.2.05:558,560`), not `$3`/`$4` as in `transaction_detail`. Preserve the outer `GROUP BY` and `order by wms_product_id` (`V1.2.05:604`); the single ANSI cast `CAST(sum(shipped) as int8)` (`V1.2.05:490`) is H2-portable as-is.

### 3.3 Controller changes

`TransactionReportRestController` switches from calling `ClientRepository.getTransactionSummary(String, String, String)` / `ClientRepository.getTransactionDetail(...)` to calling the new services.

Under the chosen **Option A** (§3.2.2), the service signatures keep the **`String` date params** and the `to_timestamp(...)` parse stays inside the ported SQL — so the controller's existing date handling (`SimpleDateFormat(WmsConstants.DATE_TIME_PATTERN)` round-trip at `TransactionReportRestController.java:99-111`, then pass the normalized `String` through) is preserved unchanged. No parse-locus change, no DST risk. Service signatures: `TransactionSummaryReportService.run(String clientCode, String startDate, String endDate)` and `TransactionDetailReportService.run(String clientCode, String sku, String startDate, String endDate)`.

(If Option B were ever selected as a fallback, the controller would instead parse to `LocalDateTime` via `DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")` and the DST acceptance test in §3.2.2 would gate it.)

No change to request/response DTOs, no change to OpenAPI schema.

### 3.4 Repository cleanup

- **Delete** `StockrecordRepository.transactionDetailByClientNumberAndSkuBetweenDates` and `transactionSummaryByClientNumberBetweenDates` (unused; confirmed in audit).
- **Delete** `ClientRepository.getTransactionDetail` and `ClientRepository.getTransactionSummary` (replaced by the new services).
- **Delete** `StockViewRepository.stockHistoryAfterAsOfDate` (replaced).
- If any of these are referenced from Spring Data REST or other callers, replace with service calls.

### 3.5 Migration strategy — parallel rollout with feature flag

**Don't drop the PL/pgSQL functions in the same release that introduces the Java path.** Stage in four phases:

1. **Phase A (add Java path):** Introduce the three services. REST endpoints still call the old repository methods. Tests compare Java-path output to DB-function output against the same seeded data.
2. **Phase B (flag flip):** Add `app.report.engine=java|plpgsql` system property (read via `LosSyspropRepository`, default `plpgsql`). Controller branches on the flag. Ship with `plpgsql` default in prod; flip to `java` in staging and bake for 2 weeks.
3. **Phase C (default flip):** Default switches to `java`. PL/pgSQL path remains as fallback.
4. **Phase D (cleanup):** Once Phase C has 1 release in prod with no reports issues, add migration `V2.1.17__drop_report_functions.sql` that drops the **`timestamptz`** signatures left by the UTC migration: `DROP FUNCTION IF EXISTS public.stock_history(timestamptz), public.transaction_detail(varchar, varchar, timestamptz, timestamptz), public.transaction_summary(varchar, timestamptz, timestamptz)`. Remove the `app.report.engine` flag and the DB-function branch of the controller.

> **Flyway numbering (verified 2026-06-17):** On `develop` the head is `V2.1.14`. The `feature/utc-timezone` branch (PR [#47](https://github.com/SiteBossInc/wms2-api/pull/47)) adds `V2.1.15`/`V2.1.16`, so **once it merges the head is `V2.1.16` and the next free is `V2.1.17`** — this plan's drop migration is therefore `V2.1.17` and the restore is `V2.1.18` (the April plan's `V2.1.08`/`V2.1.09` and the UTC branch's `V2.1.15`/`V2.1.16` are all taken). **Re-derive the next-free migration number at Phase D execution time** — Phase D is several release cycles out, so more migrations will almost certainly land before then; do NOT hardcode `V2.1.17`. Run `ls src/main/resources/db/migration/ | sort -V | tail` and take the next free `V2.1.NN`.

If Phase D looks risky (these reports are client-facing), phases C and D can stretch over a quarter. The H2 migration (separate plan) can proceed as soon as Phase C lands — once `app.report.engine=java` is default and tested, H2 compatibility no longer depends on dropping the functions, only on not *requiring* them.

### 3.6 Where the port might leak H2 incompatibility

Most of the usual H2 hazards are **already absent** (verified 2026-06-17, see §2.3). Reviewer checklist for the copied SQL:

- **Doubled single-quotes (`''…''`)** — the dominant porting hazard (§2.3). Every `''` in the PL/pgSQL body must collapse to a single `'` in the Java string. This is the most likely place to introduce a silent bug; the parity test (§6) is the guard.
- **`::type` casts** — **none exist** in the three bodies (grep-confirmed). The only cast is `CAST(sum(shipped) as int8)` at `V1.2.05:490` (in `transaction_summary`), already ANSI form. Under Option A (§3.2.2) the JPA-wrapper cast carried into the SQL is now `to_timestamp(...)::timestamptz` (post-UTC) — write it portably as `CAST(... AS TIMESTAMP WITH TIME ZONE)` and confirm H2 honors the `timestamptz` compare semantics in the Phase A spike (§2.3 timestamptz fidelity flag).
- **`to_timestamp(…)`** — under **Option A** this is KEPT inside the ported SQL (string date params), matching production exactly; H2 supports it in PG mode (confirm in the Phase A spike, §5). Under Option B it would move to the controller — but Option A is chosen precisely to avoid the TZ-locus change (§3.2.2).
- **`date_trunc('second' | 'DAY', …)`** — present and supported by H2 in `MODE=PostgreSQL`; the Phase A spike validates this concretely.
- **String concatenation with `||`** — works on both engines in PG compat mode.
- **`COALESCE`, `CASE WHEN`, `UNION` (dedup — NOT `UNION ALL`; preserve exactly, §2.3), `GROUP BY`, `LEFT JOIN`, `INNER JOIN`, `concat(...)`** — all standard SQL, portable.
- **`ORDER BY column_alias`** — works on both; but see §6 for the deterministic-total-ordering requirement.

Any incompatibility discovered becomes a scope expansion, documented in §8 with a decision (port the call site, or keep that one query on PG-only).

---

## 4. V1/V2 Applicability

This plan is **v2-only**. The v1 codebase (`v1/wms-api`) also has these functions; whether to port them is a separate decision.

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| `stock_history` PL/pgSQL | Present | Present | V1 unchanged; v2 ports to Java |
| `transaction_detail` | Present (v1 commit `4a0a26e` added zero-amount filter — we just ported this as `V2.1.07`) | Present (same body after `V2.1.07`) | V1 unchanged; v2 ports to Java |
| `transaction_summary` | Present | Present | V1 unchanged; v2 ports to Java |
| Tests | v1 has no integration tests for these | v2 has 1 `@Disabled` | Port unblocks v2 tests; v1 unaffected |

### What does NOT need porting

- V1 stays on PL/pgSQL. V1 uses Testcontainers without complaint today, and the v1 → v2 sync workflow only flows in one direction (v1 → v2). We're not porting v2 Java code back to v1.

---

## 5. Implementation Checklist

### Phase A — Add Java path alongside existing (3–4 days)

- [ ] **PR #47 / `V1.2.05` baseline gate (do FIRST, before any SQL is copied).** Run `sbdocs/9-System/scripts/verify-260420-v2-port-plpgsql-functions-to-java-prekickoff.sh` — it machine-checks this gate: PR #47 merged to `develop` (C2), `V1.2.05` `timestamptz` signatures (C3), the §2.2.1 byte-diff provenance vs `V2.1.07`/`V1.1.04`/`V1.0.03` (C4), `ClientRepository` `::timestamptz` casts (C5), and the free drop/restore migration numbers (C6). Exit 0 = gate OPEN. If only C2 fails, #47 has not merged — **do not start porting.** If a C4 check fails, `V1.2.05` diverged in review — re-validate §2.2.1 / re-baseline §2.2/§3.2, or switch to the pre-UTC fallback baseline (re-grounding note guard #2).
- [ ] **H2-portability spike (do not assume H2-readiness on faith).** Extract one function body — `stock_history` — un-double its `''` literals, and run it as a plain parameterized query against an H2 instance in `MODE=PostgreSQL`. Report whether `date_trunc('second'|'DAY', …)`, the `to_timestamp(...)` parse (Option A, §3.2.2), and the un-escaped `LEFT JOIN`/`UNION`/`GROUP BY` SQL all execute clean on H2. If anything fails, capture the exact error and decide (port that construct, or keep that query PG-only per §3.6) before building the other two services.
- [ ] Inject the **`tenantDynamicRoutingDataSource`** bean (§3.0) into each service — NOT the `@Primary`/landlord datasource. Build `NamedParameterJdbcTemplate` over it.
- [ ] Create `service/report/StockHistoryReportService.java` with SQL constant + `RowMapper<StockHistoryView>`.
- [ ] Create `service/report/TransactionDetailReportService.java` with SQL constant + `RowMapper<TransactionDetailView>`.
- [ ] Create `service/report/TransactionSummaryReportService.java` with SQL constant + `RowMapper<TransactionSummaryView>`.
- [ ] Unit tests per service using `NamedParameterJdbcTemplate` mock + seeded rows (no DB).
- [ ] Integration tests per service using Testcontainers PostgreSQL, asserting output **matches the existing DB-function output** against the same seeded dataset per the **parity comparator contract below**. This is the critical correctness gate and the proof that the `''`-un-doubling and `$N`→`:param` mapping (§2.3) were done correctly.
- [ ] Wire services into `TransactionReportRestController` behind a flag (`app.report.engine=java|plpgsql`, default `plpgsql`).
- [ ] Smoke-test both endpoints with flag on/off in a local run.

#### Phase A acceptance criterion — the parity comparator (write this precisely, or the failing test is wrong)

"Java output == DB-function output" is underspecified. The parity test MUST pin all of:

1. **BigDecimal comparison is scale-INSENSITIVE.** PostgreSQL `numeric` and H2 may differ in trailing-zero scale, and `BigDecimal.equals()` is scale-sensitive (`1.0 != 1.00`). Compare with `compareTo(...) == 0`, or normalize scale (`stripTrailingZeros()`) on both sides before comparing. Never use `.equals()` on `BigDecimal`.
2. **Deterministic TOTAL `ORDER BY` is a REQUIREMENT, not an assumption.** Every report query MUST end in an `ORDER BY` over a column set that uniquely orders the rows (e.g. SKU + transaction_date + transaction_number + a tiebreaker), so row order is stable and identical across PostgreSQL and H2. If the existing function body lacks a total order, add the tiebreaker columns to the ORDER BY as part of the port and re-confirm parity against the DB function (the DB function gets the same ORDER BY for the comparison run).
3. **Null vs zero/empty per column.** Assert COALESCE coverage column-by-column: a column that the SQL `coalesce(...,0)`s must be `0` (never `null`) on both sides; a genuinely nullable column must be `null` on both sides. Do not let a `null`↔`0` mismatch pass.
4. **Timestamp precision contract.** The SQL truncates with `date_trunc('second', transaction_date)` and `date_trunc('DAY', sr.modified)`. The comparator must assert the same truncation on both engines — second-precision for `transaction_date`, day-precision (midnight) for the `modified`-derived dates. Compare truncated values, not raw timestamps.

### Phase B — Flag flip in staging (time: parallel to Phase A sign-off)

- [ ] Set `app.report.engine=java` in staging `LosSysprop` seed migration (env-specific, not in main Flyway).
- [ ] Run both reports in staging with real client data (pick 2-3 known clients with active activity). Compare output to prod snapshot.
- [ ] Staging bake time: 2 weeks minimum.

### Phase C — Default flip in prod (1 release cycle after Phase B passes)

- [ ] Change `app.report.engine` default to `java` in application code (not just sysprop).
- [ ] Deploy; monitor report-endpoint error rate + p99 latency for 1 full release cycle.

### Phase D — Cleanup (1 release cycle after Phase C)

- [ ] Add the drop migration at the **next free number** (`V2.1.17__drop_report_functions.sql` after PR #47 merges — but re-derive at execution time, §3.5): drop the **`timestamptz`** signatures the UTC migration left — `DROP FUNCTION IF EXISTS public.stock_history(timestamptz);`, `public.transaction_detail(varchar, varchar, timestamptz, timestamptz)`, `public.transaction_summary(varchar, timestamptz, timestamptz)`.
- [ ] Remove the PL/pgSQL branch of the controller + the `app.report.engine` flag.
- [ ] Delete the three repository native-query methods (§3.4).
- [ ] Update `V1.0.03`, `V1.1.04`, `V2.1.07` to **not** be dropped from migration history (Flyway is forward-only) — the new drop migration is the authoritative "they're gone" marker.
- [ ] Enable `ClientRepositoryIntegrationTest.GetTransactionDetailSmokeTest` — it now works on H2 (no function needed).

### Cross-phase

- [ ] Code review after Phase A.
- [ ] Verifier agent run before Phase C deploy (compare Java vs DB-function output on a fresh seed).
- [ ] Update `sbdocs/3-Resources/architecture/` if a new doc is warranted (optional — probably not; services are self-documenting).

---

## 6. Test Plan

This is a refactor with zero intended behavior change, so **test coverage is the entire value proposition of the plan.** Every "Java vs DB function" comparison below MUST use the **parity comparator contract defined in §5 Phase A** (scale-insensitive BigDecimal via `compareTo`, deterministic total `ORDER BY`, per-column null/zero assertions, `date_trunc` second/day precision). "Identical output" in the tables below is shorthand for "passes that comparator," not naive `List.equals`. Coverage goals:

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| Stock history empty dataset | Seed no activity; call service with `asOfDate=now` | Empty list |
| Stock history single SKU, single receive | Seed 1 item, 1 RECEIVING stockrecord | 1 row with `received=amount`, `historical_stock=total-received` |
| Stock history matches DB function (regression) | Seed 20 mixed activities; run Java service AND `SELECT * FROM stock_history(:d)`; compare row-by-row | Identical output (same columns, same values, same order after ORDER BY) |
| Transaction detail zero-amount PICKING filter | Seed a PICKING stockrecord with amount=0 and one with amount=5 | Output contains only the amount=5 row |
| Transaction detail canceled-order row | Seed a customerorder_position with state=800 (CANCELED) and amountpicked>0 | Output contains a row with `transaction_name='Canceled'` and `depleted_picked` negative |
| Transaction detail BEGINNING/ENDING rows | Seed activity in a date window | Output includes exactly one BEGINNING row and one ENDING row per SKU |
| Transaction detail Java vs DB function | Same seed; Java service output == DB function output | Identical — this is the "are we done?" gate |
| Transaction summary Java vs DB function | Same seed; Java service output == DB function output | Identical |
| Transaction summary canceled-order accounting | Seed normal PICKING + canceled customerorder_position | `depleted_picked` reflects only uncanceled picks |
| Controller flag flip | Call endpoint with `app.report.engine=plpgsql`, then `=java`; same payload | Identical JSON response |

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `StockHistoryReportServiceTest` (unit) | `emptyDataset_returnsEmptyList`, `singleReceive_computesHistoricalStock`, … | RowMapper + SQL shape in isolation |
| `StockHistoryReportServiceIT` (Testcontainers) | `matchesDbFunction_overSeededDataset` | Java output bytewise matches `SELECT * FROM stock_history(:d)` |
| `TransactionDetailReportServiceTest` (unit) | one per UNION branch (shipped, received, picked, canceled, BEGINNING, ENDING, club-run) | Each branch in isolation |
| `TransactionDetailReportServiceIT` (Testcontainers) | `matchesDbFunction_overSeededDataset`, `zeroAmountPickingFiltered`, `canceledOrderRowPresent` | Java vs DB function equivalence |
| `TransactionSummaryReportServiceTest` (unit) | per aggregation branch | Each aggregation in isolation |
| `TransactionSummaryReportServiceIT` (Testcontainers) | `matchesDbFunction_overSeededDataset` | Java vs DB function equivalence |
| `TransactionReportRestControllerTest` (existing — update) | `flag_java_matches_plpgsql` | End-to-end parity through the controller |
| `ClientRepositoryIntegrationTest.GetTransactionDetailSmokeTest` | existing | Re-enable after Phase D (no longer needs function) |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=*ReportService*` | | |
| `mvn verify -Dtest=*ReportServiceIT` | | |
| `mvn verify` (full suite) | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Full behavioral test of the zero-amount filter in isolation from other PICKING logic | The cross-engine parity test (`matchesDbFunction_overSeededDataset`) covers it as a side-effect; a dedicated test is optional |
| Performance test Java vs DB function | Native SQL executes identically regardless of whether it lives in a function or a jdbcTemplate; perf parity is a given. If a reviewer disagrees, add a JMH test in Phase A. |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | No | Services are stateless; SQL constants are `static final` strings; RowMappers are stateless |
| 2 | **Connection pool math** | Change per-request DB connection usage? | No | One DB call per endpoint invocation — identical to today (today is one JDBC call into the function; tomorrow is one JDBC call of the inlined query) |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` / cron job? | No | Reports are user-initiated REST calls |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls? | No | Single statement, read-only, auto-commit on completion |
| 5 | **Request affinity** | Assume a follow-up request lands on the same replica? | No | Stateless |
| 6 | **Retry / idempotency** | Rely on single-execution semantics? | No | Read-only queries are trivially idempotent |
| 7 | **Tenant context** | Use `TenantContext` / `ThreadLocal` across async boundaries? | No | Runs on the caller thread; services inject the **`tenantDynamicRoutingDataSource`** bean (§3.0) — the same routing `DataSource` JPA repositories resolve — so `NamedParameterJdbcTemplate` inherits identical per-request tenant routing. No async hop, no `TenantContext` propagation across threads. |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock? | No | Read-only |
| 9 | **Cache invalidation** | Write to an entity that is cached? | No | Read-only |
| 10 | **External notifications** | Send HTTP / message inside a transaction? | No | Pure read path |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 7 | The new services inject the **`tenantDynamicRoutingDataSource`** bean — the identical `DataSource` that `tenantEntityManagerFactory` (and therefore every `repo.jpa` repository) is built on — so the hand-built `NamedParameterJdbcTemplate` routes through the same per-tenant `TenantDynamicRoutingDataSource` as JPA. NOT the `@Primary`/landlord DS. | Bean declared & consumed at `TenantDatabaseConfig.java:54-72` (qualifier `tenantDynamicRoutingDataSource`, line 57); H2 test forwarder at `TestDatabaseConfig.java:25-45`. Design rationale §3.0. |

---

## 8. Notes

### Rollback

The flagged rollout makes rollback trivial at every phase:

- **Phase A:** the flag is `plpgsql` by default — nothing to roll back.
- **Phase B/C:** set `app.report.engine=plpgsql` via `LosSysprop` to revert without redeploy.
- **Phase D (post-function-drop):** rollback requires re-creating the functions via a new forward migration (Flyway is forward-only — you cannot un-run the drop). The `restore_report_functions` migration takes the **next free number after the drop migration** (`V2.1.18` if the drop landed as `V2.1.17` — re-derive both at execution time per §3.5). **Authoritative bodies for the restore** (copy verbatim — do NOT re-derive from memory): after the `feature/utc-timezone` merge (PR #47), all three functions live in **`V1.2.05__utc_update_functions.sql`** with `timestamptz` signatures — `stock_history()` at `V1.2.05:47-103`, `transaction_detail()` at `V1.2.05:111-467`, `transaction_summary()` at `V1.2.05:475-606`. Restore from **`V1.2.05`**, NOT the pre-UTC `V2.1.07`/`V1.1.04`/`V1.0.03` bodies (those have the wrong `timestamp`-not-`timestamptz` signatures and would not match the post-UTC schema). This is why Phase D should only happen after Phase C is stable for a full release; draft the restore SQL (or a `sbdocs/2-Areas/runbooks/` stub) at Phase C/D time, not at kickoff.

### Parallel work streams

- This plan's **Phase A** unblocks the separate H2 migration plan's **Phase 2** immediately — once the Java path exists, repo/service tests that touch reports can run on H2 even while Phase B/C/D stretch over weeks/months.
- The landlord-datasource spike from the H2 plan is an independent prerequisite. Do it first either way.

### Out of scope

- Rewriting report queries in Java streams / Criteria API. We're moving SQL, not reinventing the reports.
- Adding new report columns or filters. Any such change is a separate plan.
- Changing request/response DTOs. Contracts are frozen for this refactor.
- v1 port. See §4.

### Estimated size

- Phase A: 3–4 days engineering + 1 day code review.
- Phase B: 2 weeks staging bake (calendar time, not effort).
- Phase C: 1 release cycle (calendar).
- Phase D: 0.5 day engineering + 1 release cycle (calendar).
- **Critical-path engineering: ~5 days**; total calendar including bake/soak: ~6 weeks.

### Open questions for reviewer

1. **RESOLVED — `stock_history()` does NOT need a standalone service or endpoint.** Grep across `v2/wms2-api/src` on 2026-06-17 for `stockHistoryAfterAsOfDate` and `stock_history` found **no production caller** beyond the method's own declaration at `StockViewRepository.java:61-63` (corrected from the prior 18-20 ref) — no controller, no service, no test invokes it. The function's only *live* use is its **inlined sub-SELECT inside `transaction_detail`/`transaction_summary`** (`FROM stock_history($3|$4)`, `V1.0.03:389,423`). Therefore: port the `stock_history` SQL only as the inlined fragment used by the two `transaction_*` services; do **not** build a `StockHistoryReportService` public endpoint, and **delete** `StockViewRepository.stockHistoryAfterAsOfDate` (and drop the standalone `stock_history(timestamp)` function in Phase D). Keeping a `StockHistoryReportService` purely as a private SQL-fragment holder is optional internal organization, not a public surface. The `StockrecordRepository.transactionDetailByClientNumberAndSkuBetweenDates` / `transactionSummaryByClientNumberBetweenDates` duplicates likewise have **zero callers** (same grep) and should be deleted per §3.4.
2. **RESOLVED — Date parsing stays in the DB (Option A, §3.2.2).** The prior "controller-layer vs service-layer" question is settled: relocating the parse out of the DB is an **unflagged behavior change** with TZ risk against this repo's active UTC-timezone migration. Keep `to_timestamp(...)` inside the ported SQL with `String` date params (byte-identical to today). Controller-layer relocation (Option B) is a fallback only, gated by a mandatory DST acceptance test.
3. **Single `ReportSqlConstants` class vs per-service constants?** Per-service is cleaner but duplicates the `stock_history` sub-query into `transaction_detail` and `transaction_summary`. A shared constant is better. Decide during Phase A design.
4. **Is the Phase A integration test's "Java output == DB function output" assertion the right gate?** I think yes — it directly answers "did we break anything?" — but it requires Testcontainers for Phase A. That's fine (Phase A is where we still have Testcontainers running); Phase B onwards can H2-ify.

### Decisions needed before kickoff

- Approve phased rollout (A→B→C→D with flag).
- Confirm no report DTO/contract changes.
- Confirm Phase A is scheduled after the H2 plan's Phase 1 (landlord datasource fix), so integration tests unblock simultaneously.

---

## 9. Related Work — Scope Boundary for Full PostgreSQL Independence

This plan covers the **3 PL/pgSQL functions** in v2/wms2-api. Three other PostgreSQL-specific surfaces remain after this plan completes; each is tracked separately:

| Surface | Why it's not here | Tracked by |
|---|---|---|
| **`pg_try_advisory_lock` / `pg_advisory_unlock`** in `AdvisoryLockService.java` — used by **8** scheduled jobs for distributed mutex (raw-JDBC + ThreadLocal connection-pinning at HEAD) | Not a PL/pgSQL function — it's a PG built-in invoked via raw JDBC. Different replacement strategy (interface + per-engine impl, or ShedLock). | [260421-v2-replace-pg-advisory-lock.md](./260421-v2-replace-pg-advisory-lock.md) |
| **186 `nativeQuery = true` repository methods (at HEAD) with PG-specific syntax** — `::text` casts, `FOR UPDATE OF <table>`, PG date math in `MessageRepository`, PG boolean cast in `PrinterRepository` | Too diffuse for a single plan. Addressed per-test (keep on the PG Testcontainers lane) and per-query (migrate opportunistically). | [260420-v2-integration-tests-h2-migration-report.md §2 + §4.3](./260420-v2-integration-tests-h2-migration-report.md) |
| **Landlord datasource wiring in test profile** (the actual cause of most `@Disabled` markers today) | Test infrastructure, not a feature migration. | [260420-v2-integration-tests-h2-migration-report.md §6 Phase 1](./260420-v2-integration-tests-h2-migration-report.md) |

Completing this plan + the advisory-lock sibling plan + the H2 migration plan's Phase 1 together gets `mvn verify` to run on H2 without Docker for the bulk of the suite. A small set of tests (~5, the PG-only list in the H2 migration plan) remain opt-in Testcontainers.
