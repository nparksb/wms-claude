---
title: "WMS2 REST Idempotency — Options Without JWT"
type: investigation
status: draft
project:
  - wms2
version: v2
created: 2026-05-22
last_verified: 2026-05-22
related:
  - SBDEV-2222
  - 260520-rest-security-permitall-hardening
tags:
  - report
  - idempotency
  - security
  - oms-integration
---

# WMS2 REST Idempotency — Options Without JWT

**Date:** 2026-05-22
**Context:** OMS v2 (`oms-laravel-api`) is not yet ready to send a Keycloak Bearer token on
inbound `/rest/**` calls to `wms2-api`. The existing idempotency implementation (SBDEV-2222)
requires an authenticated principal before any dedup logic runs. This report analyses what
options exist for `wms2-api` to fully utilise idempotency without a JWT, and gives a
recommendation.

---

## 1. Infrastructure Constraints

| Constraint | Detail |
|---|---|
| CORS allow-list | `wms2-api` accepts requests from `*.sbi.li` only |
| Callers | Only OMS v2 (`oms-laravel-api`) is configured to call `wms2-api` |
| Network | Private subnet / firewall restricts access at the infrastructure layer |
| OMS readiness | OMS v2 cannot send `Authorization: Bearer <jwt>` yet |

> **CORS clarification:** The Spring Security CORS filter is effective for browser-originated
> requests. OMS v2 is a PHP server-side process (GuzzleHttp); it does not send an `Origin`
> header. The real network-level isolation is the infrastructure firewall / private subnet —
> not CORS.

---

## 2. The Core Blocker

The idempotency mechanism itself — SHA-256 key derivation, `tryClaim`, `persistResponse`,
replay, and conflict detection — has **no dependency on JWT**. The blocker is a single
pre-condition check at the top of `IdempotencyFilter.doFilterInternal()`:

```java
// IdempotencyFilter.java:104-111
Authentication auth = SecurityContextHolder.getContext().getAuthentication();
if (auth == null || auth instanceof AnonymousAuthenticationToken || !auth.isAuthenticated()) {
    LOG.warn("Unauthenticated /rest/** caller refused by IdempotencyFilter: uri={}",
        request.getRequestURI());
    response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
    return;   // ← exits BEFORE any dedup logic runs
}
```

Without a JWT, `BearerTokenAuthenticationFilter` (which runs just before `IdempotencyFilter`
in the chain) leaves an `AnonymousAuthenticationToken` in the `SecurityContext`. The filter
hits this gate and returns 401 — `tryClaim`, replay, and `persistResponse` never execute.

**Current `SecurityConfiguration.java:117-121` state:**

```java
.requestMatchers(
    "/", "/v3", "/v3/token", "/error", "/rest/**", "/api/**",
    ...
).permitAll()
```

`/rest/**` is currently `permitAll()` — Spring Security itself does **not** enforce auth
on these endpoints. `IdempotencyFilter`'s defence-in-depth check is the **only** thing
blocking unauthenticated callers (when `app.idempotency.enforce=true`).

The plan `260520-rest-security-permitall-hardening` proposes moving `/rest/**` to
`.authenticated()` in Spring Security — this would add a second, stronger gate — but it
equally requires OMS to send a JWT before it can be applied.

---

## 3. Options

### Option 1 — Trusted-network flag: decouple auth from idempotency enforcement

Add a property `app.idempotency.require-auth` (default `true`) to `IdempotencyFilter`.
When `false`, the 401 pre-condition check is skipped; all dedup logic runs normally for
all callers.

**WMS change only — zero OMS change required.**

```java
// IdempotencyFilter — new field
private final boolean requireAuth;

// doFilterInternal — guard becomes:
if (requireAuth) {
    Authentication auth = SecurityContextHolder.getContext().getAuthentication();
    if (auth == null || auth instanceof AnonymousAuthenticationToken
            || !auth.isAuthenticated()) {
        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        return;
    }
}
```

