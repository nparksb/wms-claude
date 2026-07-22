---
title: "WMS v2 — End-to-End Request Journey"
type: architecture
status: active
version: v2
scope: cross-cutting
owner: Nam Park
created: 2026-04-19
updated: 2026-07-03
last_verified: 2026-07-03
verified_by: code read across v2/wms2-api + v2/wms2-web-ui + v2/wms2-mobile-ui; §3.1/§3.2 updated for SBDEV-2390 (check-sso + kc-redirect-guard loop-breaker); §4.2 re-confirmed against 260610 Phase B (PR #41)
related:
  - ./wms2-tenant-routing-datasource-topology.md
  - ./wms2-transaction-osiv-boundary-map.md
  - ../data-dictionary/wms2-sysprop-catalog.md
  - ../../../v2/wms2-web-ui/CLAUDE.md
  - ../../../v2/wms2-mobile-ui/CLAUDE.md
tags:
  - architecture
  - cross-cutting
  - auth
  - multi-tenancy
  - frontend-backend
  - wms2
---

# WMS v2 — End-to-End Request Journey

**Scope:** The full path one browser click takes across `wms2-web-ui` / `wms2-mobile-ui` → `wms2-api` → PostgreSQL and back · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-04-19

---

## 1. Overview

Most "wrong data is showing up" / "auth is broken" / "tenant mismatch" bugs live in the seams between the frontend plugin load order, the Keycloak token refresh loop, the axios request interceptor, and the backend `TenantFilter` → `TenantContext` → routing datasource. Each piece is covered in its own doc; this doc stitches them into one linear walkthrough so a debug session can start from a single page.

Two load-bearing facts to anchor the journey:

1. **`TenantContext` on the backend is a ThreadLocal.** It exists for exactly one HTTP request. The frontend is responsible for sending the two headers (`X-Tenant-ID` + `facility_code`) on *every* request — if either is missing or stale, the backend falls through to the landlord datasource (see [wms2-tenant-routing-datasource-topology.md](./wms2-tenant-routing-datasource-topology.md) §10 item 2).
2. **Keycloak state on the mobile UI lives on `window.__keycloakState`.** Module-scope variables would be reset on Nuxt page navigation, causing infinite re-init loops; the module deliberately stashes the instance on `window` (see `v2/wms2-mobile-ui/plugins/keycloak.client.js:6-19`).

---

## 2. The Journey — 10 Steps

```
 ┌──────────────────────────────────────── FRONTEND ─────────────────────────────────────┐
 │                                                                                        │
 │ 1. User opens https://{warehouse}-{tenant}.wms.siteboss.net/mobile                     │
 │ 2. Nuxt plugin chain fires (order matters):                                            │
 │       a. plugins/axios.js           — retry + interceptor setup                        │
 │       b. plugins/initTenantAuth.client.js  — subdomain → clientName+warehouse;         │
 │          fetches /api/public/authConfig?key={warehouse}-{clientName}                   │
 │          stores tenantKeycloakConfig in localStorage + dispatches setWarehouse         │
 │       c. plugins/keycloak.client.js — new Keycloak(config).init(check-sso, PKCE)       │
 │          stashes state on window.__keycloakState                                       │
 │       d. plugins/persistedState.client.js — rehydrates Vuex from localStorage          │
 │       e. plugins/cookie.js (client only) — inject $cookies                             │
 │                                                                                        │
 │ 3. Token refresh loop (keycloak.client.js):                                            │
 │       every 60 s call $kc.updateToken(120)                                             │
 │       persist kcToken + kcRefreshToken to localStorage                                 │
 │       onAuthRefreshError → logout                                                      │
 │                                                                                        │
 │ 4. User triggers an action → axios request outbound                                    │
 │    plugins/axios.js onRequest() injects:                                               │
 │       Authorization: Bearer <$kc.token or localStorage.kcToken>                        │
 │       X-Tenant-ID: localStorage.clientName                                             │
 │       facility_code: store.selectedWarehouse (fallback localStorage.selectedWarehouse) │
 │                                                                                        │
 └────────────────────────────────────────────┬───────────────────────────────────────────┘
                                              │
                                              ▼
 ┌──────────────────────────────────────── BACKEND ──────────────────────────────────────┐
 │                                                                                        │
 │ 5. TenantFilter.doFilter() — @Order(HIGHEST_PRECEDENCE)                                │
 │    reads X-Tenant-ID + facility_code, lowercases both                                  │
 │    if path starts with /api/public/... → TenantContext=null, skip                      │
 │    else → TenantContext.setCurrentTenant(new TenantProfile(t, f))                      │
 │    puts MDC key {tenantPrefix}-{facilityCode} for log correlation                      │
 │                                                                                        │
 │ 6. Spring Security (MultiTenantJwtDecoder) validates JWT                               │
 │    resolves tenant-specific Keycloak realm via TenantAuthConfigCache                   │
 │    jwtDecoders.get(tenantKey, ...) — per-tenant Caffeine decoder cache (24h TTL)              │
 │                                                                                        │
 │ 7. Controller dispatch — no @Transactional here (rule)                                 │
 │                                                                                        │
 │ 8. Service layer: @Transactional("tenantTransactionManager") or @TenantTransactional   │
 │    Hibernate asks TenantIdentifierResolver for current tenant                          │
 │    returns tenantKey or "BOOTSTRAP" if context null                                    │
 │    TenantDynamicRoutingDataSource.determineTargetDataSource()                          │
 │       tenantPools.computeIfAbsent(key, ...) → per-tenant HikariDataSource              │
 │       lastAccess.put(key, now)                                                         │
 │                                                                                        │
 │ 9. Query hits per-tenant PostgreSQL; response assembled                                │
 │    post-commit hooks (TransactionSynchronizationManager.registerSynchronization)       │
 │       fire external side-effects — OMS notifications, label prints, audits             │
 │                                                                                        │
 │ 10. TenantFilter.finally → TenantContext.clear() (always)                              │
 │                                                                                        │
 └────────────────────────────────────────────┬───────────────────────────────────────────┘
                                              │
                                              ▼
         Response returned to browser; axios response interceptor inspects status
         on 401/403 → axios-retry runs updateToken(5) + replays up to 3× (1s, 2s, 3s)
         on max retries → $kc.logout()
```

---

## 3. The Five Frontend Plugins — Load Order

Plugin order in `nuxt.config.js` is a **correctness contract**, not a style choice. Wrong order = white screen or infinite redirect loop.

Both `wms2-web-ui` and `wms2-mobile-ui` declare:

```js
plugins: [
  '@/plugins/axios',                    // 1. interceptors wired before any request
  '@/plugins/initTenantAuth.client.js', // 2. resolve tenant, write to localStorage
  '@/plugins/keycloak.client',          // 3. init Keycloak using localStorage config
  '@/plugins/persistedState.client.js', // 4. rehydrate Vuex
  { src: '@/plugins/cookie.js', mode: 'client' },  // 5. inject $cookies
]
```

Swap 2 and 3 and Keycloak init runs with no config. Swap 1 and 4 and the first post-auth request goes out without headers. Don't reorder.

### 3.1 `initTenantAuth.client.js`

**Tenant discovery from subdomain:**

```
https://cawh-wineco.wms.siteboss.net/mobile
         └─┬─┘ └──┬──┘
        warehouse client
```

Parsed by regex in `plugins/initTenantAuth.client.js`:
- If `hostname === 'localhost' || '127.0.0.1'` → `{clientName: 'localhost', warehouse: 'develop'}`
- Else if `hostParts[1] === 'wms'` → split `hostParts[0]` by `-` → `{warehouse: parts[0], clientName: parts[1]}`

Then POSTs `${API_BASE_URL%/v3}/api/public/authConfig?key={warehouse}-{clientName}` — this is the **only public endpoint** (no tenant context required; see §5.5 of [wms2-tenant-routing-datasource-topology.md](./wms2-tenant-routing-datasource-topology.md)).

Response is stashed in `localStorage.tenantKeycloakConfig`; the Keycloak plugin reads it on the next tick.

### 3.2 `keycloak.client.js` (mobile UI — window-scoped state)

```js
const getGlobalState = () => {
  if (!window.__keycloakState) {
    window.__keycloakState = {
      keycloakInstance: null,
      tokenUpdateInterval: null,
      isInitializing: false,
      config: null
    }
  }
  return window.__keycloakState
}
```

Why `window`? Nuxt's module system can re-evaluate the plugin module when navigating between pages. A module-scope variable would be `null` on the new page, triggering a second `Keycloak.init(...)` and a double login redirect. `window` survives navigation.

Web UI has an analogous setup; confirm against `v2/wms2-web-ui/plugins/keycloak.client.js`.

**Redirect-loop breaker (SBDEV-2390).** Both UIs init with `onLoad: 'check-sso'` (not `login-required`), so `init()` resolves without a forced redirect and hands control back to app code. Every `keycloak.login()` is then routed through `guardedLogin()` in `plugins/kc-redirect-guard.js`, which counts attempts in per-tab `sessionStorage` and, after `MAX_KC_REDIRECTS` (2), redirects to `/unknown-tenant?reason=auth` (mobile: `/mobile/unknown-tenant?reason=auth`) instead of bouncing again — the hard termination guarantee against the refresh/redirect loop. `resetRedirectCount()` fires on successful auth. A bare `login-required` would redirect *inside* `init()` before the guard could run, which is why `check-sso` is load-bearing here, not cosmetic.

### 3.3 `axios.js` — headers and retry

Every outbound request receives:

```
Authorization: Bearer <kcToken>        // $kc.token → fallback localStorage.kcToken
X-Tenant-ID:   <localStorage.clientName>
facility_code: <store.selectedWarehouse or localStorage.selectedWarehouse>
```

On 401/403: `axios-retry` runs `$kc.updateToken(5)`, replays up to 3× (1s, 2s, 3s). If `updateToken` returns `false` (token still valid) but the 401 persists — real auth failure — abort and logout after 3 s toast.

---

## 4. Backend Receives — Filter, Security, Routing

### 4.1 `TenantFilter` — first in the chain

At `v2/wms2-api/src/main/java/net/aim_ai/wms/landlord/config/TenantFilter.java`:

- `@Order(Ordered.HIGHEST_PRECEDENCE)` — runs before Spring Security.
- Reads `X-Tenant-ID` + `facility_code`, lowercases both (any downstream comparison to non-lowercased values would fail — see §10 item 8 of [wms2-tenant-routing-datasource-topology.md](./wms2-tenant-routing-datasource-topology.md)).
- Builds a `TenantProfile(tenantName, facilityCode)`, calls `TenantContext.setCurrentTenant(profile)`, also pushes `{tenantPrefix}-{facilityCode}` into SLF4J MDC for log correlation.
- In a `finally` block, calls `TenantContext.clear()` so the scheduler threads never inherit a stale tenant.

Public endpoints (prefix `/api/public/`) are exempt: `TenantContext` is set to `null` and validation is skipped. The authConfig lookup endpoint is the only routine user of this path.

### 4.2 Spring Security — `MultiTenantJwtDecoder`

Resolves the tenant-specific Keycloak realm via `TenantAuthConfigCache` (populated by `TenantConfigLoader.scheduledRefresh`). Caches per-tenant `JwtDecoder` instances in a bounded Caffeine cache (`expireAfterWrite(24h)`, `maximumSize(200)` — GAP F fix, 260610 Phase B) via `jwtDecoders.get(tenantKey, ...)` to avoid rebuilding JWK sets per request; landlord auth-config changes propagate within the TTL.

### 4.2.1 `IdempotencyFilter` — REST write deduplication (SBDEV-2222)

Wired via `SecurityFilterChain.addFilterAfter(idempotencyFilter, BearerTokenAuthenticationFilter.class)` so it runs **after** the JWT is validated and `SecurityContextHolder` is populated.

- Applies only to non-GET `/rest/**` requests (skips `/rest/stockcount/**` and `/rest/transactionreport/**`).
- Rejects anonymous callers (defence-in-depth against filter-order regression).
- Skips dedup for oversized bodies (> `app.idempotency.max-body-bytes`, default 5 MB) — DoS guard.
- **Auto-derives idempotency key** from `SHA-256(method + "|" + path + "|" + rawBodyBytes)` when no `Idempotency-Key` header is present (260520). An explicit header overrides the auto-derived key (back-compat for OMS callers).
- On first request: inserts a claim row atomically (`ON CONFLICT DO NOTHING RETURNING`) → forwards to handler.
- On replay: returns cached 2xx response directly; evicts Caffeine `itemdata` cache for `/rest/sku/**` replays.
- On handler exception: passes `SC_INTERNAL_SERVER_ERROR` to `persistResponse`, which deletes the claim row so OMS may retry.
- Controlled by `app.idempotency.enforce=true` (`false` bypasses in dev). See [wms2-sysprop-catalog.md](../data-dictionary/wms2-sysprop-catalog.md) §4.6.

### 4.3 Service layer — transaction + routing

See [wms2-transaction-osiv-boundary-map.md](./wms2-transaction-osiv-boundary-map.md) §5 for the "pick the right manager" rules. Tenant-scoped business code must use `@Transactional("tenantTransactionManager")` or the `@TenantTransactional` meta-annotation; bare `@Transactional` goes to landlord due to `@Primary`.

Hibernate asks `TenantIdentifierResolver.resolveCurrentTenantIdentifier()` on each query. That resolver reads `TenantContext.getCurrentTenant()` — which the filter set in step 5. If it's null, the resolver returns the literal string `"BOOTSTRAP"`, which Hibernate can't route meaningfully; requests in that state fail with either a landlord-fallback or a "not found" error depending on the entity.

### 4.4 Per-tenant pool resolution

`TenantDynamicRoutingDataSource.determineTargetDataSource()`:

1. `TenantProfile profile = TenantContext.getCurrentTenant()` — from step 5.
2. `String key = TenantKeyBuilder.buildKey(profile)` → `first4(tenantName) + "-" + facilityCode`.
3. `tenantPools.computeIfAbsent(key, k -> createHikariPool(config))` — lazy create; first request for a tenant pays 200–1000 ms pool creation. Config source: `TenantDbConfigCache` (populated by `TenantConfigLoader`, refreshed every 5 min).
4. `lastAccess.put(key, now())` — input to `TenantPoolEvictor`.

---

## 5. Post-commit Side-effects

Any mutation that needs to fire an external call (OMS notification, label print, audit) registers via:

```java
TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
    @Override public void afterCommit() { /* fire */ }
});
```

These run **only if the commit succeeds**. Rollback silently drops them — which is usually what you want, but can mask issues (OMS never hears about a failed pick; check `message` / `message_archived` tables to verify delivery).

See [wms2-transaction-osiv-boundary-map.md](./wms2-transaction-osiv-boundary-map.md) §6 for the full list of post-commit sites.

---

## 6. Token Refresh Loop

The frontend keeps the bearer alive via a setInterval in `keycloak.client.js`:

```js
state.tokenUpdateInterval = setInterval(async () => {
  const kc = state.keycloakInstance
  if (!kc || !kc.authenticated) { clearInterval(...); return }
  const refreshed = await kc.updateToken(120)   // refresh if < 2 min left
  if (refreshed) {
    localStorage.setItem('kcToken', kc.token)
    localStorage.setItem('kcRefreshToken', kc.refreshToken)
  }
}, 60000)
```

- Every 60 seconds, check if the token has < 2 minutes remaining validity; if yes, refresh.
- On refresh failure (network down, refresh token expired), `onAuthRefreshError` handler fires `logout()`.
- `onTokenExpired` handler (also registered) triggers `updateToken(30)` — an emergency refresh with only 30 s left.

Retry-inside-axios (step 4 in the journey) is the second layer: when a request comes back 401/403 despite the background refresh loop, `axios-retry` re-tries with a fresh token.

---

## 7. Where Requests Break (symptom → section)

| Symptom | Start at |
|---|---|
| Login succeeds but first API call returns 401 | §3.3 axios interceptor — confirm `kcToken` in localStorage, confirm `X-Tenant-ID` + `facility_code` on the wire |
| Infinite redirect to Keycloak | §3.2 — module-scope vs `window` state; check `window.__keycloakState.isInitializing` |
| "Tenant not found" on backend | §3.1 subdomain parsing + §4.1 `TenantFilter` lowercasing; check `localStorage.tenantKeycloakConfig` payload |
| Data from the wrong tenant | §4.3 + [wms2-transaction-osiv-boundary-map.md](./wms2-transaction-osiv-boundary-map.md) §10 item 2 — bare `@Transactional` falling through to landlord |
| Token refresh stops after a while | §6 — inspect `onAuthRefreshError` logs; check if `tokenUpdateInterval` got cleared by an unhandled exception |
| New tenant added but not routable | §4.4 + 5-min `TenantConfigLoader` refresh cadence — hit `/v3/tenant/health` for the new tenant to force validation |
| Mobile UI loops re-initialising Keycloak | §3.2 `window.__keycloakState` — confirm it's not reset by an outer mount hook |
| OMS never receives a pick/cancel/ship notification | §5 post-commit drop on rollback; inspect `message` table |

---

## 8. Known Landmines

1. **Plugin order is a correctness contract.** Step-2 before step-3. Step-1 before step-4. Don't reorder.
2. **Mobile UI Keycloak state must live on `window`.** Module-level state resets on Nuxt navigation and re-triggers init.
3. **`initTenantAuth` makes a network call *before* Keycloak is up.** Goes to `/api/public/authConfig` — the one public endpoint. If that path is moved or protected, the whole app cannot bootstrap.
4. **Axios interceptor reads tenant info from TWO places** (`store.selectedWarehouse` → localStorage fallback). If the store rehydration order is off, a request can go out with stale `facility_code`. §3.3.
5. **Headers are lowercased on both sides.** `TenantFilter:40-48` lowercases. Don't compare against mixed-case values anywhere downstream.
6. **Public path bypass is prefix-based** (`/api/public/`). A new public endpoint that accidentally operates on tenant data falls through to landlord. Audit new routes.
7. **Post-commit hooks drop silently on rollback.** OMS / label / audit callbacks only fire after commit; a rolled-back TX leaves no trace outside `message` / `message_archived` tables.
8. **Token refresh interval lives on `window.__keycloakState.tokenUpdateInterval`.** An unhandled exception inside the interval callback can kill the loop without logging — tokens then expire silently until the next 401 triggers refresh via axios-retry.
9. **Logout redirect defaults to `window.location.origin + '/mobile'`.** Mobile UI's `/mobile/` base path means any logout redirect from a non-mobile origin lands on a broken URL.
10. **`BOOTSTRAP` fallback tenant identifier** — if `TenantContext` is null when Hibernate asks, the resolver returns `"BOOTSTRAP"`. This should never happen in a request path; if you see it in logs, step 5 `TenantFilter` didn't fire — a sign the request hit a path excluded from the filter chain.

---

## 9. Related Files (canonical paths)

| Component | Path |
|---|---|
| Mobile UI plugin chain | `v2/wms2-mobile-ui/plugins/{axios,initTenantAuth.client,keycloak.client,persistedState.client,cookie}.js` |
| Web UI plugin chain | `v2/wms2-web-ui/plugins/{axios,initTenantAuth.client,keycloak.client,persistedState.client,cookie}.js` |
| Mobile UI Keycloak window state | `v2/wms2-mobile-ui/plugins/keycloak.client.js:6-19` |
| Mobile UI axios interceptor | `v2/wms2-mobile-ui/plugins/axios.js:95-139` |
| Backend TenantFilter | `v2/wms2-api/src/main/java/net/aim_ai/wms/landlord/config/TenantFilter.java` |
| Backend TenantContext | `v2/wms2-api/src/main/java/net/aim_ai/wms/landlord/config/TenantContext.java:18` |
| Backend routing DS | `v2/wms2-api/src/main/java/net/aim_ai/wms/landlord/config/TenantDynamicRoutingDataSource.java` |
| Backend multi-tenant JWT decoder | `v2/wms2-api/src/main/java/net/aim_ai/wms/landlord/config/MultiTenantJwtDecoder.java` |

---

## 10. How to use this doc

| Task | Start at |
|---|---|
| Onboarding a new full-stack engineer | §2 walkthrough + §3 plugin order |
| Debugging an auth / tenant bug | §7 symptom table |
| Adding a new public endpoint (no tenant context) | §4.1 public-path bypass + §8 item 6 |
| Adding a new outbound OMS callback | §5 + §8 item 7 |
| Tracing "why is the wrong data showing" | §4.3 + §7 + [wms2-transaction-osiv-boundary-map.md](./wms2-transaction-osiv-boundary-map.md) §10 item 2 |

---

## 11. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | Frontend plugin chain (both UIs), backend `TenantFilter` → `MultiTenantJwtDecoder` → `TenantIdentifierResolver` → `TenantDynamicRoutingDataSource`, axios interceptor header contract, token refresh loop on `window.__keycloakState`, post-commit hook pattern | All file:line refs confirmed against source; cross-linked to tenant-routing + transaction architecture docs | Code read + accumulated evidence from prior doc sweeps |
| 2026-06-14 | §4.2 `MultiTenantJwtDecoder` per-tenant decoder cache — confirmed body matches the merged 260610 hardening Phase B (`expireAfterWrite(24h)`, `maximumSize(200)`, GAP F fix, PR #41). Spot-check of §4.2 only, not a full doc re-sweep | Matches code; `last_verified` bumped | Doc-drift audit (verify-docs) |
| 2026-07-03 | §3.1 diagram + §3.2 — updated for SBDEV-2390: both UIs now init with `onLoad: 'check-sso'` (was `login-required`) and gate `login()` through the `kc-redirect-guard.js` sessionStorage loop-breaker (`MAX_KC_REDIRECTS=2` → `/unknown-tenant?reason=auth`). Confirmed against branches `tasks/SBDEV-2390-pickpack-keycloak-refresh-loop` (wms2-web-ui PR #6, wms2-mobile-ui PR #6) | Diagram was stale (`login-required`); corrected + loop-breaker documented | Doc update (verify-docs follow-up) |

**Re-verify every 60 days.** Next due: **2026-09-01** — this doc spans 3 projects; any plugin change or backend filter change invalidates sections here.
