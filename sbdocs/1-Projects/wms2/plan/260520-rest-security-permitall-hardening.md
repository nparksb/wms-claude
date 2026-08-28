---
title: "SecurityConfiguration: move /rest/** from permitAll() to authenticated()"
ticket: ""
ticket_url: ""
type: "security"
priority: "high"
status: "blocked"
blocked_on: "DEFERRED BY DECISION 2026-08-27 (Nam) — not merely technically blocked. Two decisions were taken on SBDEV-3124: (1) TOPOLOGY — /rest/** is internal-only between WMS and OMS and is NEVER internet-exposed, so the missing auth is defence-in-depth, not a live exposure; SBDEV-3124 was moved to high/blocked on that basis. (2) MECHANISM — Keycloak JWT, same as every other service, which RATIFIES this plan's title and approach; do not re-plan it. Timing: Nam will drive it with the OMS team later, not now. Do not ship the WMS half first. CORRECTED 2026-08-27 (SBDEV-3124 triage) — the prior wording said only 'OMS v2 must send a Keycloak Bearer JWT'. That is directionally right and materially incomplete: WmsApiService::applyAuthentication on oms-laravel-api origin/develop OPENS with an unconditional early return for any URL matching #/rest/#i, so OMS skips auth on this exact surface BEFORE reading any config. Setting WMS_AUTH_TYPE=token changes nothing here. Also: the operative auth config is a per-facility DB lookup (WmsUrlLut::getAuthConfigForFacility), not the config/wms.php env default; and 'token' applies a STATIC opaque bearer, which MultiTenantJwtDecoder rejects — no Keycloak client-credentials flow exists on the OMS side today. So the OMS work is: delete the /rest/ skip + build a client-credentials flow + populate per-facility auth config. Interim stopgap still in effect: app.idempotency.require-auth=false (application.properties:167, commit 40bdc13, Option 1 of 260522-wms2-rest-idempotency-without-jwt-options). NOTE the coded gate at IdempotencyFilter:196-203 defaults to require-auth=TRUE and is disabled only by that property line — and flipping it does NOT cover /rest/stockcount/**, which shouldNotFilter skips."
project:
  - wms2
version: "v2"
requester: ""
created: "2026-05-20"
updated: "2026-08-27"
db_verified: false
db_verified_rationale: "No DB change — pure Spring Security configuration. No Flyway migration or SQL query involved."
related:
  - SBDEV-2222
tags:
  - plan
  - security
  - spring-security
  - oms-integration
---

# SecurityConfiguration: move `/rest/**` from `permitAll()` to `authenticated()`

**Project:** wms2 | **Version:** v2 | **Type:** security hardening
**Priority:** high
**Status:** Blocked (design ready; awaiting OMS-v2 JWT prerequisite)
**Date:** 2026-05-20

---

## 0. Affected Sites (enumeration before drafting)

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `SecurityConfiguration.java:117-121` | `/rest/**` inside `.permitAll()` matcher group alongside docs/error paths | Yes | Yes — single edit target |
| 2 | `IdempotencyFilter.java:104-111` | Defence-in-depth 401 check (compensating control only; fails open when `enforce=false`) | Reference | Reference only — no change |
| 3 | `IdempotencyFilter.java:82-98` | `shouldNotFilter()` carve-outs: GET, `/rest/stockcount/**`, `/rest/transactionreport/**` | Reference | Reference — drives test AC-2 |
| 4 | `SecurityConfigurationTest.java` | No authorization-rule coverage (only bean smoke tests) | Coverage gap | Yes — new test class required |
| 5 | `wms2-end-to-end-request-journey.md:199-208` | IdempotencyFilter documented as sole auth gate for `/rest/**` | Doc drift | Yes — doc update after fix |
| 6 | `wms2-oms-integration-map.md:16` | "JWT authentication" claim aspirational, contradicts code | Doc drift | Yes — `last_verified` update |

