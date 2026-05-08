---
type: decision
status: accepted
date: 2022-01-01
system: wms1+wms2
---
# ADR-005: Native SQL Queries Over JPQL

## Status
Accepted

## Context
Both `wms-api` (v1) and `wms2-api` (v2) use Spring Data JPA repositories as the persistence layer. JPA provides two query mechanisms:
- **JPQL** (Java Persistence Query Language): object-oriented query language validated by Hibernate at startup against the entity model.
- **Native SQL**: raw SQL passed directly to the JDBC driver via `@Query(nativeQuery=true)`.

The codebase has made a heavy and deliberate choice toward native SQL:

| Version | `nativeQuery=true` count | Source |
|---|---|---|
| v1 (`wms-api`) | **~277** | `grep -rn "nativeQuery\s*=\s*true" v1/.../src/main/java/ \| wc -l` |
| v2 (`wms2-api`) | **~171** | `grep -rn "nativeQuery\s*=\s*true" v2/.../src/main/java/ \| wc -l` |

This is documented as an explicit pattern in v1's `CLAUDE.md`:

> "Heavy use of `nativeQuery=true` (~270+ annotations) — these bypass JPQL validation and Hibernate caching, so they're sensitive to schema changes."

The entities themselves use plain `Long foreignKeyId` fields (ADR-001), which means multi-table joins cannot be expressed as JPQL association traversals — the query layer must express joins directly in SQL.

## Decision
Native SQL (`@Query(nativeQuery=true)`) is the standard query mechanism for complex multi-table queries in both v1 and v2. JPQL and Spring Data derived queries (`findBy...`) are used only for simple single-entity lookups. New repository methods that involve joins, aggregations, or subqueries must use native SQL.

## Rationale

1. **No JPA associations means no JPQL joins.** Because entities hold `Long foreignKeyId` fields rather than `@ManyToOne` references (ADR-001), JPQL join traversal (`FROM Order o JOIN o.stockUnits s`) is not possible. Native SQL is the only practical mechanism for multi-table queries.

2. **Complex WMS queries are not well-expressed in JPQL.** Warehouse operations involve multi-table joins across orders, stock units, unit loads, locations, replenishment orders, and picking orders. These queries often use database-specific constructs (window functions, lateral joins, `FOR UPDATE SKIP LOCKED`) that JPQL does not support.

3. **Performance control.** Native SQL gives developers direct control over the execution plan. Critical batch paths (order release, replenishment calculation, BOL processing) require predictable query shapes. JPQL leaves plan shape to Hibernate's SQL generation, which can produce unexpected joins or subqueries.

4. **Schema-level flexibility.** Native SQL can query views, CTEs, and non-entity tables (e.g., audit tables, sequence tables, reporting views) that have no JPA entity representation. Several v1 queries target tables not modeled as entities.

5. **Operational familiarity.** The team works directly with PostgreSQL. Native SQL queries can be copied directly into `psql` for debugging and profiling with `EXPLAIN ANALYZE`, without translation from JPQL.

## Consequences

**Trade-offs and risks:**

1. **No Hibernate startup validation.** JPQL queries are parsed and validated against the entity model at application startup — a broken JPQL query fails fast. Native SQL queries are not validated until they execute. A native query that references a renamed or dropped column will compile and deploy successfully, then fail at runtime.

2. **Schema change fragility.** Any column rename, table rename, or column drop in a Flyway migration can silently break native queries. There is no compile-time or startup-time safety net. Teams must manually grep for column references before executing schema migrations.

   Mitigation: Before any schema change, run:
   ```
   grep -rn "<column_name>" <module>/src/main/java/
   ```
   to find all native queries referencing that column.

3. **Hibernate second-level cache bypass.** Native queries bypass Hibernate's entity cache. A native UPDATE or DELETE will not evict cached entity instances, potentially causing stale reads if the second-level cache is ever enabled. (Currently v1 does not use L2 cache, so this is a future risk.)

4. **Portability.** Native SQL is PostgreSQL-specific. This is acceptable given the codebase is deployed exclusively on PostgreSQL and has no stated requirement for database portability.

5. **v1 → v2 query migration.** Native queries in v1 can generally be carried to v2 unchanged, since both target the same PostgreSQL schema family. However, v2 uses a dual-datasource setup (landlord + tenant); native queries must be executed against the correct datasource and transaction manager (see ADR-002).

## Do NOT revisit unless
- A schema migration tooling layer (e.g., jOOQ code generation from the live schema, or Flyway-integrated query validation) is adopted that provides compile-time or startup-time safety for native SQL.
- The team moves to a CQRS/read-model pattern where complex queries are served from a separate projection store, reducing the need for complex joins in the write-model repositories.
- A non-PostgreSQL database is ever required (no current indication this will happen).
