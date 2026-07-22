---
title: "SBDEV-2390 — Keycloak refresh/redirect loop (mobile UI, paired)"
ticket: "SBDEV-2390"
ticket_url: "https://app.clickup.com/t/868jwju5e"
type: "bugfix"
priority: "High"
status: "archived"
project: ["wms2-mobile-ui"]
version: "v2"
requester: "Brent Campbell"
created: "2026-07-02"
updated: "2026-07-15"
db_verified: false
related:
  - "SBDEV-2390-web-pickpack-keycloak-refresh-loop.md"
tags:
  - plan
  - wms2-mobile-ui
  - keycloak
  - auth
  - refresh-loop
---

# SBDEV-2390 — Keycloak refresh/redirect loop (mobile UI, paired)

**Ticket:** [SBDEV-2390](https://app.clickup.com/t/868jwju5e)
**Project:** wms2-mobile-ui | **Version:** v2 | **Type:** bugfix
**Priority:** High
**Status:** archived 2026-07-15 — **merged to `develop` and released.** wms2-mobile-ui [PR #6](https://github.com/SiteBossInc/wms2-mobile-ui/pull/6) → `develop` (merge `a16cb0c`, verified on `origin/develop`); released → OWL v2.0.100 / wms2-mobile-ui v0.0.4 (PR #9 → release). (Supersedes the earlier "ready-for-review" note.)
**Date:** 2026-07-02

**Paired plan (primary):** `SBDEV-2390-web-pickpack-keycloak-refresh-loop.md`. The mobile UI shares the same Keycloak SSO session and carries the **identical regression** — the ticket explicitly involves bouncing between desktop and mobile, so both surfaces must be fixed. This plan mirrors the web fix with mobile-specific deltas.

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep across `v2/wms2-mobile-ui`.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|---------------------|
| 1 | plugins/keycloak.client.js:147-152 | `initOptions = { onLoad: 'login-required', … }` — **no** `silentCheckSsoRedirectUri` | yes (the regression) | **yes** — Fix A (restore check-sso + ADD silent uri) |
| 2 | plugins/keycloak.client.js:164-172 | `if (!authenticated) { … keycloakInstance.login() }` — unconditional, no loop guard | yes | **yes** — Fix B |
| 3 | plugins/keycloak.client.js:202-214 | `catch { … state.keycloakInstance = null; if (state.keycloakInstance) state.keycloakInstance.login() }` — **dead code** (guards on the just-nulled ref) → silent failure on init error | yes (variant) | **yes** — Fix D |
| 4 | plugins/keycloak.client.js:120-126 | no-config → `window.location.replace('/unknown-tenant')` (skip-guard at line 79) | partial (single redirect, "clear error" target) | **yes** — Fix E (verify guard) |
| 5 | plugins/keycloak.client.js:113-118 | `state.isInitializing` guard (prevents concurrent init within one page load) | partial existing guard | no — keep; it does NOT guard cross-page-load redirects (documented in §2) |

silent-check-sso.html is present in mobile `static/`. Note `router.base: '/mobile/'` — all redirect paths resolve under `/mobile`. Error pages: `not-authorized`, `unhealthy-tenant`, `unknown-tenant` (no `not-affiliated`).

Every **yes** row maps to a POSITIVE check in `verify-SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.sh` (§9).

---

## 1. Problem Statement

> **`db_verified: false`** — Pure frontend auth/routing defect (Nuxt 2 / Vue 2 SPA, `ssr: false`). No DB state; **no DB check required**. Gate is N/A.

The mobile UI (served at `/mobile/`) runs the same tenant-discovery → Keycloak bootstrap as the web UI on every full page load. The reporter's loop was observed on the web PickPack screen while bouncing to the mobile UI; because both share one Keycloak SSO session **and** the same localStorage keys on a shared origin, the mobile side is both a *co-victim* and a likely *trigger* of the loop (see §2 Bug 2). The mobile app has **no automated test suite** (per its CLAUDE.md), so verification is manual QA + the shared DevTools capture procedure.

**Acceptance criteria (from ticket):** identical to the web plan — no refresh loop; stable load on refresh; clear error if tenant cannot be verified; no infinite redirect/reload; regression test if reproducible.

---

## 2. Root Cause Analysis

Same two compounding defects as the web plan (see the primary plan §2 for the full tracer analysis). Summary as they appear in mobile code:

### Bug 1 (H1) — `login-required` + unconditional `login()`, no loop-breaker (primary)

`plugins/keycloak.client.js`:
```js
// lines 147-152
const initOptions = {
  onLoad: 'login-required',      // no silentCheckSsoRedirectUri present
  checkLoginIframe: false,
  pkceMethod: 'S256',
  enableLogging: true
}
// lines 164-172
if (!authenticated) {
  localStorage.removeItem('kcToken'); localStorage.removeItem('kcRefreshToken')
  state.isInitializing = false
  keycloakInstance.login()       // unconditional, no cross-load guard
  return
}
```
The `state.isInitializing` flag (lines 113-118) only prevents a *second concurrent* init **within one page load** — it is reset to `false` before `login()` and does not survive the redirect, so it provides **no** protection against the cross-page-load redirect loop. Same infinite mechanism as web.

### Bug 1b (variant) — dead-code catch path = silent failure on init error

`plugins/keycloak.client.js:202-214`:
```js
} catch (error) {
  state.isInitializing = false
  localStorage.removeItem('kcToken'); localStorage.removeItem('kcRefreshToken')
  state.keycloakInstance = null              // ← nulled here
  if (state.keycloakInstance) {              // ← always false → dead code
    state.keycloakInstance.login()
  }
}
```
On an init exception the app neither logs in nor redirects to a clear error — it silently dies (blank/spinner). This both violates the "clear error" AC and, combined with the polling in `pages/index.vue`, can present as an unrecoverable stuck state.

### Bug 2 (H3) — shared-origin, un-namespaced localStorage collision (trigger)

`router.base: '/mobile/'` places mobile on the **same origin** as web. Both write `kcToken` (keycloak.client.js), `tenantKeycloakConfig` + `clientName` (initTenantAuth.client.js) under identical keys. Bouncing between the two apps lets whichever resolved last overwrite the shared keys, handing the other app a token/config that fails `init()` next refresh → Bug 1 loops it. See primary plan §2 for the full argument and confidence notes.

---

## 3. The Regression Chain

| Commit | Repo | Effect |
|--------|------|--------|
| `1c219bc` | wms2-mobile-ui | *"Reverted back to login-required keycloak."* — explicitly reverted mobile to `onLoad: 'login-required'`, re-introducing the loop-prone bootstrap (mirrors the web `47a3a12` revert of `d1562c1`). |

---

## 4. Architecture Overview

Identical flow to the primary plan, with mobile paths under `/mobile/`:

```
Refresh under /mobile/…  →  initTenantAuth.client.js (shared localStorage: kcToken/tenantKeycloakConfig/clientName ◄ COLLIDES with web)
                          →  keycloak.client.js init({ onLoad:'login-required' })  ◄ Bug 1
                                 authenticated? ──no──► login() ──► KC ──► back ──► [re-run cold] ──► LOOP (no counter)
                                 catch(error) ──► state.keycloakInstance=null; if(nullref) login()  ◄ Bug 1b (dead code → silent death)
```

**Key files**

| File | Lines | Role |
|------|-------|------|
| plugins/keycloak.client.js | 130-215 | init, onLoad, unconditional `login()`, dead-code catch — **Fix A, B, D** |
| plugins/keycloak.client.js | 120-126 | no-config → `/unknown-tenant` — **Fix E** |
| plugins/initTenantAuth.client.js | — | tenant discovery + shared localStorage writes — **Fix E** |
| static/silent-check-sso.html | — | silent SSO target (present) |
| pages/unknown-tenant.vue | — | existing clear-error page |

---

## 5. Fix Design

### Fix A — Restore `onLoad: 'check-sso'` **and add** `silentCheckSsoRedirectUri`

Mobile's `initOptions` (lines 147-152) lacks `silentCheckSsoRedirectUri`, so restoring check-sso requires **re-adding** it. This is a *restore*: commit `1c219bc` ("Reverted back to login-required keycloak.") commented out **both** `onLoad:'check-sso'` and this exact `silentCheckSsoRedirectUri: window.location.origin + '/mobile/silent-check-sso.html'` line — so the URI string below matches what previously shipped.

```js
const initOptions = {
  onLoad: 'check-sso',                                                    // restored (was login-required)
  silentCheckSsoRedirectUri: window.location.origin + '/mobile/silent-check-sso.html', // restored (note /mobile base)
  checkLoginIframe: false,
  pkceMethod: 'S256',
  enableLogging: true
}
```
> `static/silent-check-sso.html` is present and serves from `/mobile/silent-check-sso.html` under the router base — verified against the shipped string in `1c219bc`.
>
> **Fix A is load-bearing for Fix B (coupling):** under `onLoad:'login-required'` keycloak-js redirects *inside* `init()` before the `if (!authenticated)` block (line 164) runs, so the counter never executes on the unauthenticated path. `check-sso` returns control so `guardedLogin()` can count. Do not keep `login-required`.

### Fix B — `sessionStorage` redirect-loop breaker (hard termination guarantee)

Same helper/contract as the primary plan (`MAX_KC_REDIRECTS = 2`, per-tab `sessionStorage` counter that survives the KC round-trip, `guardedLogin()` → after threshold `console.warn` breadcrumb + `window.location.replace('/mobile/unknown-tenant?reason=auth')`, `resetRedirectCount()` as the first statement after the `if (!authenticated)` block). Route the site-2 `login()` (line 170) through `guardedLogin`. Because mobile keeps its instance on `window.__keycloakState`, the counter lives in `sessionStorage` (not on that object), so it is orthogonal to `__keycloakState`, survives the cold re-run, and stays per-tab. Note the redirect path is `/mobile/`-prefixed (router base).

### Fix D — Fix the dead-code catch path (concrete, loop-safe)

The current catch (`keycloak.client.js:202-214`) sets `state.keycloakInstance = null` and then guards `if (state.keycloakInstance)` — always false → `login()` is **dead code**, so an init exception dies silently (blank/spinner), violating the "clear error" AC.

The **local** `const keycloakInstance` (declared at `keycloak.client.js:137` inside `initKeycloak`) is still a valid, in-scope object in the catch — only `state.keycloakInstance` is nulled (line 209). So `guardedLogin(keycloakInstance)` *would* be technically implementable here (web does exactly that in its catch). We deliberately **do not** retry login on this path: `init()` *threw* (a deterministic failure — bad realm/config, malformed token — not merely "no session"), so a re-login retry is unlikely to self-heal, and a reload-on-catch would create a **new** loop site. Therefore the catch path uses an **unconditional guarded clear-error redirect** — increment the counter (for the breadcrumb / observability) strictly **before** the redirect, then go to the clear-error page. This is an intentional, documented web↔mobile asymmetry (web retries once via `guardedLogin` on a transient throw; mobile routes straight to the clear error):

```js
} catch (error) {
  console.error('Failed to initialize Keycloak:', error)
  state.isInitializing = false
  localStorage.removeItem('kcToken'); localStorage.removeItem('kcRefreshToken')
  state.keycloakInstance = null
- if (state.keycloakInstance) {
-   state.keycloakInstance.login()
- }
+ bumpRedirectCount()   // record the attempt for the breadcrumb; never .login() on a null instance
+ console.warn('[SBDEV-2390] Keycloak init threw; routing to clear error.')
+ window.location.replace('/mobile/unknown-tenant?reason=auth')   // clear error, no reload loop
}
```

This is strictly better than today's silent death: a thrown init now surfaces a clear error page instead of a stuck screen, and it introduces **no** new reload site (no `window.location.reload()` / re-bootstrap on the catch path). The `!authenticated` path (site 2) still uses `guardedLogin(keycloakInstance)` because there the instance is valid — this is the deliberate web/mobile asymmetry (web's catch retains its instance and can reuse `guardedLogin`; mobile's does not).

### Fix E — Ensure "tenant cannot be verified" paths land on a clear error (no loop)

Confirm the `/unknown-tenant` + `/error` skip-guards (`keycloak.client.js:79`, `initTenantAuth.client.js:47`) cover every no-config / authConfig-failure path, resolving under the `/mobile/` base. (Mobile already guards **both** `/unknown-tenant` and `/error` at line 79, so — unlike web — no guard gap exists here.) Add the same one-line `reason=auth` conditional copy to mobile's `pages/unknown-tenant.vue` so an auth/init failure (from Fix B / Fix D) reads "We couldn't verify your session or tenant — please sign in again" instead of a bare "tenant not found."

### Fix F — (RECOMMENDED HARDENING, DEFERRED — not in this ticket's rollout)

Namespace the shared localStorage keys per app (web vs mobile) to remove the Bug 2 collision trigger. Deferred (same rationale as the primary plan): Fix B already guarantees termination; Fix F touches logout + persistedState read paths. Tracked in §12.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| plugins/keycloak.client.js | edit | Fix A (restore check-sso + silent uri), Fix B (loop-breaker + guardedLogin + reset-on-success), Fix D (dead-code catch → guarded clear-error redirect), Fix E (guard audit) |
| pages/unknown-tenant.vue | edit | Fix E (one conditional line: `reason=auth` copy) |
| plugins/initTenantAuth.client.js | edit (defensive) | Fix E (confirm skip-guard coverage under `/mobile/` base) |

No test file — mobile has no Jest/test harness (see §8).

---

## 7. Prerequisites & Implementation Plan

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | Database state | **N/A** — frontend-only. | — | `db_verified: false` |
| 2 | Feature flags / sysprops | **N/A** | — | |
| 3 | Config / env | `static/silent-check-sso.html` resolves under `/mobile/`. | Dev | verify path with router.base |
| 4 | Deploy-order | None; independent of web plan and backend. | — | |
| 5 | Data migration | **N/A** | — | |
| 6 | External systems | Keycloak realm/client reachable (unchanged). | — | |
| 7 | Access / permissions | **N/A** | — | |
| 8 | Monitoring | Optional console breadcrumb when loop-breaker fires. | Dev | non-blocking |

### 7.2 Implementation Checklist

- [ ] Fix A — `onLoad: 'check-sso'` + add `silentCheckSsoRedirectUri` (`/mobile/` base).
- [ ] Fix B — `guardedLogin` + `sessionStorage` counter; route site-2 `login()`; reset on success.
- [ ] Fix D — replace dead-code catch with a guarded clear-error redirect.
- [ ] Fix E — audit `/unknown-tenant` + `/error` skip-guards under `/mobile/`.
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.sh` → `0 fail`.
- [ ] `yarn lint`.
- [ ] Manual QA (§8) on a mobile-sized viewport.
- [ ] Code review completed.

---

## 8. Test Plan

### Unit / Integration

**N/A — mobile has no test suite** (no `yarn test`, no Jest config per `wms2-mobile-ui/CLAUDE.md`). This is a genuine repo constraint, recorded rather than silently skipped. The loop-breaker helper logic is validated **once** in the web plan's Jest unit test (identical helper); the mobile port relies on that plus manual QA. (If the shared helper is later extracted to a common package, promote the web unit test to cover both.)

### Regression

- `verify-…sh` NEGATIVE checks assert `onLoad: 'login-required'` is gone, no un-guarded `keycloakInstance.login()` remains, and the dead-code `if (state.keycloakInstance)`-after-null pattern is gone.

### Manual test plan (primary verification for this repo)

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Happy path — refresh on mobile | staging `/mobile/` | 1. Sign in on a mobile-sized viewport. 2. Load an operation page. 3. Hard-refresh 5×. | Stable load each time; no loop. | |
| Desktop↔mobile bounce | staging (shared origin) | 1. Sign in web `/`. 2. Open `/mobile/`. 3. Back to web PickPack, refresh. 4. Back to `/mobile/`, refresh. | Both surfaces stable; no infinite redirect. | |
| Tenant cannot be verified | staging | Force `authConfig` failure. | Single redirect to `/mobile/unknown-tenant` clear-error; no loop. | |
| Init error path (Fix D) | staging | Force an init exception (bad realm/config). | Lands on a clear error after ≤`MAX_KC_REDIRECTS`; no silent blank screen; no loop. | |
| DevTools capture ("if reproducible") | staging | Console+Network preserve-log: record `Keycloak initialized. Authenticated:` vs `Failed to initialize Keycloak:`; URL hops; `localStorage.tenantKeycloakConfig`/`kcToken` before vs mid-loop. | Confirms trigger; attach to ticket. | |

### Test execution (fill in after running)

| Command | Result | Notes |
|---------|--------|-------|
| `yarn lint` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Automated unit/integration tests | Repo has no test harness (documented constraint). Helper logic covered by the web plan's Jest test; mobile relies on manual QA + verify-script code-shape checks. |

### Pre-mortem (deliberate mode)

1. **`/mobile/` base breaks the silent-sso path** → check-sso can't complete, always `!authenticated`. *Mitigation:* Fix A explicitly sets the `/mobile/`-prefixed `silentCheckSsoRedirectUri`; the "Happy path" manual scenario verifies it.
2. **`window.__keycloakState` persistence interacts with the counter** → counter never resets. *Mitigation:* counter lives in `sessionStorage`, independent of `__keycloakState`; reset-on-success covers it.
3. **Fix D over-redirects on a *transient* init throw** (e.g. a network blip during `keycloak.init()`) — mobile routes to the clear-error page on the **first** occurrence, with **no** retry (unlike web, which retries once via `guardedLogin`). *Mitigation / accepted trade-off:* this is the intentional web↔mobile asymmetry — recovery is via user reload / fresh tab (which resets the per-tab counter). We accept no-retry on `catch` because a *thrown* `init()` is a deterministic failure unlikely to self-heal, and adding a reload-retry here would reintroduce a loop site. The clear-error page is strictly better than today's silent blank screen.

---

## 9. Horizontal Scalability Validation & v2 constraints

### 9.0 Applicability note

Target is **wms2-mobile-ui (Nuxt 2 SPA, `ssr: false`)**, not `wms2-api`. Backend HSV / v2-constraint rows are N/A (no JVM/DB/Spring). Frontend analogs match the primary plan: the redirect counter uses **`sessionStorage` (per-tab)** deliberately to avoid the cross-app `localStorage` collision (Bug 2); tenant context is derived per-load from hostname. Full table identical to primary plan §9 — all backend rows N/A with rationale.

**v2-only constraint checklist (backend-scoped):** all **N/A** (no Java/Spring in this repo).

---

## 10. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Silent-sso path wrong under `/mobile/` base | Medium | Fix A sets the `/mobile/`-prefixed URI; verified by manual "Happy path". |
| No automated test to catch mobile regression | Medium | `verify-…sh` code-shape checks + manual QA; shared helper unit-tested in web plan. |
| Dead-code catch fix changes error UX | Low | Guarded: `login()` below threshold, clear error past it — strictly better than silent death. |
| Bug 2 collision latent (Fix F deferred) | Medium | Loop-breaker terminates regardless; Fix F tracked as follow-up. |
| Fixed on mobile but not web (or vice-versa) | Medium | Ships paired with `SBDEV-2390-web-…`; both share the SSO session. |

---

## 11. Acceptance & Implementation

### 11.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.sh` (`PROJECT_ROOT=…/v2/wms2-mobile-ui`):
- **POSITIVE:** `onLoad: 'check-sso'`; `silentCheckSsoRedirectUri` with `/mobile/`; `sessionStorage` counter + `guardedLogin`; `resetRedirectCount()` on success; catch path calls `bumpRedirectCount()` + `window.location.replace('/mobile/unknown-tenant?reason=auth')`; `pages/unknown-tenant.vue` handles `reason=auth`.
- **NEGATIVE:** `onLoad: 'login-required'` gone; no un-guarded `keycloakInstance.login()`; dead-code `if (state.keycloakInstance)`-after-null gone; **no `window.location.reload()` introduced on the catch path** (loop-safety).

Final acceptance: `Result: N pass, 0 fail`.

### 11.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Size class | **Standard** | 4 fixes, single subsystem |
| Plan-review step | critic | Standard+ |
| Implementation shape | executor | single file mostly |
| Verification step | verify-script + verifier (manual QA for behavior) | no test harness |
| Code-review step | code-reviewer | auth path |
| Commit step | git-master | logical commits |

---

## 12. Notes

- Paired primary plan: `SBDEV-2390-web-pickpack-keycloak-refresh-loop.md`.
- Follow-up (Fix F): namespace shared localStorage keys per app — gate on DevTools capture.
- Consider extracting the loop-breaker helper into a shared module so a single unit test covers both web and mobile.
- After rollout, add the same `project_memory_add_directive` as the web plan (never revert to `login-required` + un-guarded `login()`).