**Not in scope:**
- `/rest/transactionreport/**` carve-out in `IdempotencyFilter` (line 94) is a dead path — actual controller is at `/rest/report/**`. Separate bug; flagged in §8 Risks.
- `v1/wms-api` `/rest/**` is intentionally open (v1 OMS uses HTTP basic/no-auth). No change.
- Dead `jwtAuthenticationConverter()` bean at `SecurityConfiguration.java:77-85` (unused; `jwtAccessTokenCustomizer` at line 106 is the wired converter). Tech debt; out of scope.
- `rest.security.api-matcher=/**` property in `application.properties:96` is set but never consumed. Tech debt; out of scope.

---

## 1. Problem Statement

**Symptom (2026-05-20, tenant wine-wsl):**
```
WARN n.a.w.l.config.IdempotencyFilter - [wine-wsl][] Unauthenticated /rest/** caller refused
by IdempotencyFilter: uri=/rest/order/create
```

OMS called `PUT /rest/order/create` without a Keycloak Bearer token. WMS returned 401 — but only because `IdempotencyFilter`'s defence-in-depth check fired (`app.idempotency.enforce=true`). Spring Security itself did not enforce authentication because `/rest/**` is listed under `.permitAll()` in `SecurityConfiguration`.

**Exposed risk:** With `app.idempotency.enforce=false` (dev/test environments), an unauthenticated caller can successfully reach any `/rest/**` handler — processing orders, creating SKUs, triggering stock counts — without a JWT. The fix is latent in production but live-open in any non-prod environment.

**DB verified:** N/A — no DB schema, migration, or query involved. Pure Spring Security configuration change.

---

## 2. Root Cause Analysis

### Bug 1: `/rest/**` listed under `.permitAll()` in SecurityConfiguration

**File**: `SecurityConfiguration.java:116-121`

```java
// BROKEN — /rest/** grouped with genuinely-public docs/error paths
.requestMatchers(
    "/", "/v3", "/v3/token", "/error", "/rest/**", "/api/**",
    "/api-docs/**", "/swagger-ui/**", "/swagger-ui.html",
    "/api/public/**"
).permitAll()
```

**Why it fails (precise mechanism):**

Spring Security evaluates `authorizeHttpRequests` rules in declared order — first match wins.
`/rest/**` matches the `permitAll()` rule, so `AuthorizationFilter` marks every `/rest/**` request
as allowed regardless of authentication state. `BearerTokenAuthenticationFilter` (wired by
`oauth2ResourceServer().jwt()` at `SecurityConfiguration.java:103-108`) will populate the
`SecurityContext` when a valid Bearer token is present — but it does **not** require one for
`permitAll()` endpoints. A request with no `Authorization` header leaves `AnonymousAuthenticationToken`
in the context and passes through Spring Security unchallenged.

**Filter chain ordering (from Architect review):**

`SecurityConfiguration.java:139-141` wires `IdempotencyFilter` via `addFilterAfter(idempotencyFilter, BearerTokenAuthenticationFilter.class)`. Because `AuthorizationFilter` runs later in the chain, the actual 401 source depends on the request:

```
BearerTokenAuthFilter  → (populates SecurityContext if Bearer header present; NO-OP otherwise)
IdempotencyFilter      → runs BEFORE AuthorizationFilter
  ├─ shouldNotFilter()=true  → skip (GET, enforce=false, /rest/stockcount/**, /rest/transactionreport/**)
  └─ shouldNotFilter()=false → check auth → 401 if anonymous (IdempotencyFilter is the gate for POST/PUT with enforce=true)
AuthorizationFilter    → evaluates /rest/**=authenticated() rule
  └─ Only reached when IdempotencyFilter skips: GETs, enforce=false, carve-out paths
     → 401 if anonymous — PRIMARY new gate for GET /rest/** and enforce=false scenarios
```

