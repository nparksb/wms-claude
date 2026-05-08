---
title: "WMS v1 — Tenant Routing & DataSource Topology"
type: architecture
status: active
version: v1
scope: multi-tenancy
owner: Nam Park
created: 2026-04-26
updated: 2026-04-26
last_verified: 2026-04-26
verified_by: code read of v1/wms-api src/main at commit HEAD
related:
  - ./wms2-tenant-routing-datasource-topology.md
tags:
  - architecture
  - multi-tenancy
  - datasource
  - hikaricp
  - wms1
---

# WMS v1 — Tenant Routing & DataSource Topology

**Scope:** How a tenant's HTTP request resolves to a PostgreSQL connection in `v1/wms-api` · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-04-26 (code read against `src/main/java` + `src/main/resources`)

---

## 1. Overview

`wms-api` (v1) does **not** implement dynamic datasource routing. There is no `AbstractRoutingDataSource`, no `TenantContext` ThreadLocal, and no per-tenant connection pool. Instead, v1 uses a **deployment-per-tenant** model:

- Each tenant runs its own dedicated instance of `wms-api`, pointed at its own PostgreSQL database via `spring.datasource.url` in `application.properties`.
- The "tenant identity" is baked into the deployment via `SPRING_PROFILES_ACTIVE` (e.g. `wineco`) — set in the Dockerfile (`Dockerfile:ENV SPRING_PROFILES_ACTIVE=wineco`).
- All requests to a running instance share one static `HikariDataSource` backed by one PostgreSQL database.

`facility_code` is **not** a datasource-routing key in v1. It is a **business-logic validation field** sent in the JSON request body of `/rest/**` endpoints (OMS integration), validated against the `MULTIWAREHOUSE_IDENTIFIER` system property stored in the DB.

Two load-bearing facts to hold in memory:

1. **One deployment = one tenant.** There is no in-process tenant switching. Cross-tenant queries are impossible by construction: the JDBC URL is fixed at startup.
2. **`facility_code` in the request body ≠ datasource routing.** It gates which facility a receiving advice / order / stock-count operation applies to, but it does not select a connection pool.

---

## 2. Topology

```
   HTTP request
   (body: { "facility_code": "cawh", ... })
          │
          ▼
   Spring Security filter chain
     ├─ /rest/** → unauthenticated (SecurityConfiguration)
     └─ /v3/**  → Keycloak OAuth2 JWT required
                    └─ group claim validated against `security.oauth2.app.group` (e.g. "wh01")
                                                  │
                                                  ▼
                 Controller → Service (@Transactional)
                                                  │
                   /rest/** (OMS integration):    │
                   AbstractRestController         │
                     └─ validateWarehouse(dto)    │
                           │                      │
                           ├─ dto.getFacilityCode() must be non-empty
                           └─ must equal LosSysprop["MULTIWAREHOUSE_IDENTIFIER"]
                                (DB lookup — single system-property table)
                                                  │
                                                  ▼
                              Hibernate → single EntityManagerFactory
                                                  │
                                                  ▼
                           static HikariDataSource (one pool, max 5 conns)
                                                  │
                                                  ▼
                            single PostgreSQL database
                            (e.g. wh01_om1 at dev.sbo.li:25060)


   Tenant identity: fixed at deployment time via
     application.properties:  spring.datasource.url=jdbc:postgresql://host/wh01_om1
     Dockerfile:               ENV SPRING_PROFILES_ACTIVE=wineco
```

---

## 3. Configuration Facts

### 3.1 Datasource — static, single-tenant

| Fact | Value | Source |
|---|---|---|
| Type | Spring Boot auto-configured `HikariDataSource` (no custom `@Bean`) | `application.properties:24-27` |
| JDBC URL | `jdbc:postgresql://dev.sbo.li:25060/wh01_om1` (dev) | `application.properties:24` |
| Username | `wh01_om1` | `application.properties:25` |
| Driver | `org.postgresql.Driver` | `application.properties:27` |
| Pool max size | **5** | `application.properties:4` |
| Connection timeout | **20,000 ms** (20 s) | `application.properties:3` |
| DDL mode | `none` (Flyway manages schema) | `application.properties:35` |
| Hibernate dialect | `PostgreSQLDialect` | `application.properties:28` |
| Batch size | 50 | `application.properties:41` |
| Timezone | `America/Los_Angeles` | `application.properties:91` |

