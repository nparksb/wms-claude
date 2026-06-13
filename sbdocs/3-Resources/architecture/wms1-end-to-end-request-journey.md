---
title: "WMS v1 — End-to-End Request Journey"
type: architecture
status: active
system: wms1
last_verified: 2026-04-27
version: v1
scope: cross-cutting
owner: Nam Park
created: 2026-04-27
updated: 2026-04-27
verified_by: code read across v1/wms-api + v1/wms-web-ui + v1/wms-mobile-ui
related:
  - ./wms2-end-to-end-request-journey.md
tags:
  - architecture
  - cross-cutting
  - auth
  - wms1
  - request-journey
---

# WMS v1 — End-to-End Request Journey

**Scope:** The full path an HTTP request takes from browser/OMS client → `v1/wms-api` → PostgreSQL and back — filter chain, security, controller dispatch, service, repository, transaction commit, response serialization · **Version:** v1
**Owner:** Nam Park · **Last verified:** 2026-04-27

---

## 1. Overview

v1/wms-api has **two distinct request paths** that share the Spring MVC stack but diverge completely at the security layer:

- **Path A — Authenticated `/v3/` requests** (web UI / mobile UI): JWT bearer token validated by Spring Security OAuth2 Resource Server against Keycloak, then role-checked via `Authority` SpEL expressions.
- **Path B — Unauthenticated `/rest/` requests** (OMS integration): No auth at all — `SecurityConfiguration` completely ignores these paths. Facility validation is done manually via `AbstractRestController.validateWarehouse()` reading `facility_code` from the **request body**.

Key structural differences from v2:

| Concern | v1 | v2 |
|---|---|---|
| Auth stack | Spring Security OAuth2 Resource Server (Spring Boot 2.3 / Spring Security 5.2 `ResourceServerConfigurerAdapter`) | Spring Security 6 `SecurityFilterChain` + `MultiTenantJwtDecoder` |
| Tenant context | No `TenantFilter` — single-tenant per deployment; facility code in body (Path B) or not carried at all (Path A) | `TenantFilter` at `HIGHEST_PRECEDENCE` sets `TenantContext` ThreadLocal for every request |
| Multi-tenancy | Single-tenant per JVM instance — one PostgreSQL schema per warehouse deployment | Dynamic per-tenant datasource routing via `TenantDynamicRoutingDataSource` |
| `/rest/` facility check | `AbstractRestController.validateWarehouse()` reads `facility_code` from JSON body, compares against `LosSysprop` DB value | Not applicable — `TenantFilter` handles facility context from header |
| JWT token customizer | `JwtAccessTokenCustomizer` — extracts roles from Keycloak `resource_access` claim into `OAuth2Authentication`; caches per-user with 2h TTL | `MultiTenantJwtDecoder` — per-tenant decoder cache (Caffeine, 24h TTL since 260610 Phase B) |
| OSIV | Not explicitly disabled — Spring Boot 2.3 default is `open-in-view=true` (OSIV enabled) | Explicitly disabled |

---

## 2. Path A — Authenticated `/v3/` Request (web UI / mobile UI)

### 2.1 Complete Flow