**Two failure modes (current state):**
1. `app.idempotency.enforce=true` (prod): `IdempotencyFilter` catches anonymous callers on POST/PUT writes. Correct outcome, wrong primary gate.
2. `app.idempotency.enforce=false` (dev/test): `shouldNotFilter()` returns `true` for everything → filter skipped → anonymous caller reaches the handler unauthenticated.

**Historical origin:** `/rest/**` was listed as `permitAll()` at initial v2 check-in (2024-07-16, commit `a685e07b`) — copied from v1/wms-api where OMS historically called WMS without a JWT. SBDEV-2222 (IdempotencyFilter, 2025) added the defence-in-depth 401 check *assuming* Spring Security already enforced auth, but the `permitAll()` was never removed.

**`@ConditionalOnProperty` kill-switch (from Critic review):**

`SecurityConfiguration.java:42` is annotated `@ConditionalOnProperty(prefix = "rest.security", value = "enabled", havingValue = "true")`. When `rest.security.enabled=false`, the entire `SecurityFilterChain` bean is not registered. Spring falls back to auto-configured defaults, which with the OAuth2 resource-server on the classpath may provide no authentication at all. The fix does **not** survive this setting. Fix B (startup WARN) addresses this partially; a deny-all fallback chain is deferred to Phase 2.

---

## 3. Architecture Overview

```
OMS caller (JWT in Authorization header — required after fix)
    │
    ▼
TenantFilter             extracts tenant_name / facility_code from headers
    │
    ▼
BearerTokenAuthFilter    validates JWT if Authorization: Bearer present; NO-OP if absent
    │
    ▼
IdempotencyFilter        addFilterAfter(BearerTokenAuthFilter) — runs BEFORE AuthorizationFilter
  ├─ POST/PUT, enforce=true  → auth-check → 401 if anonymous (IdempotencyFilter emits 401)
  └─ GET / enforce=false / stockcount / transactionreport → skip → falls to AuthorizationFilter
    │
    ▼
AuthorizationFilter      [NEW after fix] /rest/**=authenticated()
  ├─ primary gate for GET /rest/** and all paths when enforce=false
  └─ secondary defence-in-depth for POST/PUT with enforce=true
    │
    ▼
Handler (OrderRestController etc.) — only reached by authenticated callers
```

**Key Files:**

| File | Lines | Role |
|---|---|---|
| `SecurityConfiguration.java` | 186 | Filter chain + authorization rule config — single edit target |
| `SecurityDisabledWarning.java` | new | Startup WARN when `rest.security.enabled=false` |
| `IdempotencyFilter.java` | 297 | Defence-in-depth 401; `shouldNotFilter()` carve-outs — no change |
| `SecurityFilterChainIntegrationTest.java` | new | Auth-rule integration tests (4 tests, 2 nested classes) |
| `SecurityConfigurationTest.java` | ~50 | Existing bean smoke tests — do NOT modify |
| `application.properties` | — | `rest.security.enabled=true`, `app.idempotency.enforce=true` (prod) |
| `wms2-end-to-end-request-journey.md` | — | Filter chain documentation — update §4 |
| `wms2-oms-integration-map.md` | — | Auth model documentation — update `last_verified` |

---

## 4. Fix Design

### Fix A: Dedicated `.authenticated()` rule for `/rest/**`

**File**: `SecurityConfiguration.java:116-121`

**Before:**
```java
// B. Public API / Documentation (Swagger/OpenAPI)
.requestMatchers(
    "/", "/v3", "/v3/token", "/error", "/rest/**", "/api/**",
    "/api-docs/**", "/swagger-ui/**", "/swagger-ui.html",
    "/api/public/**"
).permitAll()
```