There is no dynamic datasource bean, no `AbstractRoutingDataSource` subclass, and no `TenantContext` anywhere in `src/main/java/`.

### 3.2 Tenant identity

| Fact | Value | Source |
|---|---|---|
| Mechanism | Spring profile (`SPRING_PROFILES_ACTIVE`) | `Dockerfile:ENV SPRING_PROFILES_ACTIVE=wineco` |
| Effect | Selects profile-specific property overrides (DB URL, Keycloak realm, group names) | `application-{profile}.properties` pattern |
| Scope | Per-deployment — one running JVM = one tenant | — |
| Runtime switching | Not supported — requires redeployment with different profile | — |

### 3.3 `facility_code` — business validation, not routing

| Fact | Value | Source |
|---|---|---|
| Transport | JSON request body field (`"facility_code"`) | `AbstractWebServiceDto.java:9-10` |
| Carrier DTO | `AbstractWebServiceDto` (base), `AdviceDto`, `FacilityDto` | `json/` package |
| Validation class | `AbstractRestController.validateWarehouse(dto)` | `controller/rest/AbstractRestController.java:15-25` |
| Validation logic | Must be non-empty AND must equal `LosSysprop["MULTIWAREHOUSE_IDENTIFIER"]` | `AbstractRestController.java:17-24` |
| System property key | `WmsConstants.SYSTEM_PROPERTY_MULTIWAREHOUSE_IDENTIFIER_KEY = "MULTIWAREHOUSE_IDENTIFIER"` | `WmsConstants.java:1021` |
| Default value (if unset) | `"add_identifier"` | `WmsConstants.java:1022` |
| Routing effect | None — validation only; wrong code returns `WRONG_FACILITY_CODE` error | `AbstractRestController.java:23-24` |

`tenant_name` does not appear as an HTTP header or request body field in any `v1/wms-api` source file. It is a concept at the deployment / Keycloak realm level, not an application-layer routing field.

### 3.4 Authentication / authorization

| Fact | Value | Source |
|---|---|---|
| `/rest/**` | Unauthenticated — OMS integration (PHP → Java) | `SecurityConfiguration.java` |
| `/v3/**` | Keycloak OAuth2 JWT required | `SecurityConfiguration.java` |
| Group claim key | `"groups"` in JWT | `JwtAccessTokenCustomizer.java:51` |
| Required group | `security.oauth2.app.group` (e.g. `wh01`) | `application.properties:84` |
| JWT validation | Public key in `application.properties` (RSA) | `application.properties:61-65` |
| Keycloak realm | `spk` (per `rest.security.issuer-uri`) | `application.properties:57` |

---

## 4. Connection Pool Topology

One `HikariDataSource` per JVM (= per tenant deployment).

### 4.1 Pool settings (from `application.properties`)

| HikariCP setting | Value | Source |
|---|---|---|
| `maximumPoolSize` | **5** | `application.properties:4` |
| `connectionTimeout` | **20,000 ms** (20 s) | `application.properties:3` |
| `minimumIdle` | not set (Hikari default: equals `maximumPoolSize`) | — |
| `idleTimeout` | not set (Hikari default: 600,000 ms / 10 min) | — |
| `autoCommit` | not set (Hikari default: `true`; Hibernate overrides per-transaction) | — |
| `poolName` | not set (Hikari default: `HikariPool-1`) | — |

No per-tenant pool. No pool eviction. No lazy pool creation. Pool is created once at application startup.

### 4.2 Pool lifecycle

| Event | What happens |
|---|---|
| Application startup | `HikariDataSource` created from `spring.datasource.*` properties; standard Spring Boot auto-configuration |
| Every request | Borrows connection from the single pool (max 5) |
| Connection timeout | If all 5 connections are held for >20 s, caller gets `SQLTimeoutException` |
| Application shutdown | Pool closed via Spring `DisposableBean` |
| New tenant needed | Requires new deployment (new `SPRING_PROFILES_ACTIVE`, new `spring.datasource.url`) |

---

## 5. Request Lifecycle

### 5.1 `/rest/**` — OMS integration (unauthenticated)

