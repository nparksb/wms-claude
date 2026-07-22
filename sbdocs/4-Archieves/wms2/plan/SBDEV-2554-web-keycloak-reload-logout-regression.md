---
title: "SBDEV-2554 — Page reload logs users out to the Keycloak logout page (web UI)"
ticket: "SBDEV-2554"
ticket_url: "https://app.clickup.com/t/SBDEV-2554"
type: "bugfix"
priority: "High"
status: "archived"
project: ["wms2-web-ui"]
version: "v2"
requester: "Nam Park"
created: "2026-07-13"
updated: "2026-07-15"
db_verified: false
related:
  - "SBDEV-2554-mobile-keycloak-reload-logout-regression.md"
  - "SBDEV-2390-web-pickpack-keycloak-refresh-loop.md"
  - "SBDEV-2391 (tenant-not-recognized-refresh)"
tags:
  - plan
  - wms2-web-ui
  - keycloak
  - auth
  - reload
  - regression
---

# SBDEV-2554 — Page reload logs users out to the Keycloak logout page (web UI)

**Ticket:** [SBDEV-2554](https://app.clickup.com/t/SBDEV-2554)
**Project:** wms2-web-ui | **Version:** v2 | **Type:** bugfix (regression)
**Priority:** High
**Status:** ready-for-review (critic review 2026-07-13: **SHIP-WITH-CHANGES** → 3 must-fix items applied — async `retryCondition`, `login()` init-hang safety net, advisory verify negatives; pending human review)
**Date:** 2026-07-13

**Paired plan:** `SBDEV-2554-mobile-keycloak-reload-logout-regression.md` (wms2-mobile-ui — identical regression, mirror fix)
**Regression of:** `SBDEV-2390-web-pickpack-keycloak-refresh-loop.md` (the `login-required` → `check-sso` change)

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep across `v2/wms2-web-ui` (`.login(`, `.logout(`, `onLoad`, `authenticated`, `kcToken`, `location.replace/href`, `ready`) — not from memory.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `plugins/axios.js:25-28` | `retryCondition`: `if (!app.$kc \|\| !app.$kc.authenticated) { app.$kc?.logout(); reject() }` | **yes — PRIMARY trigger** | **yes** |
| 2 | `plugins/axios.js:95-137` | `onRequest`: falls back to **stale** `localStorage.kcToken` when `!app.$kc.authenticated` (init window) | **yes — sends the doomed request** | **yes** |
| 3 | `plugins/keycloak.client.js` (`initKeycloak`, injected `enhancedKeycloak`) | `initKeycloak()` is fire-and-forget; no way for callers to await init completion | **yes — the missing barrier** | **yes** |
| 4 | `plugins/axios.js:66-92` | `onMaxRetryTimesExceeded` → `app.$kc.logout()` after 3 retries | contributory (retries only pile up because of #1/#2) | yes — becomes unreachable on reload once #2 fixed; add authenticated-guard for safety |
| 5 | `plugins/axios.js:54-60` | refresh-catch `updateToken().catch(() => { ...; app.$kc.logout() })` | **no** — genuine refresh failure of an *already-authenticated* session | no — correct behavior, leave as-is |
| 6 | `plugins/keycloak.client.js:81,118` | `guardedLogin(keycloakInstance)` (SBDEV-2390 loop-breaker) | no — this is the loop fix | **no — preserve untouched** |
| 7 | `plugins/keycloak.client.js:71` | `onLoad: 'check-sso'` | no — required by SBDEV-2390 | **no — must NOT revert to `login-required`** |
| 8 | `plugins/keycloak.client.js:~142,159,169` | `setupTokenRefresh` / `onTokenExpired` / `onAuthRefreshError` → `logout()` | no — fire only *after* auth is established (real session expiry) | no — leave as-is |
| 9 | `plugins/initTenantAuth.client.js:69` | `window.location.replace(classifyRedirect(...))` (SBDEV-2391 tenant discovery) | no — tenant-not-found path, not the reload-logout | **no — preserve untouched** |

Every **yes** row maps to a POSITIVE (and where it replaces code, NEGATIVE) check in `verify-SBDEV-2554-web-keycloak-reload-logout-regression.sh` (§11).

---

## 1. Problem Statement

> **`db_verified: false`** — This is a pure frontend auth/timing defect (Nuxt 2 / Vue 2 client plugins). No database state is involved and **no DB check is required** before implementation; the DB-verification gate is **N/A**. `wms2-api` is not modified — returning **401** for an expired/invalid bearer token is correct Spring Security OAuth2 resource-server behavior. (Optional, non-blocking backend sanity: a request with a deliberately-expired token to any `/api/**` endpoint should return 401, not 500 — but the fix does not depend on this.)

**User-visible symptom:** After the SBDEV-2390 deploy (which stopped the PickPack page from continuously reloading), **reloading any authenticated page now intermittently kicks the user out of the app and lands them on the Keycloak logout page.** Before SBDEV-2390 a reload simply re-rendered the current page.

**Reproduction:**
1. Log into WMS v2 web UI, navigate to any authenticated page (e.g. Picking, Outbound, Dashboard).
2. Leave the tab idle long enough for the access token to expire (default KC access-token lifespan, typically ~5 min), OR reload repeatedly.
3. Press browser **Reload** (F5 / Cmd-R).
4. **Observed:** the app briefly renders, then redirects to the Keycloak `/protocol/openid-connect/logout` page — the user is logged out.
5. **Expected:** the page reloads in place, silently re-checks the SSO session, obtains a fresh token, and stays logged in.

**Acceptance criteria:**
- Reloading an authenticated page keeps the user logged in (no redirect to the KC logout page) whenever the SSO session is still valid.
- The SBDEV-2390 reload/redirect **loop stays fixed** — `onLoad: 'check-sso'` and the `kc-redirect-guard` loop-breaker remain in force; the fix must not reintroduce the loop.
- A genuinely expired/invalidated SSO session still results in a clean re-login (not a hang, not a loop).

---

## 2. Root Cause Analysis

The SBDEV-2390 fix correctly changed Keycloak init from `onLoad: 'login-required'` to `onLoad: 'check-sso'` to break the reload loop. But that change removed an *implicit synchronization barrier* that the old mode provided, and the axios interceptor's logout-on-`!authenticated` reflex turns the resulting race into a full logout.

### Bug 1 (PRIMARY) — axios `retryCondition` calls `logout()` while Keycloak is still initializing

`plugins/axios.js:21-29`:

```js
retryCondition(error) {
  if (error.response && (error.response.status === 401 || error.response.status === 403)) {
    return new Promise((resolve, reject) => {
      if (!app.$kc || !app.$kc.authenticated) {
        console.warn('Keycloak not authenticated, cannot refresh token for retry.');
        app.$kc?.logout();                       // ← THE TRIGGER
        return reject(new Error('Not authenticated for token refresh.'));
      }
      ...
```

`app.$kc.logout()` calls `keycloakInstance.logout({ redirectUri })` → a full-page redirect to Keycloak's `/protocol/openid-connect/logout` endpoint (the "logout page" the user sees). The guard treats **"`$kc` has not finished initializing yet"** as **"the session is invalid"** and logs the user out. They are two very different states.

### Bug 2 (ENABLER) — `onRequest` sends a stale localStorage token during the init window

`plugins/axios.js:95-109`:

```js
$axios.onRequest((config) => {
  let kcToken = localStorage.getItem('kcToken');
  if (app.$kc && app.$kc.authenticated && app.$kc.token) {
    kcToken = app.$kc.token;          // live token — only once init resolved
  } else {
    kcToken = localStorage.getItem('kcToken');   // ← stale token from previous session
  }
  if (kcToken) {
    config.headers.common['Authorization'] = `Bearer ${kcToken}`;
    ...
```

On reload the previous session's `kcToken` is still in `localStorage` (it's only removed on logout). After idle it is **expired**. During the async `check-sso` window `$kc.authenticated` is `false`, so `onRequest` attaches this expired token → `wms2-api` correctly returns **401** → Bug 1 fires.

### Bug 3 (MISSING BARRIER) — `initKeycloak()` is fire-and-forget; nothing can await it

`plugins/keycloak.client.js` (end of plugin):

```js
if (process.client) {
  initKeycloak()          // async, NOT awaited, NOT returned to Nuxt
}
```

`enhancedKeycloak` is injected as `$kc` immediately, but its backing `keycloakInstance` is `null` until the async `await keycloakInstance.init({ onLoad: 'check-sso', ... })` resolves. There is **no `ready` promise** a consumer (axios) can await. With the old `onLoad: 'login-required'`, `init()` blocked the whole flow behind a full-page redirect and the app never issued authenticated requests until a **fresh** token existed — so Bugs 1+2 could not manifest. `check-sso` returns control immediately (silent iframe, `checkLoginIframe: false`), exposing the window.

**Why it is intermittent:** it only fires when the stored `kcToken` is expired/invalid at reload time (idle ≥ access-token lifespan, or rapid reloads racing the silent check). A reload with a still-valid stored token succeeds and hides the bug.

---

## 3. The Regression Chain

| # | Commit | Date | Effect |
|---|--------|------|--------|
| 1 | `e12cbaf` fix(auth): break Keycloak refresh/redirect loop (SBDEV-2390) | 2026-07-03 | `onLoad: 'login-required'` → `'check-sso'` + `kc-redirect-guard`. **Correct** loop fix; removed the implicit "no requests until fresh token" barrier. |
| 2 | `1ecaf08` fix(auth): stop false "Tenant not recognized" (SBDEV-2391) | 2026-07-04 | Hardened tenant discovery; unrelated to this logout path (left intact). |
| — | (this plan) SBDEV-2554 | 2026-07-13 | Re-introduce an explicit `ready` barrier so authenticated requests wait for init instead of firing a stale-token request that triggers logout. |

`plugins/axios.js` itself was **not** changed by SBDEV-2390 — its logout-on-`!authenticated` reflex predates the loop fix but was previously unreachable because `login-required` guaranteed a fresh token before any request. SBDEV-2390 made it reachable.

---

## 4. Architecture Overview

```
Reload of an authenticated page
   │
   ├─ plugins/axios.js         registers axios-retry + onRequest/onError interceptors
   ├─ plugins/initTenantAuth   discovers tenant config → localStorage (SBDEV-2391, untouched)
   ├─ plugins/keycloak.client  injects $kc (instance=null), fires initKeycloak() ──┐ async
   │                                                                                │ check-sso
   │   page mounts, fires API call ──► onRequest: $kc.authenticated == false        │ (silent
   │        └─ attaches STALE localStorage kcToken ──► GET /api/... ──► 401         │  iframe)
   │              └─ retryCondition: !authenticated ──► $kc.logout() ──► KC LOGOUT  │
   │                                                                                │
   └───────────────────────────────────────── init resolves (too late) ◄───────────┘

After fix:
   onRequest ──► await $kc.ready (bounded) ──► authenticated==true, live fresh token ──► 200
   retryCondition ──► await $kc.ready ──► if authenticated: updateToken+retry;
                                          else: reject WITHOUT logout (KC plugin owns login)
```

**Key files**

| File | Lines | Role |
|------|-------|------|
| `plugins/axios.js` | 12-93 | axios-retry `retryCondition` / `onMaxRetryTimesExceeded` — logout sites |
| `plugins/axios.js` | 95-137 | `onRequest` — token attachment |
| `plugins/keycloak.client.js` | ~59-130 | `initKeycloak()` async bootstrap |
| `plugins/keycloak.client.js` | ~190-248 | `enhancedKeycloak` façade injected as `$kc` |
| `plugins/kc-redirect-guard.js` | all | SBDEV-2390 loop-breaker (preserve) |

---

## 5. Fix Design

Guiding principle: **re-introduce the synchronization barrier that `login-required` used to provide, without reverting `check-sso`.** Authenticated requests wait for init to finish; the interceptor stops equating "still initializing" with "session invalid."

### Fix A — Expose a bounded `ready` promise from `keycloak.client.js`

Add a module-scoped promise that resolves when `initKeycloak()` reaches a terminal state (authenticated, redirected-to-login, or errored), and surface it on the injected façade.

**Before** (end of plugin + façade):
```js
const enhancedKeycloak = {
  get instance() { return keycloakInstance },
  get authenticated() { return keycloakInstance?.authenticated || false },
  ...
}
inject('kc', enhancedKeycloak)
if (process.client) { initKeycloak() }
```

**After:**
```js
// module scope (top of default export, before initKeycloak):
let _resolveReady
const authReady = new Promise((resolve) => { _resolveReady = resolve })
const settleReady = () => { if (_resolveReady) { _resolveReady(); _resolveReady = null } }

// inside initKeycloak(): call settleReady() on EVERY terminal path —
//   after resetRedirectCount()/token stored (success),
//   immediately before guardedLogin(...) (not authenticated),
//   in the catch block before the redirect.

const enhancedKeycloak = {
  get instance() { return keycloakInstance },
  get authenticated() { return keycloakInstance?.authenticated || false },
  get ready() { return authReady },              // ← NEW
  ...
}
inject('kc', enhancedKeycloak)
if (process.client) { initKeycloak() } else { settleReady() }
```

`settleReady()` must run on all three terminal branches so an awaiter never hangs (even on the redirect/guardedLogin paths, resolving is harmless because the page is navigating away).

**Why not** revert to `login-required`? That reintroduces the SBDEV-2390 loop. **Why not** await the whole plugin in Nuxt? Nuxt plugins run before the KC silent check can complete and awaiting there would still not gate per-request timing — the per-request `await $kc.ready` in Fix B is the correct barrier.

### Fix B — `onRequest`: await `ready` (bounded) before attaching the token

Make `onRequest` async and wait for init so the live, fresh token is used instead of the stale localStorage copy. Bound the wait so a stuck/blocked silent-check never freezes every request.

**After:**
```js
$axios.onRequest(async (config) => {
  await awaitAuthReady(app)                 // bounded; never rejects
  let kcToken = null
  if (app.$kc && app.$kc.authenticated && app.$kc.token) {
    kcToken = app.$kc.token                 // live fresh token
  } else {
    kcToken = localStorage.getItem('kcToken')
  }
  ...
})
```

Shared helper (top of the plugin), with a timeout so requests degrade gracefully rather than hang:
```js
const READY_TIMEOUT_MS = 5000   // bounded first-request wait; steady-state resolves immediately
function awaitAuthReady(app) {
  const ready = app.$kc && app.$kc.ready
  if (!ready) return Promise.resolve()   // no façade (e.g. /unknown-tenant, /error) → don't block
  return Promise.race([
    ready,
    new Promise((resolve) => setTimeout(resolve, READY_TIMEOUT_MS)),
  ]).catch(() => {})
}
```

> **Note (critic):** both apps are `ssr: false` (`nuxt.config.js`), so `keycloak.client.js` runs **client-only** — the `else { settleReady() }` server branch in Fix A is dead code (harmless; include it only for defensiveness). There is no SSR `asyncData`/`fetch` path that could fire an authenticated request before the client barrier exists.

### Fix C — `retryCondition`: distinguish "initializing" from "session invalid"; remove the logout reflex

**Before** (`axios.js:19-65`): the whole condition is a synchronous callback that wraps its logic in `return new Promise((resolve, reject) => { … })`, and the `!authenticated` branch calls `app.$kc?.logout()`.

**Implementation constraint (critic):** you **cannot** `await` inside that synchronous Promise executor, and turning the executor `async` silently swallows rejections. So `retryCondition` **itself becomes `async`** and drops the manual `new Promise` wrapper. axios-retry (4.5.0, confirmed in both repos) awaits an async `retryCondition` and treats the resolved value as the boolean retry decision — `true` = retry, `false` = give up.

**After (concrete signature — implement exactly this shape):**
```js
async retryCondition(error) {
  if (!error.response || (error.response.status !== 401 && error.response.status !== 403)) {
    return false
  }
  await awaitAuthReady(app)                 // let a mid-init check-sso finish (bounded)
  if (!app.$kc || !app.$kc.authenticated) {
    // Genuinely no session AFTER init settled (or the init-hang timeout fired).
    // Do NOT call logout() here — that reflex is what sent reloads to the KC
    // LOGOUT page (SBDEV-2554). Drive LOGIN instead: on a hard reload the KC
    // plugin already fired guardedLogin(); this is the safety net for the
    // init-hang edge where the plugin never got to run.
    console.warn('[SBDEV-2554] Not authenticated after init; deferring to Keycloak login (no axios logout).')
    app.$kc?.login?.()
    return false
  }
  try {
    const refreshed = await app.$kc.updateToken(5)
    if (!refreshed) {
      console.warn('Keycloak token not refreshed despite 401/403; not retrying.')
      return false
    }
    error.config.headers.Authorization = `Bearer ${app.$kc.token}`
    localStorage.setItem('kcToken', app.$kc.token)
    return true
  } catch (refreshError) {
    // Genuine refresh failure on an AUTHENTICATED session = real expiry.
    // The logout here is KEPT — this is not the reload race.
    console.error('Failed to refresh token during retry attempt:', refreshError)
    app.$toast.error('Session expired or invalid. Logging out...')
    app.$kc.logout()
    return false
  }
}
```

Key deltas vs. today: (1) no `new Promise` wrapper; (2) the `!authenticated` branch calls **`login()`, never `logout()`**; (3) the genuine-refresh-failure `logout()` (previously `axios.js:54-60`) is preserved verbatim in the `catch`.

### Fix D — `onMaxRetryTimesExceeded`: guard the terminal logout on authenticated state

Once Fix B is in place, reload requests carry a fresh token and never reach max-retries on a stale-token 401. As defense-in-depth, only force the terminal logout when the session is actually authenticated (i.e. a real, repeated 401 despite a valid session), so an init-window fluke can never reach it:

```js
onMaxRetryTimesExceeded(error, retryCount) {
  ...
  setTimeout(() => {
    localStorage.removeItem('kcToken');
    hasMaxRetriesBeenExceededForCurrentRequest = false;
    if (app.$kc && app.$kc.authenticated && app.$kc.logout) {
      app.$kc.logout();
    }
    // else: leave the KC plugin to drive login; no independent logout redirect.
  }, 3000);
}
```

### Not changed (preserve)
- `onLoad: 'check-sso'`, `silentCheckSsoRedirectUri`, `kc-redirect-guard.js` / `guardedLogin` (SBDEV-2390).
- `initTenantAuth.client.js` tenant discovery + redirect discipline (SBDEV-2391).
- `setupTokenRefresh` / `onTokenExpired` / `onAuthRefreshError` logout paths — they run only after auth is established.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `plugins/keycloak.client.js` | modify | Add `authReady` promise + `settleReady()` on all terminal init paths; expose `get ready()` on the injected façade. |
| `plugins/axios.js` | modify | Add `awaitAuthReady(app)` helper; make `onRequest` async and await it; await it in `retryCondition` and **remove** the `!authenticated → logout()` reflex; guard `onMaxRetryTimesExceeded` logout on `authenticated`. |
| `test/plugins/keycloak-ready.spec.js` | add | Unit test: `$kc.ready` resolves after init; façade exposes `ready`. |
| `test/plugins/axios-auth-timing.spec.js` | add | Unit test: 401 during init window does NOT call `logout()`; onRequest waits for ready then uses live token; genuine refresh failure still logs out. |

---

## 7. Prerequisites & Implementation Plan

### 7.1 Prerequisites

| # | Category | Applies? | Notes |
|---|----------|----------|-------|
| 1 | Database state | **N/A** | Frontend-only change; `db_verified: false`. |
| 2 | Feature flags / sysprops | **N/A** | No flags. |
| 3 | Config / env | **N/A** | No new env vars; `READY_TIMEOUT_MS` is a code constant. |
| 4 | Deploy order | Yes | Ship with the mobile mirror (`SBDEV-2554-mobile-…`) so both UIs behave consistently. No backend coupling. |
| 5 | Backend (`wms2-api`) | **N/A** | 401-on-expired-token is correct and unchanged. |
| 6 | Monitoring | Optional | Watch KC logout-endpoint hits / support reports of unexpected logout after deploy. |

### 7.2 Implementation Checklist
- [ ] Fix A — `authReady` + `settleReady()` on all terminal paths + `get ready()` in `keycloak.client.js`.
- [ ] Fix B — `awaitAuthReady` helper; `onRequest` async awaits it; uses live token.
- [ ] Fix C — `retryCondition` awaits ready; remove `!authenticated → logout()`.
- [ ] Fix D — guard `onMaxRetryTimesExceeded` logout on `authenticated`.
- [ ] Add both unit specs; `yarn test` green.
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2554-web-keycloak-reload-logout-regression.sh` → `0 fail`.
- [ ] Manual smoke (see §8): idle-then-reload keeps session; loop still broken.
- [ ] Update §10 Implementation Status with commit SHA + test/verify output.

---

## 8. Test Plan

### Unit (Jest — web has a Jest suite; see `test/plugins/`)
- `axios-auth-timing.spec.js`:
  - `retryCondition` on a 401 while `$kc.authenticated === false` and `$kc.ready` pending → **does not** call `app.$kc.logout()`; rejects the retry. (Directly asserts the SBDEV-2554 fix.)
  - After `$kc.ready` resolves with `authenticated === true`, a 401 triggers `updateToken` + retry with the refreshed token.
  - Genuine `updateToken()` rejection on an authenticated session → still calls `logout()` (Fix C boundary preserved).
  - `onRequest` awaits `ready` and attaches `app.$kc.token` (live) rather than the stale `localStorage.kcToken` once authenticated.
  - **Concurrency:** N simultaneous requests all awaiting the single `$kc.ready` all proceed once it resolves (no request is dropped, `logout` never called).
  - After the `awaitAuthReady` timeout with `authenticated===false`, the `!authenticated` branch calls `login()` (not `logout()`) — asserts the init-hang safety net.
- `keycloak-ready.spec.js`: `$kc.ready` is a promise that resolves once init settles (mock `keycloakInstance.init` resolving `true`/`false`), and resolves on the error/redirect terminal paths too.

### Integration
- N/A automated (no Cypress/Playstage harness wired for the auth bootstrap). Covered by the manual plan.

### Regression
- `verify-…sh` NEGATIVE checks assert the `!authenticated → logout()` reflex is gone from `retryCondition` and that `onLoad: 'check-sso'` is still present (loop fix not reverted).
- Existing SBDEV-2390 specs (`keycloak-redirect-guard.spec.js`, `initTenantAuth.spec.js`, `tenant-auth-fetch.spec.js`) must remain green.

### Manual test plan

| # | Scenario | Environment | Steps | Expected |
|---|----------|-------------|-------|----------|
| 1 | Idle-then-reload | dev2 web, real tenant | Log in, idle > access-token lifespan, reload | Page re-renders logged in; **no** KC logout page |
| 2 | Rapid reloads | dev2 web | Log in, hammer F5 ~10× | Stays logged in; no loop, no logout |
| 3 | Loop still broken | dev2 web | Reproduce SBDEV-2390 pre-conditions (cross-tab / bad config) | After ≤2 redirects lands on `/unknown-tenant?reason=auth`, not an infinite loop |
| 4 | Genuine expired SSO | dev2 web | Invalidate the KC SSO session server-side, reload | Clean re-login prompt (no hang, no loop) |
| 5 | Deep-link reload | dev2 web | Reload directly on e.g. `/picking` | Page loads with data; API calls carry a fresh token |

### Test execution (fill in after running)

| Command | Result | Notes |
|---------|--------|-------|
| `node_modules/.bin/jest --testPathPattern='axios-auth-timing\|keycloak-ready'` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2554-web-keycloak-reload-logout-regression.sh` | | |

> Note (from project memory): web has no `yarn` on PATH in some envs — run Jest via `node_modules/.bin/jest --testPathPattern=…` under the nvm node.

### Deliberately-skipped coverage
- Real-browser e2e of the KC silent-check timing: not automatable in the current harness; covered by manual scenarios 1-5.

---

## 9. Horizontal Scalability Validation & v2 constraints

### 9.0 Applicability note
This is a **client-side Nuxt/Vue** change. The wms2-api backend is not modified. The v2-API horizontal-scalability and Jakarta/OSIV/transaction constraint checklists are **N/A** (no server code, no DB, no cache, no cron, no tenant-context propagation on the server). The only "state" introduced is a per-tab, per-page-load JS promise (`authReady`) local to one browser tab — no cross-replica or cross-tab concern. `kc-redirect-guard` continues to use per-tab `sessionStorage` (unchanged).

| Concern | Verdict |
|---|---|
| Server in-JVM state / pool math / cron / tx / tenant context / cache / notifications | **N/A** — no backend change |
| Client per-tab state (`authReady` promise) | Yes — scoped to a single page load in one tab; resolved on all terminal init paths; bounded await prevents request hangs |

---

## 10. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `await $kc.ready` hangs a request forever if init never settles | High (app appears frozen) | `awaitAuthReady` uses `Promise.race` with `READY_TIMEOUT_MS`; `settleReady()` called on **every** terminal init path incl. catch |
| **Init-hang edge**: `init()` never resolves *and* never throws (e.g. `silent-check-sso.html` unreachable), so `settleReady()` and the plugin's own `guardedLogin` never fire | Medium | `awaitAuthReady` unblocks via timeout; the Fix C `!authenticated` branch then calls **`app.$kc.login()`** (login page, never the logout page) as the safety net — the user is redirected to log in, not stranded on a broken page. This is why the reflex was changed to `login()`, not simply deleted. |
| Removing the axios logout lets a genuinely-unauthenticated user sit on a broken page | Low | Normal flow: `keycloak.client.js` `guardedLogin` on `authenticated===false` already drives login before axios reacts; the Fix C `login()` covers the hang edge above |
| Reintroducing the SBDEV-2390 loop | High | `onLoad: 'check-sso'` and `kc-redirect-guard` untouched; `verify-…sh` NEGATIVE check fails if `login-required` returns |
| Async `onRequest` changes request ordering subtly | Low | `awaitAuthReady` resolves ~immediately once init settled (steady state); only the first post-reload requests wait |

---

## 11. Acceptance & Implementation

### 11.1 Acceptance script
`sbdocs/9-System/scripts/verify-SBDEV-2554-web-keycloak-reload-logout-regression.sh` (run with `PROJECT_ROOT=…/v2/wms2-web-ui`). Encodes:
- POSITIVE: `get ready()` exists on the façade; `awaitAuthReady` defined and awaited; the Fix C `login()`/defer marker string is present; `onLoad: 'check-sso'` and `guardedLogin` retained.
- NEGATIVE: `onLoad: 'login-required'` is absent (loop fix intact).

> **Gate authority (critic):** the code-shape greps are **advisory**. The negative "logout reflex removed" check cannot be made robust by grep alone (a reformat defeats a comment-string match). The **authoritative gate is the Jest spec** `axios-auth-timing.spec.js`, which asserts `app.$kc.logout` is **not** called on a 401 while `$kc.ready` is pending / `authenticated===false`. Both must pass.

### 11.2 Recommended OMC composition

| Step | Agent | Why |
|------|-------|-----|
| Implementation | executor | Single subsystem (2 plugins + 2 specs); verify-script as gate |
| Verification | verifier + verify-script | Mandatory before sign-off |

---

## 12. Implementation Status

**Implemented 2026-07-13; archived 2026-07-15 — merged to `develop` and released.** wms2-web-ui [PR #18](https://github.com/SiteBossInc/wms2-web-ui/pull/18) → `develop` (commit `bd71611`, verified on `origin/develop`); subsequently released (PR #19 → release, PR #20 → main, v0.0.7 / OWL v2.0.115). (Supersedes the earlier "Not yet committed" note.)

- **Files:** `plugins/keycloak.client.js` (Fix A — `authReady`/`settleReady` on all 3 init terminals + `get ready()`), `plugins/axios.js` (Fix B/C/D — `awaitAuthReady`, async `retryCondition` with `login()` not `logout()` on `!authenticated`, async `onRequest`, guarded max-retry logout). New specs: `test/plugins/keycloak-ready.spec.js` (5), `test/plugins/axios-auth-timing.spec.js` (10).
- **Tests:** new specs `Tests: 15 passed, 15 total`; full suite `Tests: 39 passed, 39 total` (SBDEV-2390 regression specs 20/20 green). The one failing *suite* is the pre-existing broken `test/NuxtLogo.spec.js` (imports a non-existent component; unrelated, touches none of these files).
- **Verify:** `Result: 13 pass, 0 fail, 0 skip` (independently re-run).
- **Known:** two pre-existing `dot-notation` lint errors on untouched `onRequest` header lines (already red on `develop`); no new lint introduced.