**After** — insert the new block BEFORE the `permitAll()` group; remove `/rest/**` from the list:
```java
// B. OMS REST integration — requires valid Keycloak JWT (any authenticated principal).
// MUST appear BEFORE the permitAll() block (Spring Security first-match-wins ordering).
// NOTE on filter-chain ordering: for POST/PUT writes with app.idempotency.enforce=true,
// IdempotencyFilter (addFilterAfter BearerTokenAuthenticationFilter) emits 401 before
// AuthorizationFilter evaluates this rule. This rule is the PRIMARY gate for GET requests
// and when enforce=false. IdempotencyFilter's defence-in-depth at line 104-111 remains
// for POST/PUT writes (secondary gate). Both 401 paths are intentional.
.requestMatchers("/rest/**").authenticated()

// C. Public API / Documentation (Swagger/OpenAPI)
.requestMatchers(
    "/", "/v3", "/v3/token", "/error", "/api/**",
    "/api-docs/**", "/swagger-ui/**", "/swagger-ui.html",
    "/api/public/**"
).permitAll()
```

Update comment section labels accordingly (old B→C, old C→D, old D→E, old E→F).

**Why `.authenticated()` over `.hasAuthority("<role>")`** (Phase 1 decision):
`.authenticated()` accepts any valid Keycloak JWT in the realm. Role-scoping (e.g. `hasAuthority("wms_user")`) is deferred to Phase 2 because the exact Keycloak role on the OMS service-account JWT is not confirmed in the repo. Deploying with a wrong role value would hard-fail all OMS calls. See §10 Q1.

**Why dedicated rule over removing from `permitAll()` and relying on `anyRequest().authenticated()` catch-all:**
An explicit, commented rule is resistant to re-introduction. A future contributor adding a new `permitAll()` path would have to deliberately move or remove this rule, not accidentally drag `/rest/**` back in.

**No change to `IdempotencyFilter`.** The defence-in-depth check at line 104-111 remains. Post-fix it is a genuine secondary layer.

---

### Fix B: Startup WARN when `rest.security.enabled=false`

**New file**: `src/main/java/net/aim_ai/wms/SecurityDisabledWarning.java`

```java
package net.aim_ai.wms;

import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * Emits a startup warning when {@code rest.security.enabled=false}, so a
 * production misconfiguration is visible in logs and alertable.
 *
 * <p>This component is intentionally a <strong>top-level class</strong> —
 * NOT nested inside {@link SecurityConfiguration}. {@code SecurityConfiguration}
 * carries {@code @ConditionalOnProperty(havingValue="true")}; nesting this
 * component inside it would prevent it from being registered when security
 * is disabled (the exact scenario it must detect).</p>
 *
 * @see SecurityConfiguration
 */
@Component
@ConditionalOnProperty(
    prefix = "rest.security",
    value = "enabled",
    havingValue = "false",
    matchIfMissing = false
)
public class SecurityDisabledWarning {

    private static final Logger LOG = LoggerFactory.getLogger(SecurityDisabledWarning.class);

    @PostConstruct
    public void warn() {
        LOG.warn("SECURITY-DISABLED: rest.security.enabled=false — all /rest/** endpoints " +
                 "are UNAUTHENTICATED. Do NOT use this setting outside local development.");
    }
}
```

**Why top-level class:** `SecurityConfiguration` is gated by `@ConditionalOnProperty(havingValue="true")`. An inner class is only registered when the outer bean is registered — so nesting the warning inside `SecurityConfiguration` would prevent it from firing in exactly the scenario it must detect.

---

## 5. Implementation Steps

### §5.1 Prerequisites

| Prerequisite | Applicable? | Notes |
|---|---|---|
| DB state / migration | N/A | Pure Java config change; no Flyway migration |
| Feature flags / sysprops | N/A | No new sysprop; `app.idempotency.enforce` unchanged |
| Config / env changes | No | `application.properties` unchanged |
| **Pre-deploy OMS caller audit** | **Yes** | Confirm ALL `/rest/**` callers send `Authorization: Bearer <jwt>` before deploying. Critical: `GET /rest/stockcount/triggerStockCount` was previously reachable by anonymous callers. |
| Phase 2 OMS role audit | Follow-up | Confirm OMS service-account JWT carries `wms_user` (or another specific role) — prerequisite for Phase 2 `hasAuthority` hardening. |