```properties
# application.properties (prod — until OMS sends JWT)
app.idempotency.enforce=true
app.idempotency.require-auth=false
```

When OMS is ready to send JWT, set `app.idempotency.require-auth=true` and apply the
plan 260520 Spring Security fix in the same deploy.

| | |
|---|---|
| **WMS change** | ~5 lines + one property |
| **OMS change** | None |
| **Keycloak setup** | None |
| **Plan 260520 compatible** | ❌ Deferred — cannot apply `.authenticated()` rule until JWT is in place |
| **Effort** | Lowest |

**Security basis:** Network firewall + private subnet provide real access control. The
`IdempotencyFilter` auth check is a defence-in-depth layer on top; temporarily relaxing
it does not open a real attack surface given the infrastructure constraints.

---

### Option 2 — Pre-shared API key filter *(recommended bridge)*

Add a new `OmsApiKeyAuthFilter` that runs **before** `IdempotencyFilter`. It reads an
`X-Api-Key` header, validates against a configured secret (env var / sysprop), and if
valid inserts a synthetic `UsernamePasswordAuthenticationToken` into the `SecurityContext`.
The existing `IdempotencyFilter` auth check then passes.

**WMS change: new filter. OMS change: add one header in `WmsApiService`.**

```java
// OmsApiKeyAuthFilter.java (new — wired via addFilterBefore IdempotencyFilter)
String apiKey = request.getHeader("X-Api-Key");
if (apiKey != null && apiKey.equals(configuredKey)) {
    UsernamePasswordAuthenticationToken token =
        new UsernamePasswordAuthenticationToken(
            "oms-service", null,
            List.of(new SimpleGrantedAuthority("oms_caller")));
    SecurityContextHolder.getContext().setAuthentication(token);
}
chain.doFilter(request, response);
```

```php
// WmsApiService.php — add to default request headers
'X-Api-Key' => config('wms.api_key'),   // WMS_API_KEY env var
```

| | |
|---|---|
| **WMS change** | New filter class + SecurityConfiguration wiring |
| **OMS change** | One header added to `WmsApiService::makeWmsRequest` |
| **Keycloak setup** | None |
| **Plan 260520 compatible** | ✅ SecurityContext is populated; `.authenticated()` rule passes |
| **Effort** | Low-medium |

**Key management:** Store the shared key in a secrets manager / vault. Rotate by updating
both sides' env vars with no code change. One key can cover all facilities or be scoped
per-facility via `wms_url_lut.config`.

---

### Option 3 — HTTP Basic auth on `/rest/**`

Add `httpBasic()` to `SecurityConfiguration` and an `InMemoryUserDetailsManager` (or
sysprop-backed `UserDetailsService`) with a dedicated OMS inbound account. OMS sends
`Authorization: Basic <base64(user:password)>`.

```java
// SecurityConfiguration.filterChain — add:
.httpBasic(basic -> basic.realmName("wms-rest"))
```

```php
// WmsApiService.php
'Authorization' => 'Basic ' . base64_encode(
    config('wms.basic_user') . ':' . config('wms.basic_password')
),
```

| | |
|---|---|
| **WMS change** | `SecurityConfiguration` + `UserDetailsService` bean |
| **OMS change** | One header added to `WmsApiService::makeWmsRequest` |
| **Keycloak setup** | None |
| **Plan 260520 compatible** | ✅ |
| **Effort** | Low-medium |

**Note:** HTTP Basic over plain HTTP exposes credentials in the clear. Acceptable only
over TLS (which production already enforces). This adds a second auth mechanism type
to the security model that must eventually be retired when JWT is adopted.

---

### Option 4 — Keycloak offline token (long-lived service-account JWT)

Create a Keycloak service account for the OMS-WMS integration, request an `offline_access`
scope token (valid until explicitly revoked — no expiry by default). Store it as an OMS
env var; OMS sends it as `Authorization: Bearer <token>`. No `wms2-api` code change
needed — the existing JWT validation path handles it fully.

