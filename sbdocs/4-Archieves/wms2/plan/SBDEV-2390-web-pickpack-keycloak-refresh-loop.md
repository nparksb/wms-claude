---
title: "SBDEV-2390 — PickPack Open Parcels continuous refresh/redirect loop (web UI)"
ticket: "SBDEV-2390"
ticket_url: "https://app.clickup.com/t/868jwju5e"
type: "bugfix"
priority: "High"
status: "archived"
project: ["wms2-web-ui"]
version: "v2"
requester: "Brent Campbell"
created: "2026-07-02"
updated: "2026-07-15"
db_verified: false
related:
  - "SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.md"
tags:
  - plan
  - wms2-web-ui
  - keycloak
  - auth
  - refresh-loop
---

# SBDEV-2390 — PickPack Open Parcels continuous refresh/redirect loop (web UI)

**Ticket:** [SBDEV-2390](https://app.clickup.com/t/868jwju5e)
**Project:** wms2-web-ui | **Version:** v2 | **Type:** bugfix
**Priority:** High
**Status:** archived 2026-07-15 — **merged to `develop` and released.** wms2-web-ui [PR #6](https://github.com/SiteBossInc/wms2-web-ui/pull/6) → `develop` (merge `e4256ea`, verified on `origin/develop`); released → OWL v2.0.100 / wms2-web-ui v0.0.4 (PR #9 → release). (Supersedes the earlier "ready-for-review" note.)
**Date:** 2026-07-02

**Paired plan:** `SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.md` (wms2-mobile-ui — identical regression, mirror fix)

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep across `v2/wms2-web-ui` (`onLoad`, `.login()`, `location.replace/href`, `sessionStorage`, redirect targets) — not from memory.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|---------------------|
| 1 | plugins/keycloak.client.js:52-53 | `// onLoad: 'check-sso'` commented out; `onLoad: 'login-required'` active | yes (the regression) | **yes** — Fix A |
| 2 | plugins/keycloak.client.js:61-65 | `if (!authenticated) { keycloakInstance.login() }` — unconditional, no loop guard | yes | **yes** — Fix B |
| 3 | plugins/keycloak.client.js:88-93 | `catch { … keycloakInstance.login() }` — unconditional, no loop guard | yes | **yes** — Fix B |
| 4 | plugins/keycloak.client.js:28-36 | no-config → `window.location.replace('/unknown-tenant')` (skip-guard at line 5) | partial (single redirect, this is the "clear error" target) | **yes** — Fix E (verify guard) |
| 5 | pages/index.vue:59 | `event.detail.tokenParsedfg` — typo; dispatched event carries `tokenParsed` (keycloak.client.js:82) | contributing (kills the event path, forces 500ms polling) | **yes** — Fix C |
| 6 | pages/index.vue:37-43 | `authCheckInterval` 500ms poll; `clearInterval` on success + `beforeDestroy` | not an infinite loop by itself | no — bounded & cleared (documented in §2) |
| 7 | plugins/axios.js:12-93 | `axios-retry` 3× on 401/403 → `updateToken` → `logout()`; `onMaxRetryTimesExceeded` guarded | same generic root cause (un-guarded redirect) on a different trigger | no — already bounded by `retries:3`; documented as H5 |
| 8 | plugins/initTenantAuth.client.js:56-91,115-121 | tenant-change clear + `authConfig` 500/error → `tenantKeycloakConfig=null` | contributing (produces the `!config` state that feeds site 4) | **yes** — Fix E (ensure clean error, not loop) |
| 9 | components/outbound/pickPack/openParcels.vue:288-293 | `reloadList` watcher → `updateTable()` then resets flag | no — data re-fetch only, not a page reload | no — excluded (rationale in §2) |

Every **yes** row maps to a POSITIVE check in `verify-SBDEV-2390-web-pickpack-keycloak-refresh-loop.sh` (§9).

---

## 1. Problem Statement

> **`db_verified: false`** — This is a pure frontend auth/routing defect (Nuxt 2 / Vue 2 client plugins). No database state is involved and **no DB check is required** before implementation. The DB-verification gate is N/A. (Optional, non-blocking backend sanity if desired: `GET /api/public/authConfig?key={warehouse}-{client}` should return a Keycloak config for a healthy tenant and a 500/error for an unknown one — but the fix does not depend on it.)

**User-visible symptoms** (from ClickUp SBDEV-2390, reported by Brent Campbell, 2026-06-02, High):
- On the **Open PickPack Parcels** screen (`/outbound/pick-pack?tab=open`), after refreshing the page, the screen enters a **continuous refresh/redirect loop** and becomes unusable.
- Reported to resemble a *previously-fixed* refresh-loop issue (a regression).
- Most strongly observed while the user was **bouncing between the desktop web UI and the mobile UI** (shared Keycloak SSO session) during PickPack testing.
- Screen recording attached to the ticket (`screen-recording-2026-06-02-11:27.webm`).

**Reproduction** (per ticket — *exact repro currently unclear / intermittent*):
1. Navigate to WMS V2 web UI.
2. Open **Open PickPack Parcels**.
3. Interact with the picking workflow across desktop and mobile UIs.
4. Refresh the screen.
5. Observe the page entering a repeated refresh loop.

**Acceptance criteria (from ticket):**
- [ ] Open PickPack Parcels screen does not enter a refresh loop.
- [ ] Refreshing the screen results in a stable page load.
- [ ] User sees a clear error if the tenant cannot be verified.
- [ ] No infinite redirect/reload behavior occurs.
- [ ] Regression test added if reproducible.

---

## 2. Root Cause Analysis

The Open PickPack Parcels screen is not special — the loop is in the **global client-side auth bootstrap** that runs on *every* full page load (a browser refresh re-executes all Nuxt client plugins cold, in order: `initTenantAuth.client.js` → `keycloak.client.js` → `persistedState.client.js`). The screen is simply where the reporter happened to hit it.

Root cause is **two compounding defects** (confirmed by an adversarial tracer pass — see confidence notes):

### Bug 1 (H1) — `login-required` + unconditional `login()` with no loop-breaker = *why it never stops* (primary)

`plugins/keycloak.client.js:41-93`:

```js
const authenticated = await keycloakInstance.init({
  // onLoad: 'check-sso',
  onLoad: 'login-required',          // line 53
  silentCheckSsoRedirectUri: window.location.origin + '/silent-check-sso.html',
  checkLoginIframe: false,
  pkceMethod: 'S256'
})
if (!authenticated) {
  keycloakInstance.login()           // line 63 — unconditional, no guard
  return
}
// …
} catch (error) {
  if (keycloakInstance) {
    keycloakInstance.login()         // line 91 — unconditional, no guard
  }
}
```

There is **no redirect-attempt counter** anywhere in the auth plugin surface. If `init()` deterministically resolves `authenticated:false` (stale/invalid KC SSO cookie, blocked 3rd-party storage, config the app can't actually use) **or throws** (catch branch), `login()` fires, Keycloak bounces the browser back, the plugin re-runs cold, the *same deterministic condition* recurs, `login()` fires again — indefinitely. This is what turns a single failed load into an **infinite** loop. It is the necessary-and-sufficient mechanism for the "never stops" shape, independent of which trigger caused the first failed `init()`.

### Bug 2 (H3) — shared-origin, un-namespaced localStorage collision = *why it starts on the desktop↔mobile bounce* (trigger)

Mobile is deployed at `router.base: '/mobile/'` (see `wms2-mobile-ui/nuxt.config.js`), i.e. the production topology reverse-proxies **web (`/`) and mobile (`/mobile/`) onto the same origin**. Both apps read/write **identical, un-namespaced** localStorage keys:

- `plugins/initTenantAuth.client.js:102` → `localStorage.setItem('tenantKeycloakConfig', JSON.stringify(keycloakConfig))`
- `plugins/initTenantAuth.client.js:75` → `localStorage.setItem('clientName', …)`
- `plugins/keycloak.client.js:68` → `localStorage.setItem('kcToken', keycloakInstance.token)`

Whichever app's `initTenantAuth` resolved last "wins" the shared keys. Bouncing between web and mobile can therefore hand the open app's `keycloak.client.js` a token/config combination that makes `init()` fail deterministically on the next refresh — which Bug 1's missing guard then loops forever. The existing tenant-change-clear branch (`initTenantAuth.client.js:64-72`) does **not** protect this path: it only fires when `clientName` differs, and web/mobile on the same subdomain derive the *same* `clientName` from the hostname.

**Confidence:** Bug 1 High (code-structure + git-history corroboration). Bug 2 Medium — it is the best explanation for the *desktop↔mobile* correlation, but confirming it is the active trigger (vs. a stale KC cookie) requires a live capture (see §6 discriminating probe). The fix does not depend on which trigger fires: Bug 1's loop-breaker guarantees termination for *any* trigger.

### Contributing / ruled-out (for completeness)

- **H2 — `tokenParsedfg` typo (`pages/index.vue:59`).** `keycloak.client.js:81-83` dispatches `CustomEvent('keycloak-authenticated', { detail: { tokenParsed } })`; `index.vue:59` reads `event.detail.tokenParsedfg` → always `undefined` → `handleAuthentication` no-ops (`if (!tokenParsed) return`, line 64). This is a **confirmed orthogonal bug**: it kills the event-driven auth path, leaving only the 500ms polling fallback (lines 37-43). It does not itself cause a *page* reload loop, but it degrades the happy path and should be fixed in the same pass (Fix C).
- **H5 — axios-retry (`plugins/axios.js:12-93`).** On 401/403 it refreshes the token up to 3× then `logout()`s (another redirect). This is the *same* generic root cause (un-guarded redirect) on a different trigger, but it is already bounded by `retries:3` + `onMaxRetryTimesExceeded`, and it only fires *after* the user is authenticated and issuing API calls — so it is a secondary amplifier, not the initial trigger. Left as-is; documented here.
- **H4 — pick-pack `reloadList` watcher (`openParcels.vue:288-293`).** Only calls `updateTable()` (a data re-fetch) and resets its flag. No page reload, no auth/session interaction. **Excluded.**

---

## 3. The Regression Chain

The reload loop was previously diagnosed and fixed, then the fix was reverted during the multi-client rewrite.

| Commit | Date | Effect |
|--------|------|--------|
| `d1562c1` | 2024-10-21 | *"Changed keycloak login-required to check-sso to avoid the page to reload twice."* Set `onLoad: 'check-sso'`, added `silentCheckSsoRedirectUri` + `static/silent-check-sso.html`, and an `onReady` handler that called `login()` **only** when `!authenticated`. |
| `47a3a12` | (multi-client rewrite) | *"implemented multi-clients version of web UI…"* Reverted the fix: `onLoad: 'check-sso'` commented out, `onLoad: 'login-required'` restored, `login()` called unconditionally on `!authenticated` and in the `catch`. No loop guard reinstated. |

`static/silent-check-sso.html` still exists and `silentCheckSsoRedirectUri` is still passed to `init()` (line 54) — so restoring `check-sso` is a one-line change with its supporting asset already in place.

---

## 4. Architecture Overview

```
Browser refresh on /outbound/pick-pack?tab=open
        │  (Nuxt re-runs ALL client plugins cold, in order)
        ▼
initTenantAuth.client.js ── extractClientFromUrl() ── fetch /api/public/authConfig
        │                                                     │
        │  writes shared localStorage: tenantKeycloakConfig,  │ 500/error → config=null
        │  clientName   ◄── COLLIDES with /mobile/ app (Bug 2) │
        ▼                                                     ▼
keycloak.client.js ── getKeycloakConfig()             (no config) → location.replace('/unknown-tenant')
        │
        ▼
keycloakInstance.init({ onLoad: 'login-required' })   ◄── Bug 1
        │
   authenticated? ──no──► login()  ──► Keycloak ──► redirect back ──► [re-run cold] ──┐
        │                    ▲                                                        │
       yes                   └──────────────── INFINITE LOOP (no counter) ◄───────────┘
        ▼
   store kcToken, setupTokenRefresh, dispatch 'keycloak-authenticated'
        ▼
pages/index.vue  ── onKeycloakAuthenticated(event.detail.tokenParsedfg) ◄── Bug H2 (undefined → no-op)
        └── fallback: authCheckInterval 500ms poll → handleAuthentication → redirectPage
```

**Key files**

| File | Lines | Role |
|------|-------|------|
| plugins/keycloak.client.js | 41-93 | KC init, `onLoad`, unconditional `login()` — **Fix A, B** |
| plugins/keycloak.client.js | 3-36 | no-config → `/unknown-tenant` redirect — **Fix E** |
| plugins/initTenantAuth.client.js | 43-122 | tenant discovery, shared localStorage writes, authConfig error handling — **Fix E** |
| pages/index.vue | 57-61 | `keycloak-authenticated` handler with `tokenParsedfg` typo — **Fix C** |
| static/silent-check-sso.html | — | silent SSO iframe target (already present) |
| pages/unknown-tenant.vue | — | existing clear-error page (redirect target) |

---

## 5. Fix Design

### Fix A — Restore `onLoad: 'check-sso'` (+ silent SSO)

**Problem:** `onLoad: 'login-required'` forces Keycloak to redirect to the login endpoint on init whenever there is no established SSO session — the "reload twice" behavior `d1562c1` removed.

**Solution:** Restore the reverted line. `silentCheckSsoRedirectUri` + `static/silent-check-sso.html` are already present, so `check-sso` performs a silent session check without a forced redirect. When `check-sso` reports `!authenticated`, our code calls `login()` explicitly — now gated by the Fix B loop-breaker.

> **Fix A and Fix B are coupled — Fix A is load-bearing, not cosmetic.** Under `onLoad: 'login-required'`, keycloak-js performs the login redirect **inside `init()`**, before the promise resolves and before any of our code runs — so the `if (!authenticated)` block (line 61) and the sessionStorage counter would **never execute** on the main unauthenticated path. `check-sso` makes `init()` resolve `authenticated:false` *without* redirecting, handing control back so `guardedLogin()` can count. **Do not keep `login-required` "to be safe" — it silently defeats the loop-breaker.**

```js
// plugins/keycloak.client.js — init options
const authenticated = await keycloakInstance.init({
  onLoad: 'check-sso',                                   // restored (was login-required)
  silentCheckSsoRedirectUri: window.location.origin + '/silent-check-sso.html',
  checkLoginIframe: false,
  pkceMethod: 'S256'
})
```

**Files changed:** `plugins/keycloak.client.js`

### Fix B — `sessionStorage` redirect-loop breaker (the hard termination guarantee)

**Problem:** No counter guards the `login()` calls (sites 2, 3). Any deterministic init failure loops forever.

**Solution:** A small helper that counts redirect attempts in `sessionStorage` (per-tab; **sessionStorage survives the full-page round-trip to the Keycloak origin and back** — it is scoped to the tab and cleared only on tab close, so it correctly accumulates across `login()→KC→back→cold reload`, and a legitimate later re-login in a fresh tab is never blocked). Before each `login()`, increment; once the count exceeds `MAX_KC_REDIRECTS`, **do not** call `login()` — instead redirect to the clear-error page. On a **successful** `init()` (`authenticated === true`), reset the counter to `0`.

**Threshold = `2`** (Architect synthesis): a normal SSO/first-time login peaks at count = 1 (`load → guardedLogin(1) → KC → back → authenticated → reset`); MAX = 2 gives exactly one bounce of headroom while capping the visible KC bounces at 2 for a deterministic failure. IdP brokering happens *server-side inside a single KC `login()` redirect* and does not multiply the app-side count, so MAX = 2 is safe. A `console.warn` breadcrumb fires when the breaker trips, so the still-open "which trigger" question (Bug 2 vs stale cookie) becomes observable in production.

> **Helper placement:** define the counter helpers + `guardedLogin` at **module scope** (or a tiny separate module `plugins/kc-redirect-guard.js`), **not** inside the `export default function (…)` plugin closure — so `test/plugins/keycloak-redirect-guard.spec.js` can `import` them without booting the Nuxt plugin.

```js
// plugins/kc-redirect-guard.js (module scope — importable by the Jest spec)
const MAX_KC_REDIRECTS = 2
const REDIRECT_KEY = 'kcRedirectAttempts'

function bumpRedirectCount() {
  const n = parseInt(sessionStorage.getItem(REDIRECT_KEY) || '0', 10) + 1
  sessionStorage.setItem(REDIRECT_KEY, String(n))
  return n
}
function resetRedirectCount() {
  sessionStorage.removeItem(REDIRECT_KEY)
}
// Call login() only through this gate:
function guardedLogin(kc) {
  if (bumpRedirectCount() > MAX_KC_REDIRECTS) {
    console.warn(`[SBDEV-2390] KC redirect loop broken after ${MAX_KC_REDIRECTS} attempts; routing to clear error.`)
    resetRedirectCount()
    window.location.replace('/unknown-tenant?reason=auth')   // clear error, breaks the loop
    return
  }
  kc.login()
}
```

- Site 2 (`!authenticated`, line 63) → `guardedLogin(keycloakInstance)`.
- Site 3 (`catch`, line 91) → **`if (keycloakInstance) { guardedLogin(keycloakInstance) } else { bumpRedirectCount(); window.location.replace('/unknown-tenant?reason=auth') }`**. Web's catch retains a usable instance in the common case (init threw *after* `new Keycloak()`), so `guardedLogin` is valid. The `else` covers the near-zero edge where `new Keycloak()` itself threw (null instance) — route it to the clear-error page rather than dying silently, mirroring mobile Fix D.
- **On success:** call `resetRedirectCount()` as the **first statement after the `if (!authenticated)` block** (before token storage / `handleAuthentication` dispatch) so a later throw can't skip the reset and strand a stale count.

This is the **hard termination guarantee** for the AC "no infinite redirect/reload" — it terminates the loop regardless of which trigger (Bug 2 collision, stale KC cookie, blocked storage) caused it. Note the coupling (Fix A): the counter only *runs* because `check-sso` returns control to our code; under `login-required` `init()` would redirect before the counter executes.

**Files changed:** `plugins/keycloak.client.js`

### Fix C — Fix the `tokenParsedfg` typo

**Problem:** `pages/index.vue:59` reads `event.detail.tokenParsedfg` (undefined) → the event-driven auth path is dead; only the 500ms poll works.

**Solution:**

```js
// pages/index.vue:59
- const tokenParsed = event.detail.tokenParsedfg
+ const tokenParsed = event.detail.tokenParsed
```

**Files changed:** `pages/index.vue`

### Fix E — Ensure every "tenant cannot be verified" path lands on a clear error (no loop)

**Problem:** The AC requires a clear error when the tenant can't be verified. Today `keycloak.client.js:28-36` and `initTenantAuth.client.js` (authConfig 500 / no client / fetch error) drive toward `/unknown-tenant`, and both plugins skip re-running on `/unknown-tenant` (+ `/error`). Verify these skip-guards actually cover every no-config / authConfig-failure path so a config failure surfaces as a single clear redirect, never a loop.

**Concrete edits:**
1. **Web skip-guard gap (confirmed):** `keycloak.client.js:5` guards **only** `'/unknown-tenant'`, while `initTenantAuth.client.js:45` guards both `'/unknown-tenant'` and `'/error'`. Add `'/error'` to `keycloak.client.js:5` for parity so a page already showing an error does not re-run the KC bootstrap:
   ```js
   - if (route.path === '/unknown-tenant') { return; }
   + if (route.path === '/unknown-tenant' || route.path === '/error') { return; }
   ```
2. **Auth vs tenant error copy (satisfies the AC precisely):** an *init/auth* failure is not literally a "tenant not found" failure. Rather than add a new page, pass `?reason=auth` on the loop-breaker redirect (Fix B) and add one conditional line to `pages/unknown-tenant.vue` so the copy reads "We couldn't verify your session or tenant — please sign in again" when `$route.query.reason === 'auth'`. This closes the gap between the promised "clear error" message and the bare redirect.
3. Confirm the `authConfig` 500/error branches (`initTenantAuth.client.js:86-91,115-121`) leave `tenantKeycloakConfig=null` so `keycloak.client.js` takes the single `replace('/unknown-tenant')` path (unchanged behavior).

**Files changed:** `plugins/keycloak.client.js`, `plugins/initTenantAuth.client.js` (guard parity), `pages/unknown-tenant.vue` (one conditional line for the `reason=auth` copy)

### Fix F — (RECOMMENDED HARDENING, DEFERRED — not in this ticket's rollout)

Namespace the shared web/mobile localStorage keys (`kcToken`, `tenantKeycloakConfig`, `clientName`) per app so the same-origin collision (Bug 2 trigger) cannot occur — e.g. prefix by `router.base` (`web:` vs `mobile:`). **Deferred** per decision: the Fix B loop-breaker already guarantees the loop terminates regardless of trigger, and Fix F touches logout + `persistedState` read paths (larger regression surface) — inappropriate for a High-priority hotfix. Tracked in §8 as a follow-up; requires the §6 discriminating-probe capture to confirm the collision is the active trigger before it is worth the blast radius.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| plugins/kc-redirect-guard.js | new | Fix B helper module (module-scope `guardedLogin`/`bumpRedirectCount`/`resetRedirectCount`) — importable by the Jest spec |
| plugins/keycloak.client.js | edit | Fix A (restore `check-sso`), Fix B (wire `guardedLogin` at both `login()` sites + reset-on-success), Fix E (`/error` skip-guard parity) |
| pages/index.vue | edit | Fix C (`tokenParsedfg` → `tokenParsed`) |
| plugins/initTenantAuth.client.js | edit (defensive) | Fix E (confirm authConfig-failure paths leave config=null → single `/unknown-tenant` redirect) |
| pages/unknown-tenant.vue | edit | Fix E (one conditional line: `reason=auth` → "couldn't verify your session or tenant" copy) |
| test/plugins/keycloak-redirect-guard.spec.js | new | Jest unit test for the loop-breaker helper (Fix B) |

---

## 7. Prerequisites & Implementation Plan

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | Database state | **N/A** — frontend-only change, no DB. | — | `db_verified: false` |
| 2 | Feature flags / system properties | **N/A** — no toggles. | — | |
| 3 | Config / env changes | `static/silent-check-sso.html` present (it is). No env change. | Dev | check-sso needs the silent-sso asset only |
| 4 | Deploy-order dependencies | None. Independent of backend and of the mobile plan (fixes can ship separately). | — | Mobile plan is a sibling, not a blocker |
| 5 | Data migration | **N/A** | — | |
| 6 | External systems | Keycloak realm/client reachable (unchanged from today). | — | |
| 7 | Access / permissions | **N/A** — no new roles/scopes. | — | |
| 8 | Monitoring / alerts | Optional: add a console/error breadcrumb when the loop-breaker fires (count > MAX) so recurrence is observable. | Dev | non-blocking |

### 7.2 Implementation Checklist

- [ ] Fix A — restore `onLoad: 'check-sso'` in `plugins/keycloak.client.js`.
- [ ] Fix B — add `guardedLogin` + `sessionStorage` counter; route both `login()` sites through it; `resetRedirectCount()` on successful auth.
- [ ] Fix C — correct `tokenParsedfg` → `tokenParsed` in `pages/index.vue`.
- [ ] Fix E — add `'/error'` to the `keycloak.client.js:5` skip-guard; add the `reason=auth` conditional copy to `pages/unknown-tenant.vue`; confirm authConfig-failure paths leave config=null.
- [ ] Unit test — `test/plugins/keycloak-redirect-guard.spec.js` for the loop-breaker helper.
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2390-web-pickpack-keycloak-refresh-loop.sh` → `0 fail`.
- [ ] `yarn lint` + `yarn test` green.
- [ ] Manual QA (§8 table) on staging.
- [ ] Code review completed.

---

## 8. Test Plan

### Unit (Jest — web has a Jest suite)

| Test class/file | Test method | What it asserts |
|-----------------|-------------|-----------------|
| test/plugins/keycloak-redirect-guard.spec.js | `guardedLogin calls kc.login() below the threshold` | first `MAX_KC_REDIRECTS` calls invoke `kc.login()`; counter increments in `sessionStorage` |
| test/plugins/keycloak-redirect-guard.spec.js | `guardedLogin redirects to /unknown-tenant past the threshold` | on the `(MAX+1)`th call `kc.login()` is NOT called and `window.location.replace('/unknown-tenant')` is invoked |
| test/plugins/keycloak-redirect-guard.spec.js | `resetRedirectCount clears the counter on success` | after reset, the next `guardedLogin` starts from 1 again |

> Testing note: mock `sessionStorage` and `window.location.replace`; the helper lives in `plugins/kc-redirect-guard.js` (module scope, per Fix B), so the spec imports it directly without booting the Nuxt plugin.

### Integration

**N/A** — no backend/integration surface; the change is entirely client-side plugin logic. (Documented rather than silently skipped.)

### Regression

- Guard against re-introduction: `verify-…sh` NEGATIVE checks assert `onLoad: 'login-required'` and `tokenParsedfg` are gone and that no un-guarded `keycloakInstance.login()` remains.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Happy path — refresh Open PickPack Parcels | staging web | 1. Sign in. 2. Open `/outbound/pick-pack?tab=open`. 3. Hard-refresh 5×. | Page loads once each time, stable, no loop. | |
| Desktop↔mobile bounce | staging (same origin, `/` + `/mobile/`) | 1. Sign in on web. 2. Open mobile `/mobile/`. 3. Return to web PickPack. 4. Refresh. | Stable load; no infinite redirect. | |
| Tenant cannot be verified | staging | 1. Force `authConfig` failure (unknown tenant key / backend 500). 2. Load any page. | Single redirect to `/unknown-tenant` clear-error page; **no loop**. | |
| Loop-breaker trips | staging | 1. Simulate persistent `init()` failure (e.g. bad realm). 2. Load page. | After ≤`MAX_KC_REDIRECTS` bounces, lands on `/unknown-tenant`, loop stops. | |
| DevTools capture (the "if reproducible" path) | staging | With Console+Network "preserve log": trigger the loop and record (a) `Keycloak initialized. Authenticated:` vs `Failed to initialize Keycloak:`; (b) URL hops (KC `/auth` vs `/unknown-tenant`); (c) `localStorage.tenantKeycloakConfig`/`kcToken` before vs mid-loop. | Confirms which trigger (Bug 2 collision vs stale cookie) fires; attach to ticket. | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped |
|---------|--------|------------------------|
| `yarn test -- --testPathPattern=keycloak-redirect-guard` | | |
| `yarn lint` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2390-web-pickpack-keycloak-refresh-loop.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Integration/e2e for the full KC redirect flow | No SSR/backend surface; KC redirect is a browser-level flow not exercisable in Jest. Covered by the manual QA table. |

### Pre-mortem (deliberate mode)

1. **check-sso silently leaves the user unauthenticated on a slow network** → the silent iframe times out, `!authenticated`, `guardedLogin` fires. *Mitigation:* `guardedLogin`'s first `MAX` attempts still call `login()` (a real interactive login), so a transient failure recovers; only a *persistent* failure lands on `/unknown-tenant`.
2. **sessionStorage counter never resets because success never reached** → user is stuck on `/unknown-tenant`. *Mitigation:* that is the intended terminal state (clear error) rather than an infinite loop; counter clears on tab close, so a fresh tab retries cleanly.
3. **Long-lived tab: a token-expiry re-login accumulates counts and trips the breaker.** *Mitigation:* `resetRedirectCount()` fires on every successful `init()` (`authenticated===true`), so each successful auth zeroes the counter — a re-login after any prior success starts from 0. The counter only accumulates across *consecutive failures without an intervening success*, which is exactly the loop it is meant to break. IdP brokering does not add to this (server-side, inside a single KC `login()` redirect — it does not multiply the app-side count), so MAX=2 is safe; the constant is named for trivial tuning if a real IdP flow proves otherwise in staging.

---

## 9. Horizontal Scalability Validation & v2 constraints

### 9.0 Applicability note

This plan targets **wms2-web-ui (a Nuxt 2 SPA/client)**, not `wms2-api`. The backend-oriented HSV and v2-constraint checklists below are therefore almost entirely N/A; each row carries a one-line rationale, and the frontend-relevant analogs are called out where they apply (client-side `localStorage`/`sessionStorage` state shared across same-origin apps/tabs, multi-tenant client extraction from hostname, per-tab vs cross-tab redirect-counter scoping).

| # | Concern | Verdict | Rationale (frontend analog) |
|---|---|---|---|
| 1 | In-JVM state | N/A | No JVM. **Frontend analog:** the new counter uses `sessionStorage` (per-tab, not shared) — deliberately NOT `localStorage`, to avoid the cross-tab/cross-app collision that is Bug 2. |
| 2 | Connection pool math | N/A | No server DB connections. |
| 3 | Scheduled jobs | N/A | No cron. |
| 4 | Long transactions | N/A | No transactions. |
| 5 | Request affinity | N/A | SPA; no server session affinity. |
| 6 | Retry / idempotency | N/A (analog: Yes) | **Analog:** the loop-breaker makes the redirect path idempotent-safe — re-running the cold plugin re-reads the same counter and converges to the error page instead of looping. |
| 7 | Tenant context | N/A (analog: Yes) | **Analog:** tenant is derived per page load from hostname (`extractClientFromUrl`); the shared-key collision (Bug 2) is the tenant-context hazard, documented + deferred to Fix F. |
| 8 | Distributed lock | N/A | No locks. |
| 9 | Cache invalidation | N/A | No server cache. |
| 10 | External notifications | N/A | None. |

**v2-only constraint checklist (backend-scoped):** OSIV / tenantTransactionManager / readOnly / Caffeine / Jakarta / H2-test-SQL / BaseControllerTest / Micrometer — **all N/A** (no Java/Spring in this repo).

---

## 10. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| `check-sso` behaves differently than `login-required` for a first-time (no SSO session) user | Medium | `check-sso` + explicit `guardedLogin()` on `!authenticated` preserves the login prompt; validated by the "Happy path" + "Loop-breaker trips" manual scenarios. This restores the exact behavior `d1562c1` shipped. |
| Loop-breaker threshold too low/high | Low | Named constant `MAX_KC_REDIRECTS`; unit-tested; tunable in staging. |
| Bug 2 (localStorage collision) remains a latent trigger (Fix F deferred) | Medium | Loop-breaker terminates the loop regardless; Fix F tracked as follow-up; §8 capture steps confirm before investing. |
| Mobile not fixed in this plan | Medium | Paired plan `SBDEV-2390-mobile-…` ships the mirror fix; both share the SSO session. |
| Regression re-introduced by a future auth rewrite | Medium | `verify-…sh` NEGATIVE checks guard `login-required` / un-guarded `login()` / `tokenParsedfg`; project-memory directive recommended after rollout. |

---

## 11. Acceptance & Implementation

### 11.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2390-web-pickpack-keycloak-refresh-loop.sh` (run with `PROJECT_ROOT=…/v2/wms2-web-ui`). Encodes:
- **POSITIVE (Fix A/B/C):** `onLoad: 'check-sso'` present; `sessionStorage` redirect counter + `guardedLogin` present; `resetRedirectCount()` on success; loop-breaker redirect reachable from the guard — match the **open-ended prefix** `location\.replace\('/unknown-tenant` (the actual target is `/unknown-tenant?reason=auth`, so a closed literal would miss it); `event.detail.tokenParsed` (correct) in `index.vue`.
- **POSITIVE (Fix E — added per Critic MAJOR-3, both grep-expressible):** `route.path === '/error'` present in the top-of-plugin skip-guard of `keycloak.client.js` (parity with `initTenantAuth`); `reason` / `reason=auth` handling present in `pages/unknown-tenant.vue`.
- **NEGATIVE:** `onLoad: 'login-required'` gone; `tokenParsedfg` gone; no un-guarded `keycloakInstance.login()` outside `guardedLogin`.
- Optional: `yarn test` on the guard spec.

Final acceptance: the script prints `Result: N pass, 0 fail` and the implementer pastes that line.

### 11.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Size class | **Standard** | 3 code fixes + 1 test, single subsystem (auth bootstrap) |
| Pre-draft step | analyst+planner (done: tracer + this ralplan) | already consensus-reviewed |
| Plan-review step | critic | Standard+ |
| Implementation shape | executor | single subsystem, verify-script as gate |
| Verification step | verify-script + verifier | mandatory |
| Code-review step | code-reviewer | auth-path change |
| Commit step | git-master | 3 logical commits (Fix A+B, Fix C, test) |

---

## 12. Notes

- Paired mobile plan: `SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.md`.
- Follow-up (Fix F): namespace shared localStorage keys per app to remove the Bug 2 trigger — gate on the §8 DevTools capture first.
- After rollout, add a `project_memory_add_directive`: *"Any wms2 UI auth/keycloak change must preserve `onLoad:'check-sso'` and the sessionStorage redirect-loop breaker (SBDEV-2390); never revert to `login-required` with an un-guarded `login()`."*