### §5.2 Steps

1. **Edit `SecurityConfiguration.java`** — add `.requestMatchers("/rest/**").authenticated()` block before the `permitAll()` group (see Fix A). Remove `/rest/**` from the `permitAll()` list. Update comment labels (B→C, C→D, D→E, E→F).

2. **Create `SecurityDisabledWarning.java`** — new top-level file at `src/main/java/net/aim_ai/wms/SecurityDisabledWarning.java` (see Fix B). Import: `jakarta.annotation.PostConstruct`.

3. **Create `SecurityFilterChainIntegrationTest.java`** — new test class at `src/test/java/net/aim_ai/wms/integration/config/SecurityFilterChainIntegrationTest.java` (see §7 Testing Plan for full structure). Do **not** modify the existing `SecurityConfigurationTest.java` — it is a Mockito-only unit test for bean construction and must remain isolated.

4. **Run `mvn test -Dtest=SecurityFilterChainIntegrationTest`** — confirm 4 tests pass (0 failures).

5. **Run `mvn test`** — confirm full suite passes (no regression).

6. **Update `wms2-end-to-end-request-journey.md`** — in the filter-chain section (around line 199-208), add a note that `/rest/**` is `.authenticated()` at the Spring Security layer (primary gate for GETs and `enforce=false`); `IdempotencyFilter` is the defence-in-depth gate for POST/PUT writes.

7. **Update `wms2-oms-integration-map.md`** — update `last_verified: 2026-05-20` in frontmatter. The existing claim "Authentication is via Spring Security OAuth2/OIDC (Keycloak JWT)" (line 16) is now accurate; no rewrite needed.

8. **Run verify script** — `bash sbdocs/9-System/scripts/verify-260520-rest-security-permitall-hardening.sh` → must exit 0 (`Result: N pass, 0 fail`).

9. **Commit and PR** to `develop`.

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `SecurityConfiguration.java` | Modify | Add `.requestMatchers("/rest/**").authenticated()` before `permitAll()` block; remove `/rest/**` from `permitAll()` list; update comment labels |
| `SecurityDisabledWarning.java` | New | Standalone `@Component` startup WARN when `rest.security.enabled=false` |
| `SecurityFilterChainIntegrationTest.java` | New | Auth-rule integration tests (4 tests in 2 outer + 2 nested contexts) |
| `wms2-end-to-end-request-journey.md` | Modify | §4 filter-chain section: note Spring Security as primary auth gate for `/rest/**` |
| `wms2-oms-integration-map.md` | Modify | `last_verified: 2026-05-20`; existing JWT claim becomes accurate |
| `verify-260520-rest-security-permitall-hardening.sh` | New | Verify script (9 assertions) |

---

## 7. Testing Plan

### Unit tests — existing (do not modify)

`SecurityConfigurationTest.java` — Mockito-only bean construction tests. These remain unchanged and must still pass after the fix.

### Integration tests — new

**New class**: `src/test/java/net/aim_ai/wms/integration/config/SecurityFilterChainIntegrationTest.java`

**Rationale for new class**: The existing `SecurityConfigurationTest` extends `BaseUnitTest` (`@ExtendWith(MockitoExtension.class)`) with `@InjectMocks`. It cannot be extended with `@SpringBootTest` — they conflict. The new class is a standalone `@SpringBootTest` slice.

**Full class structure:**

