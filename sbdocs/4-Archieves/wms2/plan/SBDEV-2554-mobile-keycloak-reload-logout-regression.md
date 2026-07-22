---
title: "SBDEV-2554 — Page reload logs users out to the Keycloak logout page (mobile UI)"
ticket: "SBDEV-2554"
ticket_url: "https://app.clickup.com/t/SBDEV-2554"
type: "bugfix"
priority: "High"
status: "archived"
project: ["wms2-mobile-ui"]
version: "v2"
requester: "Nam Park"
created: "2026-07-13"
updated: "2026-07-15"
db_verified: false
related:
  - "SBDEV-2554-web-keycloak-reload-logout-regression.md"
  - "SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.md"
  - "SBDEV-2391 (mobile tenant-not-recognized-refresh)"
tags:
  - plan
  - wms2-mobile-ui
  - keycloak
  - auth
  - reload
  - regression
---

# SBDEV-2554 — Page reload logs users out to the Keycloak logout page (mobile UI)

**Ticket:** [SBDEV-2554](https://app.clickup.com/t/SBDEV-2554)
**Project:** wms2-mobile-ui | **Version:** v2 | **Type:** bugfix (regression)
**Priority:** High
**Status:** ready-for-review (critic review 2026-07-13: **SHIP-WITH-CHANGES** → 3 must-fix items applied — async `retryCondition`, `login()` init-hang safety net, `isInitializing` reuse path leaves `ready` pending, advisory verify negatives; pending human review)
**Date:** 2026-07-13

**Paired plan:** `SBDEV-2554-web-keycloak-reload-logout-regression.md` (wms2-web-ui — identical regression, this is the mobile mirror)
**Regression of:** `SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.md` (the `login-required` → `check-sso` change)

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep across `v2/wms2-mobile-ui` (`.login(`, `.logout(`, `onLoad`, `authenticated`, `kcToken`, `location.replace/href`, `isInitializing`, `__keycloakState`) — not from memory.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `plugins/axios.js:25-28` | `retryCondition`: `if (!app.$kc \|\| !app.$kc.authenticated) { app.$kc?.logout(); reject() }` | **yes — PRIMARY trigger** | **yes** |
| 2 | `plugins/axios.js:95-131` | `onRequest`: falls back to **stale** `localStorage.kcToken` when `!app.$kc.authenticated` (init window) | **yes — sends the doomed request** | **yes** |
| 3 | `plugins/keycloak.client.js` (`initKeycloak`, `createEnhancedKeycloak`, `window.__keycloakState`) | `initKeycloak()` fire-and-forget; no awaitable init-complete signal | **yes — the missing barrier** | **yes** |
| 4 | `plugins/axios.js:66-92` | `onMaxRetryTimesExceeded` → `app.$kc.logout()` after 3 retries | contributory (retries pile up only because of #1/#2) | yes — add authenticated-guard |
| 5 | `plugins/axios.js:54-60` | refresh-catch `updateToken().catch(() => { ...; app.$kc.logout() })` | **no** — genuine refresh failure of an authenticated session | no — correct, leave as-is |
| 6 | `plugins/keycloak.client.js:191` | `guardedLogin(keycloakInstance)` (SBDEV-2390 loop-breaker) | no | **no — preserve untouched** |
| 7 | `plugins/keycloak.client.js:168` | `onLoad: 'check-sso'` + `silentCheckSsoRedirectUri: …/mobile/silent-check-sso.html` | no — required by SBDEV-2390 | **no — must NOT revert** |
| 8 | `plugins/keycloak.client.js:111-121` | reuse early-returns: "already initialized and authenticated" / "already initializing" | related — the `ready` promise must interoperate with these | **yes — ready must resolve on the reuse path too** |
| 9 | `plugins/keycloak.client.js:~330-360` | `setupTokenRefresh`/`onTokenExpired`/`onAuthRefreshError`/`logout()` | no — post-auth session expiry | no — leave as-is |
| 10 | `plugins/initTenantAuth.client.js:73` | `window.location.replace(classifyRedirect(...))` (SBDEV-2391) | no | **no — preserve untouched** |

Every **yes** row maps to a check in `verify-SBDEV-2554-mobile-keycloak-reload-logout-regression.sh` (§11).

---

## 1. Problem Statement

> **`db_verified: false`** — Pure frontend auth/timing defect (Nuxt 2 / Vue 2 client plugins). No DB state; DB-verification gate **N/A**. `wms2-api` unchanged — 401 on expired bearer is correct resource-server behavior.

**User-visible symptom:** After the SBDEV-2390 deploy, **reloading any authenticated screen on the handheld intermittently logs the operator out to the Keycloak logout page** instead of re-rendering in place. Warehouse handhelds on spotty wifi hit this more often (stale token + slow silent check).

**Reproduction:** identical to the web plan — log in, idle past the access-token lifespan (or reload rapidly), press reload → app briefly renders then redirects to Keycloak `/protocol/openid-connect/logout`. Expected: silent SSO re-check, fresh token, stay logged in.

**Acceptance criteria:**
- Reloading an authenticated mobile screen keeps the operator logged in when the SSO session is valid.
- SBDEV-2390 loop stays fixed (`check-sso` + `kc-redirect-guard` intact).
- Genuinely expired SSO still yields a clean re-login (no hang/loop).

---

## 2. Root Cause Analysis

Identical mechanism to the web UI (`plugins/axios.js` is byte-for-byte the same defective logic), with mobile-specific state handling in `keycloak.client.js`.

### Bug 1 (PRIMARY) — axios `retryCondition` logs out during init
`plugins/axios.js:25-28`:
```js
if (!app.$kc || !app.$kc.authenticated) {
  app.$kc?.logout();                       // ← THE TRIGGER → /mobile logout redirect
  return reject(new Error('Not authenticated for token refresh.'));
}
```
`app.$kc.logout()` → `keycloakInstance.logout({ redirectUri })` (or the mobile fallback `window.location.replace(redirectUri)`), i.e. the Keycloak logout page. It treats "still initializing" as "session invalid."

### Bug 2 (ENABLER) — `onRequest` sends the stale localStorage token
`plugins/axios.js:100-106`: when `!app.$kc.authenticated` (the async `check-sso` window), it attaches the previous session's expired `localStorage.kcToken` → `wms2-api` 401 → Bug 1 fires.

### Bug 3 (MISSING BARRIER) — `initKeycloak()` fire-and-forget over `window.__keycloakState`
`plugins/keycloak.client.js` uses a window-scoped state bag (`window.__keycloakState = { keycloakInstance, tokenUpdateInterval, isInitializing, config }`) to survive Nuxt page navigations, and injects `$kc` via `createEnhancedKeycloak(config)` **before** `await keycloakInstance.init({ onLoad: 'check-sso', … })` resolves. There is **no `ready` signal** on the state bag or the façade for axios to await. The old `onLoad: 'login-required'` blocked behind a full-page redirect so authenticated requests never fired before a fresh token existed; `check-sso` removed that implicit barrier (SBDEV-2390). Mobile additionally has early-return reuse paths (`isInitializing`, "already authenticated") that must also leave `ready` resolved.

**Intermittent** for the same reason as web: only fires when the stored token is expired/invalid at reload time.

---

## 3. The Regression Chain

| # | Commit | Date | Effect |
|---|--------|------|--------|
| 1 | `f34f2ce` fix(auth): break Keycloak refresh/redirect loop on mobile (SBDEV-2390) | 2026-07-03 | `login-required` → `check-sso` + `/mobile/` silent SSO + `kc-redirect-guard`. Correct loop fix; removed the implicit barrier. |
| 2 | `3a4df8a` fix(auth): harden mobile tenant discovery (SBDEV-2391) | 2026-07-04 | Tenant-discovery retry/recovery; unrelated to this logout path (left intact). |
| — | (this plan) SBDEV-2554 | 2026-07-13 | Re-introduce an explicit `ready` barrier on `window.__keycloakState`. |

---

## 4. Architecture Overview

```
Reload of an authenticated mobile screen (base = /mobile/)
   ├─ plugins/axios.js         retry + onRequest interceptors (identical to web)
   ├─ plugins/initTenantAuth   tenant config → localStorage (SBDEV-2391, untouched)
   ├─ plugins/keycloak.client  window.__keycloakState; inject $kc (instance=null);
   │                           fire initKeycloak() ──┐ async check-sso (silent iframe)
   │   screen mounts, API call ─► onRequest: authenticated==false                 │
   │        └─ STALE localStorage kcToken ─► 401 ─► retryCondition ─► logout() ───┘ ─► KC LOGOUT
After fix:
   onRequest ─► await $kc.ready (bounded) ─► live fresh token ─► 200
   retryCondition ─► await $kc.ready ─► if authenticated: updateToken+retry; else reject (no logout)
```

**Key files**

| File | Lines | Role |
|------|-------|------|
| `plugins/axios.js` | 12-93 | axios-retry logout sites |
| `plugins/axios.js` | 95-131 | `onRequest` token attachment (note: sets both `headers.common` and `headers`) |
| `plugins/keycloak.client.js` | 6-24 | `getGlobalState()` → `window.__keycloakState` |
| `plugins/keycloak.client.js` | 27-93 | `createEnhancedKeycloak()` façade |
| `plugins/keycloak.client.js` | 111-121 | reuse early-returns (`authenticated`, `isInitializing`) |
| `plugins/keycloak.client.js` | ~148-244 | `initKeycloak()` bootstrap |
| `plugins/kc-redirect-guard.js` | all | SBDEV-2390 loop-breaker (preserve) |

---

## 5. Fix Design

Mirror of the web fix, adapted to the window-scoped state bag.

### Fix A — Add a `ready` promise to `window.__keycloakState` and expose it on the façade

**In `getGlobalState()`** initialize the promise once (survives plugin re-eval):
```js
if (!window.__keycloakState) {
  const state = { keycloakInstance: null, tokenUpdateInterval: null, isInitializing: false, config: null }
  state.ready = new Promise((resolve) => { state._resolveReady = resolve })
  window.__keycloakState = state
}
```
Add a `settleReady(state)` helper:
```js
const settleReady = (state) => { if (state._resolveReady) { state._resolveReady(); state._resolveReady = null } }
```

**Call `settleReady(state)` on these paths only:**
- `initKeycloak()` success (after tokens stored),
- immediately before `guardedLogin(...)` (not authenticated),
- in the `catch` block before the `/mobile/unknown-tenant?reason=auth` redirect,
- the no-config redirect branch (`!config`),
- the **already-authenticated** reuse early-return (`state.keycloakInstance && authenticated`) — defensive; `state.ready` should already be resolved there.

> **Do NOT call `settleReady` on the `isInitializing` reuse early-return** (`keycloak.client.js:119-123`) — critic finding. There, an init started by a prior plugin run is still in flight and `state.ready` is (correctly) still pending; the in-flight init is the **sole settler**. Forcing resolution there would let `awaitAuthReady` return before init completes → `onRequest` proceeds with `authenticated===false` → stale token → 401 (Fix C would prevent the *logout*, but the request would still fail). Leave `state.ready` pending and do nothing.

**Expose on the façade** (`createEnhancedKeycloak`):
```js
return {
  get instance() { return state.keycloakInstance },
  get authenticated() { return state.keycloakInstance?.authenticated || false },
  get ready() { return state.ready },        // ← NEW
  ...
}
```

### Fix B — `onRequest`: await `ready` (bounded) before attaching the token
Same as web. Add `awaitAuthReady(app)` (Promise.race with `READY_TIMEOUT_MS = 5000`, returns `Promise.resolve()` when no façade, never rejects), make `onRequest` async, await it, then prefer `app.$kc.token` over stale `localStorage.kcToken`. Preserve the mobile behavior of setting **both** `config.headers.common['Authorization']` and `config.headers['Authorization']`. (Mobile is `ssr: false`, client-only — no SSR request path to guard.)

### Fix C — `retryCondition`: await ready; remove the `!authenticated → logout()` reflex
Same as web (`plugins/axios.js` is identical). **Implementation constraint (critic):** you cannot `await` inside the current synchronous `new Promise((resolve, reject) => …)` executor, and an async executor swallows rejections — so `retryCondition` **becomes `async`** and drops the manual Promise wrapper (axios-retry 4.5.0 awaits it; `true`=retry, `false`=give up):
```js
async retryCondition(error) {
  if (!error.response || (error.response.status !== 401 && error.response.status !== 403)) {
    return false
  }
  await awaitAuthReady(app)                 // let a mid-init check-sso finish (bounded)
  if (!app.$kc || !app.$kc.authenticated) {
    // Do NOT logout here (that reflex sent reloads to the KC LOGOUT page, SBDEV-2554).
    // Drive LOGIN as the init-hang safety net; on a hard reload guardedLogin already ran.
    console.warn('[SBDEV-2554] Not authenticated after init; deferring to Keycloak login (no axios logout).')
    app.$kc?.login?.()
    return false
  }
  try {
    const refreshed = await app.$kc.updateToken(5)
    if (!refreshed) return false
    error.config.headers.Authorization = `Bearer ${app.$kc.token}`
    localStorage.setItem('kcToken', app.$kc.token)
    return true
  } catch (refreshError) {
    // Genuine refresh failure on an AUTHENTICATED session → keep logout.
    app.$toast.error('Session expired or invalid. Logging out...')
    app.$kc.logout()
    return false
  }
}
```
The `!authenticated` branch calls **`login()`, never `logout()`**; the genuine-refresh-failure `logout()` (previously `axios.js:54-60`) is preserved in the `catch`.

### Fix D — `onMaxRetryTimesExceeded`: guard the terminal logout on `authenticated`
Same as web — only call `app.$kc.logout()` when `app.$kc.authenticated`, else defer to the KC plugin.

### Not changed (preserve)
- `onLoad: 'check-sso'` + `/mobile/silent-check-sso.html`, `kc-redirect-guard.js` / `guardedLogin` (SBDEV-2390).
- `initTenantAuth.client.js` tenant discovery + `/mobile/`-prefixed redirects (SBDEV-2391).
- `setupTokenRefresh` / `onTokenExpired` / `onAuthRefreshError` / `logout()` post-auth paths.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `plugins/keycloak.client.js` | modify | Add `state.ready` on `window.__keycloakState` + `settleReady(state)` on all terminal/reuse paths; expose `get ready()` on `createEnhancedKeycloak`. |
| `plugins/axios.js` | modify | Add `awaitAuthReady(app)`; `onRequest` async awaits it (keeps dual-header set); `retryCondition` awaits ready and **removes** `!authenticated → logout()`; guard `onMaxRetryTimesExceeded` logout on `authenticated`. |
| `test/plugins/keycloak-ready.spec.js` | add | `$kc.ready` resolves after init and on the reuse path. |
| `test/plugins/axios-auth-timing.spec.js` | add | 401 during init window does NOT logout; onRequest awaits ready then uses live token; genuine refresh failure still logs out. |

---

## 7. Prerequisites & Implementation Plan

### 7.1 Prerequisites

| # | Category | Applies? | Notes |
|---|----------|----------|-------|
| 1 | Database state | **N/A** | Frontend-only; `db_verified: false`. |
| 2 | Feature flags / sysprops | **N/A** | None. |
| 3 | Config / env | **N/A** | `READY_TIMEOUT_MS` is a code constant. |
| 4 | Deploy order | Yes | Ship with the web plan so both UIs are consistent. |
| 5 | Backend | **N/A** | Unchanged. |
| 6 | Test harness | Note | Mobile Jest harness was added in SBDEV-2391 (`jest.config.js`, `.babelrc`, `test/` scoped). New specs go under `test/plugins/`. |

### 7.2 Implementation Checklist
- [ ] Fix A — `state.ready` + `settleReady` on all terminal & reuse paths + `get ready()`.
- [ ] Fix B — `awaitAuthReady`; async `onRequest`; live token; dual-header preserved.
- [ ] Fix C — `retryCondition` awaits ready; remove logout reflex.
- [ ] Fix D — guard `onMaxRetryTimesExceeded` logout on `authenticated`.
- [ ] Add both specs; mobile Jest green.
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2554-mobile-keycloak-reload-logout-regression.sh` → `0 fail`.
- [ ] Manual smoke on a handheld / mobile viewport (see §8).
- [ ] Update §10 with SHA + results.

---

## 8. Test Plan

### Unit (Jest — mobile harness from SBDEV-2391)
- `axios-auth-timing.spec.js`:
  - 401 while `$kc.authenticated === false` and `$kc.ready` pending → **no** `logout()`; retry rejected.
  - After `ready` resolves authenticated → `updateToken` + retry with refreshed token.
  - Genuine `updateToken()` rejection on authenticated session → still `logout()`.
  - `onRequest` awaits `ready`, sets both `headers.common.Authorization` and `headers.Authorization` from the live token.
  - **Concurrency:** N simultaneous requests all awaiting the single `state.ready` all proceed once it resolves; `logout` never called.
  - After the `awaitAuthReady` timeout with `authenticated===false`, the `!authenticated` branch calls `login()` (not `logout()`).
- `keycloak-ready.spec.js`: `state.ready` resolves after init; resolves on the "already authenticated" reuse early-return (mock `window.__keycloakState` pre-populated); and on the `isInitializing` reuse path the shared promise **stays pending** until the in-flight init settles it (asserts critic Major #2 — no premature settle).

### Integration
- N/A automated. Covered by manual plan.

### Regression
- `verify-…sh` NEGATIVE checks: `!authenticated → logout()` reflex gone; `onLoad: 'check-sso'` present; `/mobile/silent-check-sso.html` present.
- Existing SBDEV-2390/2391 specs (`initTenantAuth.spec.js`, `tenant-auth-fetch.spec.js`) remain green.

### Manual test plan

| # | Scenario | Environment | Steps | Expected |
|---|----------|-------------|-------|----------|
| 1 | Idle-then-reload | dev2 mobile `/mobile/`, real tenant | Log in, idle > token lifespan, reload | Screen re-renders logged in; no KC logout page |
| 2 | Spotty-wifi reload | throttled network | Log in, throttle to 3G, reload | Stays logged in (bounded ready wait); no logout |
| 3 | Loop still broken | dev2 mobile | Reproduce SBDEV-2390 preconditions | ≤2 redirects → `/mobile/unknown-tenant?reason=auth`, no loop |
| 4 | Genuine expired SSO | dev2 mobile | Invalidate SSO server-side, reload | Clean re-login |
| 5 | Deep-screen reload | dev2 mobile | Reload on a picking/putaway screen | Loads with data; fresh token on API calls |

### Test execution (fill in after running)

| Command | Result | Notes |
|---------|--------|-------|
| `node_modules/.bin/jest --testPathPattern='axios-auth-timing\|keycloak-ready'` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2554-mobile-keycloak-reload-logout-regression.sh` | | |

### Deliberately-skipped coverage
- Real-device silent-check timing e2e — not automatable here; manual scenarios 1-5.

---

## 9. Horizontal Scalability Validation & v2 constraints

### 9.0 Applicability note
Client-side Nuxt/Vue change; no backend, DB, cache, cron, or server tenant-context. v2-API scalability + Jakarta/OSIV/transaction checklists **N/A**. The only new state is a per-tab promise on `window.__keycloakState`, local to one browser tab; `kc-redirect-guard` keeps its per-tab `sessionStorage` counter (unchanged).

| Concern | Verdict |
|---|---|
| Server-side (JVM state / pool / cron / tx / tenant / cache / notifications) | **N/A** — no backend change |
| Client per-tab state (`window.__keycloakState.ready`) | Yes — single tab; resolved on all terminal + reuse paths; bounded await prevents hangs |

---

## 10. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `ready` never settles → requests hang | High | `settleReady` on all init terminals + the already-authenticated reuse return; `isInitializing` path leaves the shared promise for the in-flight init to settle; `awaitAuthReady` timeout as backstop |
| **Init-hang edge**: `init()` never resolves/throws so `settleReady` + `guardedLogin` never fire | Medium | `awaitAuthReady` unblocks via timeout; Fix C `!authenticated` branch calls **`app.$kc.login()`** (login page, never the logout page) as the safety net — user re-logs-in, not stranded |
| Stale promise on `window.__keycloakState` across a logout/re-init | Medium | Logout resets the bag (`state.keycloakInstance = null` etc.); `getGlobalState()` re-creates `state.ready` (fresh pending promise) whenever it rebuilds the bag — verify the reset path nulls/recreates `ready`, not leaves a resolved one |
| Reintroducing SBDEV-2390 loop | High | `check-sso` + `kc-redirect-guard` untouched; verify NEGATIVE check |
| Async `onRequest` ordering | Low | resolves immediately in steady state; only first post-reload requests wait |

---

## 11. Acceptance & Implementation

### 11.1 Acceptance script
`sbdocs/9-System/scripts/verify-SBDEV-2554-mobile-keycloak-reload-logout-regression.sh` (run with `PROJECT_ROOT=…/v2/wms2-mobile-ui`). POSITIVE: `get ready()` on façade; `state.ready`/`settleReady` present; `awaitAuthReady` awaited; Fix C `login()`/defer marker present; `onLoad: 'check-sso'` + `/mobile/silent-check-sso.html` + `guardedLogin` retained. NEGATIVE: `onLoad: 'login-required'` absent.

> **Gate authority (critic):** code-shape greps are **advisory** (a reformat can defeat a comment-string negative check). The **authoritative gate is the Jest spec** `axios-auth-timing.spec.js` asserting `app.$kc.logout` is **not** called on a 401 while `authenticated===false`/`ready` pending. Both must pass.

### 11.2 Recommended OMC composition

| Step | Agent | Why |
|------|-------|-----|
| Implementation | executor | 2 plugins + 2 specs; verify-script gate |
| Verification | verifier + verify-script | Mandatory |

---

## 12. Implementation Status

**Implemented 2026-07-13; archived 2026-07-15 — merged to `develop` and released.** wms2-mobile-ui [PR #17](https://github.com/SiteBossInc/wms2-mobile-ui/pull/17) → `develop` (commit `b96de16`, verified on `origin/develop`); subsequently released (PR #18 → release, PR #19 → main, v0.0.8 / OWL v2.0.115). (Supersedes the earlier "Not yet committed" note.)

- **Files:** `plugins/keycloak.client.js` (Fix A — `state.ready`/`settleReady`/`resetReady` on `window.__keycloakState`; settle on paths a–e; **`isInitializing` reuse path left pending** per critic Major #2; `get ready()`), `plugins/axios.js` (Fix B/C/D — identical to web; max-retry else-defers to `login()`). New specs: `test/plugins/keycloak-ready.spec.js`, `test/plugins/axios-auth-timing.spec.js`.
- **Tests:** new specs `Tests: 7 passed, 7 total`; full suite `Tests: 23 passed, 23 total` (SBDEV-2390/2391 specs green; jest scoped to `test/`, no Playwright e2e pulled in). `npm install` was run to provision the declared-but-uninstalled `jest` (node_modules only, gitignored).
- **Verify:** `Result: 14 pass, 0 fail, 0 skip` (independently re-run).