```
1. OMS (PHP) sends HTTP POST to /rest/advice, /rest/order, etc.
   Request body contains { "facility_code": "cawh", ... }

2. Spring Security passes through (unauthenticated path).

3. Controller calls AbstractRestController.validateWarehouse(dto):
   a. dto.getFacilityCode() must be non-empty → else FIELD_NOT_SET error
   b. value must equal LosSysprop["MULTIWAREHOUSE_IDENTIFIER"] (DB lookup)
      → else WRONG_FACILITY_CODE error

4. Service method executes with @Transactional.
   Hibernate borrows a connection from the single HikariPool.

5. Query executes against the single PostgreSQL database.

6. Connection returned to pool on transaction commit/rollback.
```

### 5.2 `/v3/**` — Web/mobile UI (authenticated)

```
1. Frontend sends HTTP request with Bearer JWT (Keycloak token).

2. Spring Security validates JWT:
   a. Signature verified against RSA public key.
   b. `groups` claim extracted; must contain security.oauth2.app.group value.

3. Controller method executes.
   facility_code (where needed) comes from the request payload or path variable,
   not from a routing-level context.

4. Service → Hibernate → single HikariPool → PostgreSQL.
```

There is no "cleanup" step for tenant context because there is no tenant context to clean up.

---

## 6. Scheduled Jobs

Cron jobs (`app.cron=true`) operate on the single datasource with no tenant-iteration loop. Each job works directly against the one configured database.

| Job | File |
|---|---|
| `OrderReleaseJob` | `schedulejob/OrderReleaseJob.java` |
| `ReplenishOrderJob` | `schedulejob/ReplenishOrderJob.java` |
| `StockSummaryExportJob` | `schedulejob/StockSummaryExportJob.java` |
| `CleanUpOldMessagesJob` | `schedulejob/CleanUpOldMessagesJob.java` |
| `ReleaseExpiredPickingOrdersFromUserJob` | `schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java` |

No advisory lock service. No cross-replica coordination. Cron is enabled via `app.cron=true` in `application.properties` and gated by `@ConditionalOnProperty`. Cron expressions come from the `LosSysprop` table.

---

## 7. v1 vs v2 Differences

| Aspect | v1 (`wms-api`) | v2 (`wms2-api`) |
|---|---|---|
| Multi-tenancy model | **Deployment-per-tenant** (one JVM per tenant) | **In-process routing** (one JVM serves N tenants) |
| Datasource count | **1** (static, at startup) | **N** (one `HikariDataSource` per tenant-facility, lazily created) |
| Routing mechanism | None — `spring.datasource.url` is fixed | `TenantDynamicRoutingDataSource extends AbstractRoutingDataSource` |
| Routing key | Not applicable | `first4Chars(tenantName) + "-" + facilityCode` (e.g. `wine-cawh`) |
| `tenant_name` role | Spring profile (`SPRING_PROFILES_ACTIVE=wineco`) — selects DB URL | HTTP header `X-Tenant-ID` — part of in-process routing key |
| `facility_code` role | JSON request body field — **business validation only** (must match `MULTIWAREHOUSE_IDENTIFIER` sysprop) | HTTP header + routing key component — **selects which datasource to use** |
| TenantContext ThreadLocal | **Does not exist** | `TenantContext` (ThreadLocal) set by `TenantFilter` |
| Filter/interceptor | None for tenant routing | `TenantFilter (@Order HIGHEST_PRECEDENCE)` |
| Landlord DB | **Does not exist** — no tenant directory | Separate `landlordDataSource` for tenant configs + Keycloak metadata |
| Connection pool | Single `HikariPool-1`, max 5, static | Per-tenant `HikariPool-{key}`, max 5 default, lazy create / 15-min evict |
| Tenant config source | `application.properties` / Spring profile | `TenantDbConfiguration` table in landlord DB |
| Pool eviction | None | `TenantPoolEvictor` (every 5 min, 15-min idle threshold) |
| Config refresh | None (restart required) | `TenantConfigLoader` (every 5 min) |
| Advisory locks | None | `AdvisoryLockService` (`pg_try_advisory_lock` on landlord) |
| Async/ThreadLocal risk | Not applicable (no ThreadLocal) | `TenantAwareTaskDecorator` exists but unwired — `@Async` loses context |
| New tenant onboarding | New deployment | Landlord DB row → visible after next config refresh (up to 5 min) |
| Horizontal scaling | Multiple instances all share the same single DB | Multiple instances each create per-tenant pools — total PG conns = `replicas × tenants × max_per_tenant` |

---

## 8. Common Failure Modes