```java
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK)
@AutoConfigureMockMvc
@ActiveProfiles("integration")          // activates H2 datasource (application-integration.properties)
@Import(TestDatabaseConfig.class)       // consistent with BaseIntegrationTest; provides mock RestClient + TenantDynamicRoutingDataSource
@TestPropertySource(properties = {
    "rest.security.enabled=true",       // overrides application-integration.properties:46 (rest.security.enabled=false)
    "app.idempotency.enforce=true"
})
public class SecurityFilterChainIntegrationTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean  // import: org.springframework.test.context.bean.override.mockito.MockitoBean
    private MultiTenantJwtDecoder multiTenantJwtDecoder;

    @MockitoBean
    private RestIdempotencyService restIdempotencyService;

    @MockitoBean
    private KeycloakService keycloakService;

    @MockitoBean
    private CacheManager cacheManager;

    @MockitoBean
    private SecurityProperties securityProperties;  // required by SecurityConfiguration constructor

    // AC-2: GET /rest/** without token → 401 (AuthorizationFilter is the gate for GETs)
    @Test
    void restGet_noToken_returns401() throws Exception {
        mockMvc.perform(MockMvcRequestBuilders.get("/rest/stockcount/triggerStockCount")
                .header("tenant_name", "wine")
                .header("facility_code", "wl"))
                .andExpect(MockMvcResultMatchers.status().isUnauthorized())
                .andExpect(MockMvcResultMatchers.header().exists("WWW-Authenticate"));
    }

    // AC-4: Public endpoints without token → 200 (regression guard)
    @Test
    void publicEndpoints_noToken_returns200() throws Exception {
        mockMvc.perform(MockMvcRequestBuilders.get("/actuator/health"))
                .andExpect(MockMvcResultMatchers.status().isOk());
    }

    // AC-3: enforce=false + no token → 401 from Spring Security (not IdempotencyFilter)
    // Uses nested class to reload context with different property source.
    @Nested
    @TestPropertySource(properties = {
        "rest.security.enabled=true",
        "app.idempotency.enforce=false"   // IdempotencyFilter.shouldNotFilter() → true; AuthorizationFilter is the sole gate
    })
    class WithEnforceFalse {

        @Test
        void restPost_noToken_returns401() throws Exception {
            mockMvc.perform(MockMvcRequestBuilders.put("/rest/order/create")
                    .header("tenant_name", "wine")
                    .header("facility_code", "wl")
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("[]"))
                    .andExpect(MockMvcResultMatchers.status().isUnauthorized());
        }
    }

    // AC-5: SecurityDisabledWarning fires when rest.security.enabled=false
    // Uses OutputCaptureExtension to capture log output from context startup.
    @Nested
    @ExtendWith(OutputCaptureExtension.class)
    @TestPropertySource(properties = "rest.security.enabled=false")  // triggers context reload; SecurityDisabledWarning @PostConstruct fires
    class WithSecurityDisabled {

        @Test
        void securityDisabled_warnIsLogged(CapturedOutput output) {
            assertThat(output.getAll()).contains("SECURITY-DISABLED");
        }
    }
}
```

**Important notes for implementer:**
- Use `@MockitoBean` (NOT deprecated `@MockBean`). Import: `org.springframework.test.context.bean.override.mockito.MockitoBean`.
- The `@Nested` classes with different `@TestPropertySource` each trigger a separate Spring context reload — this is correct JUnit 5 + Spring Test behaviour and is necessary for the `enforce=false` and `security.enabled=false` test isolation.
- `OutputCaptureExtension` is from `org.springframework.boot.test.system.OutputCaptureExtension` — ships in `spring-boot-starter-test`, no new dependency required.
- The `@PostConstruct` fires at context refresh, before the test method runs — `OutputCaptureExtension` captures from context startup onward, so there is no race condition.
- If the test context fails to boot, add additional `@MockitoBean` declarations for any bean that attempts external connections at startup.

### Regression

- `mvn test -Dtest=SecurityConfigurationTest` — existing bean tests must still pass.
- `mvn test` — full suite (44+ existing tests) must pass.
- `mvn verify` — full integration suite (Testcontainers) must pass.

