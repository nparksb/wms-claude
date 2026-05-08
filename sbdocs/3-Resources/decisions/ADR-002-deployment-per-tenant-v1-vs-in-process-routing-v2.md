---
type: decision
status: accepted
date: 2022-01-01
system: wms1+wms2
---
# ADR-002: Deployment-Per-Tenant in v1 vs In-Process Routing in v2

## Status
Accepted

## Context
WMS serves multiple warehouse tenants (e.g., `wineco`, `bevc`). Both versions must isolate tenant data. The decision of *how* to achieve that isolation was made differently in v1 and v2.

**v1 (`wms-api`) — Deployment-per-tenant:**
There is no `AbstractRoutingDataSource`, no `TenantContext` ThreadLocal, and no per-tenant connection pool. Instead, each tenant runs its own dedicated JVM instance of `wms-api`:
- Tenant identity is baked into the deployment via `SPRING_PROFILES_ACTIVE` (e.g., `SPRING_PROFILES_ACTIVE=wineco`), set in the `Dockerfile` (`Dockerfile:ENV SPRING_PROFILES_ACTIVE=wineco`).
- `spring.datasource.url` resolves from the active profile's `application-{profile}.properties` — fixed at startup.
- One `HikariDataSource` per JVM (max 5 connections). One PostgreSQL database per tenant.
- Cross-tenant queries are impossible by construction.

Evidence source: `wms1-tenant-routing-datasource-topology.md`, confirmed against `v1/wms-api/src/main/java/` (no `AbstractRoutingDataSource` subclass, no `TenantContext` class anywhere in the source tree).

**v2 (`wms2-api`) — In-process routing:**
A single JVM serves all tenants. Routing is done via:
- `TenantDynamicRoutingDataSource extends AbstractRoutingDataSource` — resolves the active datasource key at query time.
- `TenantContext` ThreadLocal — set by `TenantFilter (@Order HIGHEST_PRECEDENCE)` from the HTTP header `X-Tenant-ID`.
- Routing key: `first4Chars(tenantName) + "-" + facilityCode` (e.g., `wine-cawh`).
- Per-tenant `HikariPool-{key}`, lazily created, evicted after 15 minutes of inactivity.
- Separate `landlordDataSource` for tenant configs and Keycloak metadata.

Evidence source: `wms1-tenant-routing-datasource-topology.md` §7 comparison table, `wms2-tenant-routing-datasource-topology.md`.

## Decision
**v1** uses deployment-per-tenant isolation (one JVM + one DB per tenant). This decision is fixed and will not change in v1.

**v2** uses in-process routing with `AbstractRoutingDataSource` + `TenantContext`. This is the target architecture for all future development.

## Rationale

**Why deployment-per-tenant was chosen for v1:**
1. **Simplicity.** A single static datasource requires zero application-level routing logic. There is no risk of a request being routed to the wrong tenant's database — the JDBC URL is physically fixed.
2. **Complete schema isolation.** Each tenant database can have independent schema migrations, data retention policies, and backup schedules without affecting others.
3. **No shared-state bugs.** There is no ThreadLocal to leak between requests, no pool to exhaust on behalf of another tenant, and no `@Primary` landmine (see ADR-004 v2 analogue).
4. **Lower initial complexity.** At the time v1 was built, the number of tenants was small enough that deploying N containers was operationally acceptable.

**Why in-process routing was chosen for v2:**
1. **Operational scalability.** As the tenant count grows, running N independent JVM instances becomes expensive. A single v2 JVM can serve all tenants with lazy pool creation.
2. **Centralized configuration.** The landlord DB holds all tenant configs; adding a tenant is a DB row + config refresh, not a new deployment.
3. **Kubernetes-friendly.** One deployment with horizontal pod autoscaling is simpler to operate than N per-tenant deployments.

## Consequences

**v1 consequences:**
- Adding a new tenant requires a new deployment (new `SPRING_PROFILES_ACTIVE`, new `spring.datasource.url`, new container).
- Cron jobs operate on the single static datasource — no per-tenant iteration loop exists. Each cron container targets exactly one tenant.
- "Wrong tenant" bugs manifest as misconfigured `SPRING_PROFILES_ACTIVE` or `spring.datasource.url` at container start. Debug by checking env vars on the running container; there is no in-process routing to inspect.
- A single runaway transaction consumes from the shared 5-connection pool, affecting all operations for that tenant (no pool isolation within the tenant).

**v2 consequences:**
- Total PostgreSQL connections = `replicas × tenants × max_per_tenant`. Pool exhaustion risk scales with tenant count.
- The `@Primary` landlord transaction manager is the default for bare `@Transactional`. Any tenant-data operation without an explicit `@Transactional("tenantTransactionManager")` qualifier silently routes to the landlord DB — the single biggest data-routing landmine in v2.
- `TenantContext` must be cleared after each request (handled by `TenantFilter`) to prevent ThreadLocal leaks across pooled threads.

## Do NOT revisit unless
- **v1:** The operational cost of N-per-tenant deployments becomes prohibitive AND the team is prepared to migrate all tenant-specific config, cron logic, and profile-based properties into a landlord DB pattern.
- **v2:** A tenant's data isolation requirement (regulatory, contractual) cannot be met by logical DB-level row separation — i.e., a tenant requires a physically separate PostgreSQL instance. In that case, v2's routing layer can be extended to support a hybrid model, but this requires auditing all `@Transactional` qualifiers.