```
 ┌──────────────────────────────── FRONTEND (wms-web-ui / wms-mobile-ui) ─────────────────────────────┐
 │                                                                                                      │
 │ 1. User triggers action → plugins/axios.js onRequest() fires                                        │
 │    Injects:  Authorization: Bearer <$kc.token or localStorage.kcToken>                              │
 │    No X-Tenant-ID or facility_code header — v1 is single-tenant per deployment                      │
 │                                                                                                      │
 │ 2. axios-retry configured at startup:                                                                │
 │    retries: 3 (1s, 2s, 3s), retryCondition: isNetworkOrIdempotentRequestError + 401/403             │
 │    on each retry: refreshes $kc.token, updates Authorization header before replay                    │
 │                                                                                                      │
 └───────────────────────────────────────────────────┬──────────────────────────────────────────────────┘
                                                     │
                                                     ▼
 ┌───────────────────────────────────── BACKEND (wms-api) ─────────────────────────────────────────────┐
 │                                                                                                      │
 │ 3. CorsFilter (FilterRegistrationBean<CorsFilter>) — @Order(HIGHEST_PRECEDENCE)                     │
 │    Registered in SecurityConfigurer.simpleCorsFilter()                                              │
 │    Sets CORS headers; allows all origins (*), all methods, all headers                               │
 │    Runs before Spring Security filter chain                                                          │
 │                                                                                                      │
 │ 4. Spring Security OAuth2 Resource Server filter chain                                               │
 │    Active when rest.security.enabled=true (property in application.properties)                       │
 │    SecurityConfigurer extends ResourceServerConfigurerAdapter (@ConditionalOnProperty)               │
 │                                                                                                      │
 │    4a. OAuth2AuthenticationProcessingFilter                                                          │
 │        Extracts Bearer token from Authorization header                                               │
 │        Delegates to JwtAccessTokenCustomizer.extractAuthentication(tokenMap)                         │
 │        → reads resource_access.{clientId}.roles + groups from JWT claims                            │
 │        → builds OAuth2Authentication with GrantedAuthority list                                     │
 │        → caches result in PassiveExpiringMap (2h TTL keyed by preferred_username)                   │
 │        → if resource_access missing: throws IllegalArgumentException → 401                          │
 │                                                                                                      │
 │    4b. SecurityConfigurer.configure(HttpSecurity) — role checks                                      │
 │        Admin endpoints (/v3/adminAction/**, /v3/losSysprop/**, /v3/systemProperty/**,               │
 │          /mywmsuser/**, /mywmsrole/**, /import/**, /client/**, /group/**, /role/**):                 │
 │          requires hasAuthority(adminGroupPath) OR hasAuthority(aimAdminGroupPath)                    │
 │        All other /v3/**:                                                                             │
 │          requires hasAuthority(userGroupPath) OR hasAuthority(adminGroupPath)                        │
 │        Group/role paths come from:                                                                   │
 │          security.oauth2.app.group (wh01), .user.group (user), .admin.group (wms_admin)              │
 │          → KeycloakService builds full group paths                                                   │
 │        401 if no token or token invalid; 403 if token valid but wrong role                           │
 │                                                                                                      │
 │ 5. DispatcherServlet routes to @RestController under /v3/                                            │
 │    Controllers are NOT @Transactional — service layer owns transactions                              │
 │                                                                                                      │
 │ 6. Service layer — @Transactional (single datasource; no tenant manager needed)                      │
 │    Transaction strategies are mixed:                                                                 │
 │      • class-level @Transactional: BillofladingService, CustomerorderService,                       │
 │        TransferOrderService                                                                          │
 │      • method-level with rollbackFor: GoodsReceiptPositionService,                                  │
 │        ReplenishorderService                                                                         │
 │      • Propagation.REQUIRES_NEW for job steps: job services use isolated TX per step                 │
 │    Plain @Transactional resolves to the single configured datasource (no @Primary                    │
 │    ambiguity — only one datasource in v1)                                                            │
 │                                                                                                      │
 │ 7. Repository layer — Spring Data JPA + heavy nativeQuery=true usage                                 │
 │    ~270+ @Query(nativeQuery=true) annotations across 61 repositories                                 │
 │    Native queries bypass JPQL validation and Hibernate second-level cache                            │
 │    Hibernate fetches connection from configured HikariDataSource                                     │
 │                                                                                                      │
 │ 8. Transaction commits — post-commit hooks                                                           │
 │    OMS notifications deferred via OmsNotificationHelper.deferToCommit()                             │
 │    Uses TransactionSynchronizationManager.registerSynchronization(                                   │
 │        new TransactionSynchronizationAdapter() { afterCommit() { ... } })                           │
 │    On rollback: registration dropped silently (OMS never notified)                                  │
 │    On afterCommit failure: caught + logged, never re-thrown (committed TX is safe)                   │
 │    Fallback: if no TX synchronization active, executes synchronously + propagates exception         │
 │    OMS audit: MessageService.createMessageInNewTransaction() writes Message row with                 │
 │      REQUIRES_NEW so audit commits independently of the publishing TX                               │
 │                                                                                                      │
 │ 9. Response serialization — WebConfigurer (ObjectMapper)                                             │
 │    JsonInclude.NON_NULL — null fields omitted from JSON output                                       │
 │    WRITE_DATES_AS_TIMESTAMPS disabled — dates as ISO-8601 strings                                   │
 │    StdDateFormat with colon in timezone offset (e.g. +05:30)                                        │
 │    JavaTimeModule registered for java.time.* types                                                   │
 │    Date format: "yyyy-MM-dd HH:mm:ss" (via Jackson2ObjectMapperBuilderCustomizer)                   │
 │    Timezone: JVM default (user.timezone=America/Los_Angeles in application.properties)              │
 │    DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES=false (extra fields silently ignored)          │
 │                                                                                                      │
 │ 10. OSIV scope                                                                                       │
 │     spring.jpa.open-in-view NOT set in application.properties                                        │
 │     → Spring Boot 2.3 default: open-in-view=TRUE (OSIV enabled)                                     │
 │     Hibernate session stays open through the HTTP response write phase                               │
 │     Lazy collections accessible from controller/serializer layer                                     │
 │     Risk: lazy-load N+1 during Jackson serialization is silent in logs                               │
 │                                                                                                      │
 └───────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Security Path — What Throws What

| Condition | What fires | HTTP status |
|---|---|---|
| No `Authorization` header | `OAuth2AuthenticationProcessingFilter` → unauthenticated | 401 |
| Token present but signature invalid / expired | JWT token store validation fails | 401 |
| Token valid, `resource_access` claim missing | `JwtAccessTokenCustomizer.extractClients()` throws `IllegalArgumentException` | 401 |
| Token valid, user lacks required Keycloak group | `AccessDeniedException` from SpEL `.access()` check | 403 |
| Valid admin token hitting admin endpoint | Passes — `hasAuthority(adminGroupPath)` satisfied | 200 |
| Valid user token hitting admin endpoint | 403 — `hasAuthority(adminGroupPath)` not satisfied |  403 |

### 2.3 Token Cache Behaviour

`JwtAccessTokenCustomizer` caches `OAuth2Authentication` per username in a `PassiveExpiringMap` with 2-hour TTL. Cache hit condition: `cacheMap.get(username)` returns non-null AND `tokenMap.hashCode()` matches stored principal details hashCode. Role changes in Keycloak take up to 2 hours to propagate unless the user logs out and back in (clearing the cache entry by username key change).

---

## 3. Path B — Unauthenticated `/rest/` Request (OMS integration)

### 3.1 Complete Flow

```
 ┌───────────────────────────────── OMS CLIENT (v1/oms — PHP / Zend Framework 2) ────────────────────┐
 │                                                                                                     │
 │ 1. OMS posts JSON payload to /rest/{resource} (e.g. POST /rest/order/create)                       │
 │    No Authorization header — these endpoints are fully unauthenticated                              │
 │    facility_code field is embedded in the JSON request body (not a header):                         │
 │      { "facility_code": "cawh", "batch_id": "...", ... }                                           │
 │                                                                                                     │
 └────────────────────────────────────────────────┬────────────────────────────────────────────────────┘
                                                  │
                                                  ▼
 ┌───────────────────────────────────── BACKEND (wms-api) ────────────────────────────────────────────┐
 │                                                                                                     │
 │ 2. CorsFilter — @Order(HIGHEST_PRECEDENCE)                                                         │
 │    Same CORS filter as Path A — sets permissive headers                                            │
 │                                                                                                     │
 │ 3. Spring Security — SecurityConfiguration.configure(WebSecurity)                                  │
 │    .ignoring().antMatchers("/rest/**")                                                              │
 │    The entire /rest/** path tree is EXCLUDED from the Spring Security filter chain                  │
 │    No OAuth2AuthenticationProcessingFilter fires; no token extraction attempted                    │
 │    Also excluded: /api/**, /actuator/**, /swagger-*, /v2/api-docs/**, /webjars/**                  │
 │                                                                                                     │
 │ 4. DispatcherServlet routes to @RestController under /rest/                                         │
 │    All /rest/ controllers extend AbstractRestController (package-private base class)                │
 │    Controllers: OrderRestController, AdviceRestController, SkuRestController,                       │
 │      StockCountRestController, TransactionReportRestController                                      │
 │                                                                                                     │
 │ 5. AbstractRestController.validateWarehouse(dto)                                                    │
 │    Reads warehouseId = losSyspropRepository.findSysvalueBySyskey(                                   │
 │        WmsConstants.SYSTEM_PROPERTY_MULTIWAREHOUSE_IDENTIFIER_KEY)                                 │
 │    if dto.getFacilityCode() is blank:                                                               │
 │        throw WebserviceBusinessExceptionClientSide(FIELD_NOT_SET, "facility_code")                 │
 │    if dto.getFacilityCode() != warehouseId (exact string match, case-sensitive):                   │
 │        throw WebserviceBusinessExceptionClientSide(WRONG_FACILITY_CODE, actual, expected)          │
 │    On exception: controller catches it, returns { "status": "failure", "description": "..." }      │
 │    HTTP status from controller: typically 200 with failure body (OMS compatibility pattern)        │
 │                                                                                                     │
 │ 6. Business validation — controller-level checks                                                    │
 │    Controllers perform additional field validation in a try/catch block:                            │
 │    Missing required fields → WebserviceBusinessExceptionClientSide(FIELD_NOT_SET, ...)             │
 │    Duplicate entity → ENTITY_ALREADY_EXITS error code                                              │
 │    Entity not found → ENTITY_DOES_NOT_EXISTS error code                                            │
 │    Each exception produces { "status": "failure", "description": "..." } via getErrorMap()         │
 │                                                                                                     │
 │ 7. Service layer — same @Transactional pattern as Path A                                            │
 │    No SecurityContext in thread (unauthenticated request)                                           │
 │    SecurityContextUtils.getUserName() will return null/default if called from /rest/ path          │
 │                                                                                                     │
 │ 8. Repository / transaction commit — identical to Path A steps 7–8                                 │
 │                                                                                                     │
 │ 9. Response serialization — same ObjectMapper (WebConfigurer), same NON_NULL policy                │
 │    /rest/ responses typically use a plain Map or WebserviceError object, not HATEOAS              │
 │                                                                                                     │
 └────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 facility_code Validation — Critical Details

`facility_code` travels in the **request body** (field on `AbstractWebServiceDto`), not an HTTP header. Every DTO that extends `AbstractWebServiceDto` inherits the `@JsonProperty("facility_code")` field.

The comparison in `validateWarehouse` is a plain `String.equals()` — **case-sensitive, exact match**. If OMS sends `"CAWH"` and the DB sysprop holds `"cawh"`, validation fails with `WRONG_FACILITY_CODE`.

The sysprop key is `WmsConstants.SYSTEM_PROPERTY_MULTIWAREHOUSE_IDENTIFIER_KEY` — look this up in `LosSysprop` table to find the expected value for a given deployment.

### 3.3 Exception-to-HTTP-Status Mapping — `/rest/` Path

The `/rest/` controllers catch `WebserviceBusinessExceptionClientSide` explicitly and return a JSON body with `"status": "failure"`. These are **not routed through `RestExceptionHandler`** — the handler is `@ControllerAdvice` and would apply, but the controllers catch this exception themselves. HTTP status is typically **200** with a failure body for OMS compatibility.

---

## 4. Exception-to-HTTP-Status Mapping — `/v3/` Path

`RestExceptionHandler` (`@ControllerAdvice`) covers the authenticated path. All mappings:

| Exception class | HTTP status | Notes |
|---|---|---|
| `ApiInvalidParameterException` | 422 Unprocessable Entity | explicit business-rule violation with message |
| `ApiConstraintViolationException` | 409 Conflict | DB-level constraint (duplicate key, FK violation) |
| `MethodArgumentNotValidException` | 422 Unprocessable Entity | `@Valid` annotation failure; returns field-level error list |
| `ApiMissingUserException` | 422 Unprocessable Entity | Required user not found in system |
| `SsoCreateUserException` | variable (`ex.getStatusCode()`) | Keycloak user-creation failure; status from SSO upstream |
| `SsoGroupMembershipException` | 400 Bad Request | Keycloak group join/leave failure |
| `SsoException` | variable (`ex.getStatus()`) | General SSO failure; status from exception |
| `BusinessException` (unhandled) | 422 Unprocessable Entity | Safety net for BusinessException escaping controller try/catch; returns `{ "errors": [{ "type": "Error", "message": "..." }] }` |
| `NoSuchElementException` | 404 Not Found | Unguarded `Optional.get()` call; entity not found |
| `NullPointerException` | 500 Internal Server Error | Safety net for `.orElse(null)` + NPE pattern; logs full stack trace |
| Spring Security `AccessDeniedException` | 403 Forbidden | Role check fails (not handled by `RestExceptionHandler` — Spring Security handles directly) |
| JWT validation failure | 401 Unauthorized | Spring Security OAuth2 handles directly |

---

## 5. Transaction Commit Point and OSIV

### 5.1 Transaction boundary

The `@Transactional` boundary in v1 lives at the **service layer**. Controllers are never annotated `@Transactional`. The commit point is the exit of the outermost `@Transactional` method in the service call stack.

There is only one datasource and one transaction manager — bare `@Transactional` always routes to the single warehouse PostgreSQL instance. No risk of "wrong manager" routing that exists in v2.

### 5.2 Post-commit hooks

OMS notifications are deferred to `afterCommit()` via `OmsNotificationHelper.deferToCommit()`:

```java
OmsNotificationHelper.deferToCommit("siteName", "entityId", () -> {
    // HTTP call to OMS
}, (succeeded, statusCode, answer) -> {
    messageService.createMessageInNewTransaction(...);  // REQUIRES_NEW audit row
});
```

Key properties:
- Fires only if TX commits. Rollback silently drops the registration.
- Exception inside `afterCommit()` is caught and logged — never propagates, never rolls back the already-committed TX.
- If no TX synchronization is active (code called outside `@Transactional`): executes synchronously and propagates exceptions.
- The `MessagePersister` callback uses `REQUIRES_NEW` so the audit `message` row commits regardless of outer TX state.

### 5.3 OSIV impact

`spring.jpa.open-in-view` is not set in `application.properties` → Spring Boot 2.3 default is `true` (OSIV **enabled**).

The Hibernate session stays open until the HTTP response is fully written. Consequences:
- Lazy associations on entities can be traversed after the `@Transactional` service method returns, including during Jackson serialization.
- This silently enables N+1 query patterns in serializers — a lazy collection being serialized fires one query per element.
- The transaction has committed by the time serialization runs, but the Hibernate session is still alive for reads.
- If a lazy load during serialization throws (e.g. `LazyInitializationException`), it produces a 500 response after headers may already be flushed.

---

## 6. Frontend — v1 Plugin Chain and Headers

Both `v1/wms-web-ui` and `v1/wms-mobile-ui` use the same plugin set:

```
plugins/axios.js              — interceptors + axios-retry setup
plugins/keycloak.client.js    — Keycloak init (login-required, PKCE)
plugins/persistedState.client.js — Vuex rehydration from localStorage
plugins/cookie.js             — inject $cookies (client only)
```

Note: **no `initTenantAuth.client.js`** — v1 is single-tenant per deployment. The Keycloak realm and client ID are read from a static `config/keycloak.json` file, not fetched from the backend at runtime.

### 6.1 `axios.js` — headers sent on each request

```
Authorization: Bearer <$kc.token or localStorage.kcToken>
```

v1 sends **only the bearer token**. No `X-Tenant-ID`, no `facility_code` header. Facility context on authenticated (`/v3/`) endpoints is implicit — the deployment IS the facility.

On 401/403: `axios-retry` runs `$kc.updateToken()`, updates the `Authorization` header, replays up to 3 times. On final failure: redirects to Keycloak logout.

---

## 7. Where Requests Break (symptom → section)

| Symptom | Start at |
|---|---|
| 401 on first API call after login | §2.2 — confirm JWT carries `resource_access.{clientId}.roles`; check `security.oauth2.resource.id` matches JWT `aud` claim |
| 403 on a specific endpoint | §2.2 role table — confirm user has the Keycloak group for that path; admin endpoints require `wms_admin` group |
| Role change not taking effect | §2.3 — `JwtAccessTokenCustomizer` caches auth by username for 2h; user must log out + back in to bust cache |
| `/rest/` call returns `"status": "failure"` with facility_code error | §3.2 — check OMS is sending correct case-exact `facility_code` value; compare against `LosSysprop.MULTIWAREHOUSE_IDENTIFIER_KEY` |
| `/rest/` call returns `"status": "failure"` with missing field | §3.3 — field-level validation in controller try/catch; check the DTO field listed in the error description |
| Unexpected 422 on `/v3/` endpoint | §4 — `BusinessException` safety net; check logs for "Unhandled BusinessException" — entity not found outside try/catch |
| Unexpected 404 on `/v3/` endpoint | §4 — `NoSuchElementException` safety net; unguarded `Optional.get()` — look for "Unguarded Optional.get()" in logs |
| Unexpected 500 | §4 — `NullPointerException` safety net or OSIV lazy-load failure during serialization (§5.3) |
| N+1 queries during response write | §5.3 — OSIV enabled; lazy collection serialized outside TX; add `@JsonIgnore` or eager-load in service |
| OMS never receives a notification | §5.2 — post-commit hook dropped on rollback; inspect `message` / `message_archived` tables for delivery status |
| Security config not active | `rest.security.enabled=false` in properties — `SecurityConfigurer` is `@ConditionalOnProperty` and won't load |

---

## 8. Known Landmines

1. **`/rest/**` is fully unauthenticated.** `SecurityConfiguration.configure(WebSecurity)` calls `.ignoring()` — Spring Security's filter chain never sees these requests. Any new `/rest/` endpoint is public by default.

2. **facility_code validation is case-sensitive exact match.** `AbstractRestController.validateWarehouse()` uses `String.equals()`. OMS must send the value exactly as stored in `LosSysprop`.

3. **`JwtAccessTokenCustomizer` 2h auth cache.** Role changes in Keycloak take up to 2h to propagate unless the cache entry is evicted by a different username key (logout + re-login with the same username just gets the cached entry). Direct cache invalidation is not supported.

4. **`SecurityConfigurer` is `@ConditionalOnProperty(rest.security.enabled=true)`.** If this property is missing or false, the entire OAuth2 resource server config does not load and all `/v3/**` endpoints are open.

5. **OSIV is enabled (Spring Boot 2.3 default).** Lazy collections can be traversed during serialization, silently enabling N+1 patterns. A `LazyInitializationException` during serialization produces a 500 after headers may be partially written.

6. **`@Transactional` in v1 is safe — one datasource.** Unlike v2, bare `@Transactional` always goes to the single warehouse datasource. No risk of accidentally using a wrong transaction manager.

7. **`AbstractRestController` is package-private.** Only controllers in `net.aim_ai.wms.controller.rest` can extend it. New external integration controllers must live in that package.

8. **Post-commit OMS hooks silently drop on rollback.** A rolled-back TX leaves no OMS trace. Check `message` / `message_archived` to verify delivery. The `MessagePersister` uses `REQUIRES_NEW` so audit rows commit even if the outer TX rolls back — but only if the `afterCommit()` was registered (requires a prior commit).

9. **`/rest/` response format is OMS-compatibility JSON, not HATEOAS.** `WebserviceBusinessExceptionClientSide.getErrorMap()` returns `{ "status": "failure", "description": "..." }` at HTTP 200. This is different from the `{ "errors": [...] }` format returned by `RestExceptionHandler` on `/v3/` endpoints.

10. **CORS filter allows all origins (`*`).** `SecurityConfigurer.simpleCorsFilter()` sets `allowedOrigins(Collections.singletonList("*"))`. No origin restriction.

---

## 9. Related Files (canonical paths)

| Component | Path |
|---|---|
| Security — unauthenticated paths | `v1/wms-api/src/main/java/net/aim_ai/wms/SecurityConfiguration.java` |
| Security — OAuth2 resource server + role rules | `v1/wms-api/src/main/java/net/aim_ai/wms/SecurityConfigurer.java` |
| JWT token customizer + auth cache | `v1/wms-api/src/main/java/net/aim_ai/wms/JwtAccessTokenCustomizer.java` |
| Role/group SpEL helpers | `v1/wms-api/src/main/java/net/aim_ai/wms/Authority.java` |
| Jackson ObjectMapper config | `v1/wms-api/src/main/java/net/aim_ai/wms/WebConfigurer.java` |
| `/rest/` facility validation | `v1/wms-api/src/main/java/net/aim_ai/wms/controller/rest/AbstractRestController.java` |
| `/rest/` base DTO with facility_code | `v1/wms-api/src/main/java/net/aim_ai/wms/json/AbstractWebServiceDto.java` |
| Exception handler (`@ControllerAdvice`) | `v1/wms-api/src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java` |
| OMS post-commit notification helper | `v1/wms-api/src/main/java/net/aim_ai/wms/service/util/OmsNotificationHelper.java` |
| Application properties (security, OSIV, timezone) | `v1/wms-api/src/main/resources/application.properties` |
| Mobile UI axios interceptor | `v1/wms-mobile-ui/plugins/axios.js` |
| Web UI axios interceptor | `v1/wms-web-ui/plugins/axios.js` |
| Sample `/rest/` controller | `v1/wms-api/src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java` |

---

## 10. How to Use This Doc

| Task | Start at |
|---|---|
| Debugging a 401 or 403 on `/v3/` | §2.2 security path table |
| Role change not showing up | §2.3 + §8 item 3 — 2h JWT auth cache |
| `/rest/` OMS call returns facility_code failure | §3.2 + §8 item 2 |
| Adding a new public endpoint (no auth) | §3 — consider whether it belongs under `/rest/` (already public) or needs a `/api/public/` path added to `SecurityConfiguration` ignoring list |
| Adding a new OMS outbound callback | §5.2 + §8 item 8 — use `OmsNotificationHelper.deferToCommit()` |
| Tracing a 422 or unexpected error response | §4 exception table + application logs |
| Understanding OSIV / lazy-load 500s | §5.3 |
| Comparing v1 auth to v2 | §1 overview table + [wms2-end-to-end-request-journey.md](./wms2-end-to-end-request-journey.md) |

---

## 11. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-27 | `SecurityConfiguration` (unauthenticated path list), `SecurityConfigurer` (OAuth2 resource server + role rules + CORS filter), `JwtAccessTokenCustomizer` (token extraction + 2h cache), `Authority` (SpEL builders), `AbstractRestController.validateWarehouse()` (body-based facility_code check), `RestExceptionHandler` (all exception→status mappings), `WebConfigurer` (Jackson NON_NULL + date format + timezone), `OmsNotificationHelper` (afterCommit pattern), `application.properties` (security properties, OSIV absent = default true, `user.timezone=America/Los_Angeles`), v1 frontend axios plugins (Bearer-only header injection) | All file:line refs confirmed against source; no filters or interceptors found beyond Spring Security and the CORS registration bean | Code read across v1/wms-api + v1/wms-web-ui + v1/wms-mobile-ui |

**Re-verify every 60 days.** Next due: **2026-06-26** — any security config change, new exception handler, or OSIV property addition invalidates sections here.