### Manual Test Plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| OMS authenticated order create | Dev, valid Keycloak JWT | `curl -X PUT /rest/order/create -H "Authorization: Bearer <jwt>" -H "tenant_name: wine" -H "facility_code: wl" -d '[...]'` | 204 No Content (or 400 business-error) | |
| OMS unauthenticated order create | Dev, no JWT | Same without `Authorization` header | 401 Unauthorized + `WWW-Authenticate: Bearer` header | |
| `enforce=false` + no JWT | Dev with `app.idempotency.enforce=false` | Unauthenticated curl | 401 from Spring Security (not IdempotencyFilter — confirmed by absence of WARN log) | |
| Swagger UI accessible without auth | Dev | Browser `GET /swagger-ui.html` | 200 OK — docs load | |
| Actuator health without auth | Dev | `curl GET /actuator/health` | 200 OK | |
| Authenticated stock count trigger | Dev, valid JWT | `curl GET /rest/stockcount/triggerStockCount -H "Authorization: Bearer <jwt>"` | 200 OK | |
| Startup warning logged | Dev with `rest.security.enabled=false` | Start application, inspect logs | Log contains `SECURITY-DISABLED: rest.security.enabled=false` | |

---

## 8. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| OMS caller hits `GET /rest/stockcount/triggerStockCount` without JWT (was anonymous-accessible; now requires auth) | Medium | High — endpoint starts 401-ing in production | **Pre-deploy OMS audit required** (§5.1). Check all OMS modules and any internal cron that calls this URL. Fix OMS caller to send JWT before deploying. |
| Dev env uses `enforce=false` and developers relied on unauthenticated `/rest/**` local testing | Medium | Low — only local dev impact | Document: `enforce=false` no longer bypasses Spring Security gate. Devs must use a valid JWT (can use `rest.security.enabled=false` for pure local dev without Keycloak). |
| `rest.security.enabled=false` bypasses entire filter chain | Always (by design) | High in prod | Fix B (startup WARN) makes the misconfiguration visible. Full mitigation (deny-all fallback chain) deferred to Phase 2. |
| Spring Security `BearerTokenAuthenticationEntryPoint` 401 response differs from pre-fix IdempotencyFilter 401 | Certain | Low | Pre-fix: status 401, no `WWW-Authenticate` header. Post-fix: status 401, `WWW-Authenticate: Bearer realm="Realm"` header added. Both return status 401 with empty body. OMS must already handle 401; additive header is RFC 6750 compliant. |
| `/rest/transactionreport/**` carve-out in `IdempotencyFilter` (line 94) is a dead path — actual controller is `/rest/report/**` | Confirmed (existing) | Low (idempotency runs on report endpoints today, which is correct behaviour) | Flagged as separate bug; out of scope. Create follow-up plan after this fix lands. |
| Future contributor adds a new `permitAll()` entry and accidentally re-introduces `/rest/**` | Low | High | The dedicated `.requestMatchers("/rest/**").authenticated()` rule with comment prevents this — it would have to be explicitly removed or overridden. |

---

## 9. Acceptance Criteria & Verify Script

**Verify script**: `sbdocs/9-System/scripts/verify-260520-rest-security-permitall-hardening.sh`

| AC | Description | Check type |
|---|---|---|
| AC-1 | `/rest/**` NOT in `permitAll()` matcher group | Negative grep in `SecurityConfiguration.java` |
| AC-1b | `.requestMatchers("/rest/**").authenticated()` present | Positive grep in `SecurityConfiguration.java` |
| AC-2 | `SecurityFilterChainIntegrationTest` exists with `restGet_noToken_returns401` | File + method grep |
| AC-3 | `WithEnforceFalse` nested class exists | Class grep in test file |
| AC-4 | `WithSecurityDisabled` nested class exists | Class grep in test file |
| AC-5 | `SecurityDisabledWarning.java` exists with `@ConditionalOnProperty(havingValue = "false")` | File + annotation grep |
| AC-6 | `SecurityDisabledWarning.java` imports `jakarta.annotation.PostConstruct` (not `javax`) | Positive grep |
| AC-7 | `mvn test -Dtest=SecurityFilterChainIntegrationTest` passes | Build check |
| AC-8 | `wms2-oms-integration-map.md` contains `last_verified: 2026-05-20` | Doc grep |