### 8.1 Wrong `facility_code` in request body
**Symptom:** `WRONG_FACILITY_CODE` error returned from `/rest/**` endpoints.
**Cause:** The `facility_code` in the JSON body does not match the `MULTIWAREHOUSE_IDENTIFIER` system property in the DB.
**Fix:** Verify the value in `LosSysprop` table (`syskey = 'MULTIWAREHOUSE_IDENTIFIER'`) matches what the OMS is sending. The default value `"add_identifier"` indicates the system property was never set.

### 8.2 Missing `facility_code` in request body
**Symptom:** `FIELD_NOT_SET` error for field `"facility_code"`.
**Cause:** The OMS call omitted the field or sent `null`.
**Fix:** OMS caller must always include `"facility_code"` in request body for `/rest/advice`, `/rest/order`, etc.

### 8.3 Connection pool exhaustion (max 5)
**Symptom:** `SQLTimeoutException` after 20 s; requests queue and eventually fail.
**Cause:** All 5 HikariCP connections held simultaneously (long transactions, slow queries, lock contention).
**Fix:** Identify slow/blocked transactions via PostgreSQL `pg_stat_activity`. Pool size is `spring.datasource.hikari.maximumPoolSize=5` — raise if workload justifies it (note: raising requires restart). At 5, this pool is sized conservatively.
**Note:** Unlike v2, there is no per-tenant pool isolation — a single runaway transaction consumes from the shared pool affecting all operations.

### 8.4 Wrong tenant database
**Symptom:** Data from a different tenant appears, or expected entities are absent.
**Cause:** Deployment is pointing at the wrong `spring.datasource.url` or the wrong `SPRING_PROFILES_ACTIVE` was set at container start.
**Fix:** Verify the JDBC URL in the running container (`SPRING_PROFILES_ACTIVE` env var + active `application-{profile}.properties`). There is no in-process routing to debug — the database is fixed.

### 8.5 Keycloak group mismatch (`/v3/**` returns 403)
**Symptom:** Authenticated requests to `/v3/**` return 403.
**Cause:** The JWT's `groups` claim does not match `security.oauth2.app.group` (e.g. `wh01`). This happens when a user from a different Keycloak realm or group tries to access the wrong tenant's instance.
**Fix:** Verify the user's Keycloak group membership and the `security.oauth2.app.group` property for this deployment.

### 8.6 Scheduled job runs against wrong database
**Symptom:** Cron job processes orders/replenishments for the wrong tenant.
**Cause:** The container's `SPRING_PROFILES_ACTIVE` or `spring.datasource.url` was misconfigured at deployment.
**Fix:** Same as 8.4 — cron jobs use the same single static datasource. There is no per-tenant iteration in v1 cron.

---

## 9. How to use this doc

| Task | Start at |
|---|---|
| Debug "wrong facility_code" errors from OMS | §3.3 + §8.1–8.2 |
| Debug "data from wrong tenant" | §8.4 — check deployment config |
| Investigating connection-pool exhaustion | §4.1–4.2 + §8.3 |
| Understanding why v1 has no TenantFilter | §1 + §7 |
| Comparing v1 vs v2 multi-tenancy | §7 in full |
| Adding a new OMS-integrated endpoint (`/rest/**`) | §5.1 + §3.3 — must call `validateWarehouse()` |
| Planning v1→v2 migration of tenant routing | §7 — note that `facility_code` changes role entirely |
| Debugging 403 on `/v3/**` | §3.4 + §8.5 |

---

## 10. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-26 | `application.properties` (full file), `AbstractRestController.java`, `AbstractWebServiceDto.java`, `JwtAccessTokenCustomizer.java`, `SecurityConfiguration.java`, `SecurityConfigurer.java`, `SecurityProperties.java`, `WmsConstants.java` (lines 1021-1022), `Dockerfile` (`SPRING_PROFILES_ACTIVE`), `schedulejob/` directory listing, `application_dev.properties` datasource block | No `AbstractRoutingDataSource`, no `TenantContext`, no `ThreadLocal` in any source file. Single static `HikariDataSource`. `facility_code` is body field, not routing key. `tenant_name` = Spring profile. All counts and file:line refs confirmed. | Code read (grep-based) |

**Re-verify every 60 days.** Next due: **2026-06-25** — or sooner if a v1→v2 migration of the `/rest/**` OMS integration path is planned.
