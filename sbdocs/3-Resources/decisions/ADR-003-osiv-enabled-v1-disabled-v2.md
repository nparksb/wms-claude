---
type: decision
status: accepted
date: 2022-01-01
system: wms1+wms2
---
# ADR-003: OSIV Enabled in v1, Disabled in v2

## Status
Accepted

## Context
Open Session in View (OSIV) is a Spring/Hibernate pattern that keeps the `EntityManager` (JPA session) open through the entire HTTP request lifecycle — including the controller return and view rendering phases, well after the `@Transactional` service method has returned.

**v1 (`wms-api` — Spring Boot 2.3.7):**
`open-in-view` is **not set** in `v1/wms-api/src/main/resources/application.properties`. In Spring Boot 2.x, the default is `true`. OSIV is therefore **on**. Spring Boot 2.x does emit a WARN at startup ("spring.jpa.open-in-view is enabled by default") but the setting was never explicitly overridden.

Evidence: `grep -n "open-in-view" .../v1/wms-api/src/main/resources/application.properties` returns no output — the property is absent, confirming the default applies.

**v2 (`wms2-api` — Spring Boot 3.5.9):**
`spring.jpa.open-in-view=false` is explicitly set at line 41 of `v2/wms2-api/src/main/resources/application.properties`. OSIV is **disabled**.

Evidence: `wms2-transaction-osiv-boundary-map.md` §2 table, confirmed against source (`application.properties:54` — line number may vary by file version).

## Decision
- **v1**: OSIV remains enabled (implicit default). No change will be made.
- **v2**: OSIV is explicitly disabled (`spring.jpa.open-in-view=false`). This is the target posture for all new development.

## Rationale

**Why OSIV was left on in v1:**
OSIV was not a deliberate design choice in v1 — it is the Spring Boot 2.x default that was never overridden. Disabling it in v1 now would require auditing every service method that returns entities with lazy associations (a substantial migration risk for a stable production system). The combination of "OSIV on + manual FK fields (ADR-001)" means lazy associations are not used in production entities, reducing — but not eliminating — the practical blast radius. The risk of retrofitting this change to v1 outweighs the benefit.

**Why OSIV is disabled in v2:**
1. **Correctness over convenience.** With OSIV on, lazy association fetches in the controller/view layer succeed silently but execute outside any transaction — reads are non-atomic and can produce inconsistent snapshots in a concurrent system.
2. **Connection pool pressure.** OSIV holds the database connection open for the full HTTP request lifetime (including serialization, network I/O). Under load, this exhausts the HikariCP pool even when no DB work is happening.
3. **Forces correct fetch strategy.** Disabling OSIV makes `LazyInitializationException` explicit and immediate: any missing fetch inside a `@Transactional` boundary is caught during development, not masked until a specific production code path is hit.
4. **v2 is multi-tenant.** With per-tenant connection pools (see ADR-002), holding connections open through the view layer multiplies pool exhaustion risk across all tenants.

## Consequences

**v1 consequences (OSIV on):**
- Lazy association fetches in controllers or response-building code succeed silently. This masks service methods that return entities without fetching their lazy associations inside the transaction.
- When v1 code is ported to v2, these lazy-load paths break with `LazyInitializationException`. Every v1 → v2 migration must be audited for this pattern.
- Services with no `@Transactional` annotation (see ADR-004) can still perform reads because the OSIV-open session supplies a live connection. This further obscures missing transaction boundaries.

**v2 consequences (OSIV off):**
- All entity association fetches must occur inside a `@Transactional` service method. Controllers must not trigger lazy loads.
- Lazy association debt is tracked under `4-Archieves/wms2/plan/260424-WMS_OSIV_Disabled_Audit.md`.
- Any bare `@Transactional` that fetches across the landlord/tenant boundary (see ADR-004) will fail correctly with an exception rather than silently routing to the wrong datasource.

## Do NOT revisit unless
- **v1**: A performance incident is directly attributed to OSIV holding connections open (requires profiling evidence), AND the team commits to a full audit of all lazy-load paths across 67 entities and 61 repositories.
- **v2**: A new Spring Boot upgrade changes OSIV behavior or introduces a replacement pattern (e.g., virtual-thread-per-request model) that eliminates the connection-hold concern. Re-evaluate only with measured evidence from load testing.