All 9 assertions encoded in the verify script. Final acceptance: `Result: 9 pass, 0 fail`.

---

## 10. Open Questions / Resolved Decisions

| # | Question | Decision |
|---|---|---|
| Q1 | `.authenticated()` vs `.hasAuthority(<oms_role>)`? | Phase 1: `.authenticated()` — OMS service-account role not confirmed in-repo. Phase 2: Audit OMS JWT claims, then harden to `hasAuthority("<role>")`. Create follow-up ticket before deploying to prod. |
| Q2 | v1/wms-api same fix? | No — v1 `/rest/**` is intentionally open (v1 OMS uses HTTP basic/no-auth, documented in v1 SecurityConfiguration). |
| Q3 | `rest.security.enabled=false` full mitigation? | Fix B provides startup WARN (partial). Full mitigation (deny-all fallback chain bean) deferred to Phase 2 — separate hardening plan. |
| Q4 | `GET /rest/stockcount/triggerStockCount` current anonymous callers? | Pre-deploy OMS audit required (§5.1). Unknown until audited. |
| Q5 | Dead `jwtAuthenticationConverter()` bean at `SecurityConfiguration.java:77-85`? | Tech debt. The wired converter is `jwtAccessTokenCustomizer` (line 106). The dead bean is harmless but confusing. Separate cleanup. |
| Q6 | Dead `rest.security.api-matcher=/**` property? | Tech debt. Property is set in `application.properties:96` but `filterChain()` never reads it. Separate cleanup. |

---

## 11. Implementation Status

**BLOCKED — not implemented as of 2026-07-16.** Verify script `verify-260520-rest-security-permitall-hardening.sh` reports 1 pass / 11 fail: `/rest/**` is still inside the `permitAll()` group (`SecurityConfiguration.java:121`); `SecurityDisabledWarning.java` and `SecurityFilterChainIntegrationTest.java` do not exist.

**Blocker:** OMS v2 does not yet send a Keycloak Bearer JWT on `/rest/**` calls. Deploying Fix A now would 401 all OMS→WMS traffic (the §8 top risk / §5.1 pre-deploy audit).

**Interim stopgap in effect:** commit `40bdc13` (Option 1 of the report `[[260522-wms2-rest-idempotency-without-jwt-options]]`) added `app.idempotency.require-auth`, currently set to `false` in `application.properties:138`, so `IdempotencyFilter` skips the 401 gate and runs full dedup for anonymous callers. The commit message ties the two together: *"Flip back to true together with the plan 260520 Spring Security /rest/**=authenticated() fix in the same deploy."*

**Unblock path:** once OMS v2 sends a JWT on `/rest/**`, ship Fix A + Fix B and flip `require-auth=false → true` in the same release.

---

## Horizontal Scalability Validation

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | In-JVM state | N/A | No Caffeine / ConcurrentHashMap / static / ThreadLocal added |
| 2 | Connection pool math | N/A | No per-request DB connections changed |
| 3 | Scheduled jobs | N/A | No `@Scheduled` / cron added |
| 4 | Long transactions | N/A | No `@Transactional` added |
| 5 | Request affinity | N/A | Stateless filter-chain rule; no in-memory session state |
| 6 | Retry / idempotency | N/A | No new write path; existing `IdempotencyFilter` unchanged |
| 7 | Tenant context | N/A | No `@Async` / `CompletableFuture` touched |
| 8 | Distributed lock correctness | N/A | No pessimistic / optimistic lock added |
| 9 | Cache invalidation | N/A | No cached entities modified |
| 10 | External notifications | N/A | No HTTP / message sends added |

Pure stateless Spring Security configuration change — horizontal scalability is unaffected.