```bash
# One-time Keycloak setup (ops step — no code change)
curl -X POST https://keycloak.sbi.li/realms/<realm>/protocol/openid-connect/token \
  -d "client_id=oms-wms-service" \
  -d "client_secret=<secret>" \
  -d "grant_type=client_credentials" \
  -d "scope=offline_access"
# → store "refresh_token" value as WMS_SERVICE_ACCOUNT_TOKEN in OMS env
```

```php
// WmsApiService.php
'Authorization' => 'Bearer ' . config('wms.service_account_token'),
```

| | |
|---|---|
| **WMS change** | None |
| **OMS change** | One env var + one header in `WmsApiService::makeWmsRequest` |
| **Keycloak setup** | Service account + offline token provisioning (one-time) |
| **Plan 260520 compatible** | ✅ |
| **Effort** | Lowest (ops only — no code) |

**Trade-off:** Offline tokens become long-lived secrets. Compromise = full `/rest/**`
access until manually revoked in Keycloak. Rotation requires a coordinated Keycloak +
OMS env var update. Not a substitute for the full `client_credentials` flow OMS should
eventually adopt — but it is the fastest path to a properly authenticated principal
with zero code change on the WMS side.

---

## 4. Comparison

| Option | WMS code | OMS code | Keycloak | Plan 260520 ✅ | Effort |
|---|---|---|---|---|---|
| **1 — trusted-network flag** | 5 lines + property | None | None | ❌ defer | Lowest |
| **2 — API key filter** | New filter + wiring | 1 header | None | ✅ | Low-medium |
| **3 — HTTP Basic** | SecurityConfig + UDS bean | 1 header | None | ✅ | Low-medium |
| **4 — Keycloak offline token** | None | 1 env var | Service acct | ✅ | Lowest (ops) |

---

## 5. Recommendation

### Immediate term — while OMS cannot change

**Option 1 (trusted-network flag)** is the least risky path if OMS cannot ship any
change in the short term. It is a single WMS property (`app.idempotency.require-auth=false`)
that unblocks full idempotency immediately, is trivially reversible, and does not
introduce a new auth mechanism to retire. The network firewall provides real access
control; the `IdempotencyFilter` auth check is defence-in-depth that can be safely
relaxed given the infrastructure constraints.

The only cost is that plan 260520 (Spring Security `.authenticated()` hardening) must
remain deferred until both flags are flipped together in the same JWT-ready deploy.

### If OMS can make a small change

**Option 2 (API key filter)** is the cleanest bridge. It provides application-layer
authentication for `/rest/**` without requiring OAuth2/Keycloak on the OMS side, is
compatible with plan 260520 immediately, and requires only one header addition in
`WmsApiService::makeWmsRequest`. The key can be rotated via env var with no code change.

**Option 4 (Keycloak offline token)** achieves the same result with zero code on either
side — only Keycloak service-account provisioning and an OMS env var. If the Keycloak
admin is available and OMS can accept a new env var, this is the fastest path to a
properly authenticated principal that fully unblocks both idempotency and plan 260520.

### Long-term (regardless of bridge chosen)

OMS v2 adopts the Keycloak `client_credentials` flow (rotating short-lived access tokens).
Plan 260520 `.authenticated()` rule is applied. The bridge mechanism (whichever was chosen)
is retired. `app.idempotency.require-auth=true` (default) is enforced.

---

## 6. What Does NOT Change Regardless of Option

- The SHA-256 key derivation (`method + "|" + path + "|" + body`) is auth-independent and
  works the same in all options.
- `RestIdempotencyService.tryClaim`, `persistResponse`, replay, and conflict detection are
  all auth-independent and work the same in all options.
- `app.idempotency.enforce=true` stays on in production in all options.
- The `rest_idempotency` table, `RestIdempotencyCleanupJob` (7-day retention), and
  `app.idempotency.bridge-mode` behaviour are all unaffected.

---

*Prepared: 2026-05-22. Relates to SBDEV-2222 (idempotency implementation) and
`260520-rest-security-permitall-hardening` (Spring Security `/rest/**` hardening plan).*
