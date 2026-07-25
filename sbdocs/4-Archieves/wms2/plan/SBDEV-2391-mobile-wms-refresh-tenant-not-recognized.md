---
title: "SBDEV-2391 — Refresh on a valid tenant intermittently shows \"Tenant Not Recognized\" (mobile UI)"
ticket: "SBDEV-2391"
ticket_url: "https://app.clickup.com/t/868jwjyg1"
type: "bugfix"
priority: "High"
status: archived
project: ["wms2-mobile-ui"]
version: "v2"
requester: "Brent Campbell"
created: "2026-07-04"
updated: "2026-07-04"
db_verified: false
related:
  - "SBDEV-2391-wms-refresh-tenant-not-recognized.md"
  - "SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.md"
  - "SBDEV-2390-web-pickpack-keycloak-refresh-loop.md"
tags:
  - plan
  - wms2-mobile-ui
  - keycloak
  - auth
  - tenant-discovery
  - multi-tenant
---

# SBDEV-2391 — Refresh on a valid tenant intermittently shows "Tenant Not Recognized" (mobile UI)

**Ticket:** [SBDEV-2391](https://app.clickup.com/t/868jwjyg1)
**Project:** wms2-mobile-ui | **Version:** v2 | **Type:** bugfix
**Priority:** High
**Status:** implemented (PORT of the consensus-approved web design; Architect SOUND-WITH-CHANGES [M1/M2 folded] → implemented + code-reviewed SHIP-WITH-NITS on 2026-07-04; uncommitted working-tree in `v2/wms2-mobile-ui`, see §12)
**Date:** 2026-07-04

**Paired plan (reference design + shipped reference implementation):** `SBDEV-2391-wms-refresh-tenant-not-recognized.md` (web UI — `implemented`/`SHIP`, PR #7). This mobile plan is a **port** of that already-consensus-approved design (ralplan round 2 → Critic APPROVE). Line numbers, before/after, and the ADR here are all referenced back to the web plan's §12 shipped source (`v2/wms2-web-ui/plugins/tenant-auth-fetch.js`, `plugins/initTenantAuth.client.js`, `plugins/keycloak.client.js`, `pages/unknown-tenant.vue`, `test/plugins/*.spec.js`).

**Sibling plan:** `SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.md` (same tenant-discovery / Keycloak-bootstrap subsystem in `wms2-mobile-ui` — this plan shares its files and MUST NOT regress its fixes; see §6 non-regression and §7 constraint checklist).

**LOCKED USER DECISION (this session): FULL PARITY.** Port Fixes **D + E + B + C + F** to mobile (the full web fix set), not just the latent fixes. **Fix A is a no-op on mobile** (mobile already has `if (!response.ok) throw` and no dead `status === 500` branch — see §2.1). Additionally, **add a minimal Jest harness** so the ported `tenant-auth-fetch.js` helper + a plugin-level `initTenantAuth` spec are unit-testable; the mobile repo currently has **no test runner** (only a Playwright e2e config).

---

## 0. Affected sites (enumeration before drafting)

Enumerated by reading the live mobile source (`v2/wms2-mobile-ui`) — line numbers verified against the on-disk files 2026-07-04, **not** copied from the web plan. Mobile line numbers differ from web.

| # | File:line (MOBILE) | Construct | Root-cause contribution | In-scope this plan? |
|---|-----------|-----------|-------------------------|---------------------|
| 1 | plugins/initTenantAuth.client.js:58-62 | `if (!clientInfo) { … setItem('tenantKeycloakConfig', null); resetWarehouseTimezone(store) }` — **NO `return`**, falls through the `else` and out to the fetch at :86 which dereferences `clientInfo.warehouse` on a `null` `clientInfo` → **TypeError** | **deterministic defect** — a genuinely tenant-less URL throws (caught at :118) instead of short-circuiting | **yes** — Fix D |
| 2 | plugins/initTenantAuth.client.js:86-90 | `const response = await fetch(...)` then `if (!response.ok) throw new Error(...)` at :88 | **Fix A is ALREADY present** on mobile — a 5xx already throws into the catch. There is **no** dead `status === 500` branch to remove. | **no (already-present)** — documented; no re-add |
| 3 | plugins/initTenantAuth.client.js:60, 120 | **exactly two** `localStorage.setItem('tenantKeycloakConfig', null)` sites (no-client / catch). `setItem(key, null)` stores the **string** `"null"`, not JS `null` | contributing — poisons the value the KC plugin reads; see Fix E `'null'`-guard | **yes** — Fix E (rework both sites → `removeItem`) |
| 4 | plugins/initTenantAuth.client.js:67-70 | tenant-change branch: `if (previousClientName && previousClientName !== clientInfo.clientName) { resetWarehouseTimezone(store) }` — **WEAKER than web**: mobile only resets the timezone; it does **NOT** `removeItem` the stale `tenantKeycloakConfig` / `kcToken` on a tenant switch | contributing — for the Fix-E "preserve-only-when-identity-matches" invariant to be sound, the cross-tenant branch must clear stale config/token first (web does this) | **yes** — Fix E (**mobile-only addition**: align this branch to web) |
| 5 | plugins/keycloak.client.js:88-102 | `getKeycloakConfig()` → `if (storedConfig) { JSON.parse … }`. The stored string `"null"` is **truthy** at :90, so `JSON.parse("null")` returns JS `null`; the inner `if (parsed) return parsed` returns `undefined`, so `config` becomes `undefined` at :104 | contributing — the `"null"` string is the poisoned value that makes `config` falsy and triggers the bare redirect | **yes** — Fix E (`'null'`/`'undefined'`/`''`-as-missing guard) |
| 6 | plugins/keycloak.client.js:121-129 | `if (!config) { … window.location.replace('/mobile/unknown-tenant') }` — **bare** redirect (already `/mobile/`-prefixed per SBDEV-2390 Fix E), no `reason`, cannot distinguish "tenant not found" from "backend briefly down" | **primary user-visible symptom** — a transient failure dead-ends on the terminal "Tenant Not Recognized" page with no retry | **yes** — Fix F (flag-aware skip wired into THIS block) |
| 7 | plugins/keycloak.client.js:230 | `window.location.replace('/mobile/unknown-tenant?reason=auth')` (SBDEV-2390 init-throw terminal); also :34 in `kc-redirect-guard.js` guardedLogin loop-breaker | separate cause (KC auth loop, not tenant discovery) | no — **must not regress** (§6); documented as a redirect surface for Fix F arbitration |
| 8 | pages/unknown-tenant.vue:6, 30-37 | `isAuthError()` reads `reason === 'auth'`; page has exactly **two** copy states (auth vs not-found); **no `mounted()` hook** | needs a **third** state for transient/unavailable + a mount-time flag clear | **yes** — Fix C |
| 9 | plugins/tenant-auth-fetch.js | (new) | extracted, Nuxt-free fetch/retry/classification helper | **yes** — Fix B (prerequisite) |
| 10 | jest.config.js / babel config / package.json / test/ | (new) | mobile repo has **no test runner** (no jest, no babel-jest, no `test` script; only Playwright e2e) | **yes** — Jest harness (this port's addition) |

Every **yes** row maps to a POSITIVE (and, where it replaces old code, a NEGATIVE) check in `verify-SBDEV-2391-mobile-wms-refresh-tenant-not-recognized.sh` (§9). Row 2 (Fix A already-present) and row 7 (`?reason=auth`) map to **non-regression** checks.

**Router-base note (`/mobile/`):** every redirect/asset on mobile is under `router.base: '/mobile/'` (`nuxt.config.js:12`). All new redirect targets in this plan use the `/mobile/` prefix (`/mobile/unknown-tenant`, `/mobile/unknown-tenant?reason=unavailable`); silent-check-sso is `/mobile/silent-check-sso.html`; KC `redirectUri` defaults to `window.location.origin + '/mobile'`. A **bare** `/unknown-tenant` resolves **outside** the app base on mobile and would 404 — this plan MUST NOT emit bare `/unknown-tenant`.

---

## 1. Problem Statement

> **`db_verified: false`** — This is a pure frontend tenant-discovery / auth-routing defect (Nuxt 2 / Vue 2 client plugins). No database state is involved and **no DB check is required** before implementation; the DB-verification gate is N/A. Optional non-blocking backend sanity: `GET /api/public/authConfig?key={warehouse}-{client}` returns a Keycloak config for a healthy tenant, and returns a 5xx (or times out / is unreachable) during a backend blip — but the fix does not depend on reproducing that.

**User-visible symptom** (ClickUp SBDEV-2391, reported by Brent Campbell, High):
- A user on a **known-good tenant** refreshes the mobile app (`/mobile/`) and lands on the **"Tenant Not Recognized"** dead-end (`/mobile/unknown-tenant`) even though the tenant exists.
- Recovering requires the user to manually refresh again (sometimes several times); there is no in-app retry.
- Correlated with brief `wms2-api` unavailability (rolling deploy, replica restart, cold-start latency, or a transient network blip) rather than any change to the tenant.

**Root symptom in one line:** a *transient* backend failure during tenant discovery is being reported to the user as a *permanent* "tenant does not exist" error, with no retry and no recovery path.

**Reproduction** (intermittent — timing-dependent):
1. Be on a valid tenant subdomain (e.g. `wh1-acme.wms.example.com`) served under `/mobile/`, authenticated and working.
2. During a `wms2-api` rolling restart / brief outage / cold start, refresh the page (or the cold boot re-runs the tenant-discovery fetch).
3. `GET /api/public/authConfig?key={warehouse}-{client}` returns 5xx, times out, or the connection is refused.
4. **Expected:** a brief "temporarily unavailable, retrying…" experience that self-heals, or at worst a *recoverable* page with a Retry action.
5. **Actual:** the fetch throws (5xx) or rejects (network) → catch at :118 sets `tenantKeycloakConfig` to the string `"null"` → `keycloak.client.js` reads it as no-config → the app hard-redirects to the terminal **`/mobile/unknown-tenant`** page — the same page shown for a genuinely non-existent tenant.

---

## 2. Root Cause Analysis

The tenant-discovery bootstrap runs in `plugins/initTenantAuth.client.js` (loaded before `keycloak.client.js` — see mobile CLAUDE.md plugin order: `axios → initTenantAuth.client → keycloak.client → persistedState.client → cookie`). On mobile the defects are a **subset** of the web defects (Fix A is already present); the remaining ones combine so that a *transient* failure is misclassified as a *permanent* "no tenant".

### 2.1 Fix A is ALREADY present on mobile (no dead 5xx branch)

At **initTenantAuth.client.js:86-90**:

```js
const response = await fetch(`${BASE_URL}/api/public/authConfig?key=${clientInfo.warehouse}-${clientInfo.clientName}`)

if (!response.ok) {
    throw new Error(`Auth config fetch failed: ${response.statusText}`)   // :88 — ALREADY correct
}
```

- Unlike the web (which had a **dead** `if (tenantConfig.status === 500)` branch that never fired because `fetch` doesn't reject on 5xx and the body has no `status` field), mobile **already** guards on `!response.ok` and throws on any non-2xx.
- So the web plan's **Fix A** ("replace the dead `status===500` guard with real HTTP-status handling") is a **no-op on mobile**: there is nothing to remove. The `!response.ok` throw is retained.
- **BUT** the throw funnels *both* transient (5xx, network) *and* permanent (404) failures into the **same** catch at :118, which nulls the config and lets `keycloak.client.js` dead-end at `/mobile/unknown-tenant`. The transient-vs-permanent distinction (the actual bug) is still missing — that is what **Fix B** (the classified retry helper) supplies, replacing the raw `fetch` + `!response.ok throw` with a call into `fetchAuthConfig`.

### 2.2 `!clientInfo` falls through into the fetch (deterministic defect — Fix D)

At **initTenantAuth.client.js:58-62**:

```js
if (!clientInfo) {
  console.log('No client found in URL or localStorage, using default config')
  localStorage.setItem('tenantKeycloakConfig', null)   // :60
  resetWarehouseTimezone(store)
  // <-- NO return here; falls out of the if/else
} else {
  // … tenant-change branch + store the client info …
}
// falls through to :86
const response = await fetch(`${BASE_URL}/api/public/authConfig?key=${clientInfo.warehouse}-${clientInfo.clientName}`)
```

- There is **no `return`** after the no-client branch. Execution falls through the `else` to the fetch at :86, which dereferences `clientInfo.warehouse` / `clientInfo.clientName` on a `null` `clientInfo` → **`TypeError`** → caught at :118 → config nulled (string `"null"`). A genuinely tenant-less URL therefore throws instead of cleanly short-circuiting to the not-found page. Same defect as web.

### 2.3 `setItem(key, null)` stores the string `"null"`, which the reader treats as present (contributing — Fix E)

- At **initTenantAuth.client.js:60 and :120**, `localStorage.setItem('tenantKeycloakConfig', null)` coerces `null` to the **string** `"null"`. (Two sites on mobile, vs three on web — mobile has no dead-500 branch, so no third site.)
- At **keycloak.client.js:88-102**, `getKeycloakConfig()` does `const storedConfig = localStorage.getItem('tenantKeycloakConfig'); if (storedConfig) {`. The string `"null"` is **truthy**, so it enters the `try`, `JSON.parse("null")` returns JS `null`, the inner `if (parsed) return parsed` is skipped, and the function returns `undefined`. `config` at :104 is `undefined`.
- At **keycloak.client.js:121-129**, `if (!config)` fires the **bare** `window.location.replace('/mobile/unknown-tenant')` — the terminal dead-end. The reader cannot tell a transient failure from a real "no tenant".

### 2.4 The mobile tenant-change branch is WEAKER than web (Fix E dependency — mobile-only addition)

At **initTenantAuth.client.js:64-70**, the mobile tenant-change branch is:

```js
const previousClientName = localStorage.getItem('clientName')
if (previousClientName && previousClientName !== clientInfo.clientName) {
  resetWarehouseTimezone(store)   // <-- ONLY resets timezone
}
```

Compare the **web** shipped source (`v2/wms2-web-ui/plugins/initTenantAuth.client.js:112-120`):

```js
if (previousClientName && previousClientName !== clientInfo.clientName) {
  localStorage.removeItem('kcToken')                 // <-- also clears stale token
  localStorage.removeItem('tenantKeycloakConfig')    // <-- also clears stale config
  resetWarehouseTimezone(store)
}
```

- Mobile does **NOT** `removeItem` the stale `tenantKeycloakConfig` / `kcToken` on a tenant switch. Its own §2.4 web-derivation ("cross-tenant navigation has already wiped the stored config, so same-tenant is the only case where a stored config survives to the preserve path") **does not hold on mobile as-is** — a tenant switch leaves tenant A's config in `localStorage`.
- For the **Fix E preserve-invariant** ("preserve stored config on a transient blip ONLY when identity matches") to be sound on mobile, the cross-tenant branch MUST first clear the stale config/token — otherwise a same-`clientName` warehouse switch, or any partially-applied clear, could leave A's config preservable/bootable for a B request. This plan therefore **aligns the mobile tenant-change branch to web** (add the two `removeItem`s + persist `warehouseCode`) as an explicit **mobile-only addition** folded into Fix E.

### 2.5 Interaction with SBDEV-2390

The SBDEV-2390 mobile wiring lives in `keycloak.client.js` + `kc-redirect-guard.js`: `guardedLogin` (`:178`), `resetRedirectCount` (`:185`), `bumpRedirectCount` + `?reason=auth` init-throw terminal (`:228-230`), the `/mobile/`-prefixed clear-error targets, and `onLoad: 'check-sso'` (`:154-156`). None of these are tenant-discovery redirects; all are preserved intact (§6 non-regression). Fix F's flag-aware skip is added to the **`!config`** bare-redirect block at `:121-129` ONLY — the `?reason=auth` surfaces at `:230` / guard `:34` are left untouched.

### Affected Locations (mobile)

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | plugins/initTenantAuth.client.js | 58-62 | `!clientInfo` branch has no `return`; falls through into the fetch (Fix D) |
| 2 | plugins/initTenantAuth.client.js | 86-90 | fetch has correct `!response.ok` throw (**Fix A already present**); replaced by helper call (Fix B) — both transient & permanent still funnel to the same catch |
| 3 | plugins/initTenantAuth.client.js | 60, 120 | two `setItem('tenantKeycloakConfig', null)` sites — string `"null"` poisoning (Fix E rework → removeItem) |
| 4 | plugins/initTenantAuth.client.js | 64-70 | tenant-change branch resets tz only; missing stale config/token removeItem (Fix E mobile-only addition) |
| 5 | plugins/initTenantAuth.client.js | 118-124 | catch nulls config, no transient/permanent distinction, no retry (Fix B) |
| 6 | plugins/keycloak.client.js | 88-102 | `getKeycloakConfig()` treats string `"null"` as present (Fix E `'null'`-guard) |
| 7 | plugins/keycloak.client.js | 121-129 | bare `/mobile/unknown-tenant` redirect, not `reason`-aware (Fix F) |
| 8 | pages/unknown-tenant.vue | 6, 30-37 | only two copy states (auth / not-found); no `mounted()`; needs recoverable `unavailable` + mount clear (Fix C) |
| 9 | plugins/tenant-auth-fetch.js | (new) | extracted, Nuxt-free fetch/retry/classification helper (Fix B, prerequisite) |
| 10 | jest.config.js, babel config, package.json, test/plugins/* | (new) | Jest harness — mobile repo has no test runner today |

---

## 3. Design / Proposed Fix

Locked UX decisions carried from the web design (ralplan round 1 → round 2):
- **R1** — distinguish *transient* (retryable) from *permanent* (tenant not found) failures.
- **R2** — on a transient failure, perform a **bounded** in-plugin retry, then route to a **recoverable** page (`?reason=unavailable`) with a Retry action, rather than the terminal dead-end.

Fixes **B + C + D + E + F** (Fix A is a mobile no-op, §2.1). Fix B is delivered via a **new extracted helper** so the fetch/retry/classification logic is unit-testable without booting Nuxt. Ported near-verbatim from the shipped web helper; the only deltas are (a) the redirect targets carry the `/mobile/` base and (b) the config maps `mobileRedirectUrl` (not web's `webRedirectUrl`) for `redirectUri`.

### 3.1 Fix A — already present (no change)

Mobile already throws on `!response.ok` (§2.1). No dead branch to remove. The Fix B helper subsumes the raw fetch + throw and adds the transient/permanent classification the throw lacks.

### 3.2 Fix B — extracted, bounded, Nuxt-free retry helper (`plugins/tenant-auth-fetch.js`)

New module `plugins/tenant-auth-fetch.js`, ported from the shipped web helper (`v2/wms2-web-ui/plugins/tenant-auth-fetch.js`), module-scope exports (mirroring `kc-redirect-guard.js`) so Jest can import it without booting Nuxt.

- Constants: `MAX_ATTEMPTS = 3`, `TIMEOUT_MS = 5000`, `BACKOFF_MS = 300`, `DISCOVERY_REDIRECT_KEY = 'tenantDiscoveryRedirect'`.
- `fetchAuthConfig(baseUrl, key)`: `AbortController` per attempt (enforces `TIMEOUT_MS`); linear `BACKOFF_MS` between attempts; **retry policy (explicit)** — retries on **5xx**, **network errors**, and **its OWN `AbortController` timeout**; does **NOT** retry on `4xx` (a `404` is surfaced immediately as permanent). Bounded by the `MAX_ATTEMPTS` hard cap so a rapid-refresh burst cannot amplify into a request storm (§7 concern row 2). Clears `DISCOVERY_REDIRECT_KEY` unconditionally at the start of every run (Fix F).
- **Config mapping delta (mobile):** the success result maps `redirectUri: body.mobileRedirectUrl` (web used `body.webRedirectUrl`). All other fields (`url`←`authServerUrl`, `realm`, `clientId`, `timezone`) match web. This mirrors the current mobile plugin's `:101` `redirectUri: tenantConfig.mobileRedirectUrl`.
- Returns a discriminated result: `{ ok: true, config }` | `{ ok: false, reason: 'notfound' }` | `{ ok: false, reason: 'unavailable' }`.
- Also exports `shouldPreserveStoredConfig(resolvedClientName, resolvedWarehouse, storedClientName, storedWarehouse)` (identity match, Fix E/C1), `classifyRedirect(outcomeKind)` (**mobile: returns `/mobile/unknown-tenant?reason=unavailable` or bare `/mobile/unknown-tenant`** — the web helper returned the un-prefixed forms), and `isMissingConfig(stored)` (`'null'`/`'undefined'`/`''`-as-missing, Fix E).

### 3.3 Fix C — recoverable page + retry action (`pages/unknown-tenant.vue`)

- Add `isUnavailable` computed (`this.$route.query.reason === 'unavailable'`) as a third copy state ("Couldn't Reach SiteBoss OWL" + "usually temporary, try again in a moment"), plus a Retry button, same as the shipped web page.
- **Retry re-runs the cold boot on the ORIGINAL URL/path** via `window.location.reload()` — **NOT** `window.location.replace('/mobile/')`. `extractClientFromUrl()` reads `window.location.href`, so reloading preserves the tenant subdomain and deep link.
- **`mounted()` clear (MANDATORY):** the page is currently a **computed-only SFC with no `mounted()` hook**. The executor MUST **ADD** a `mounted()` hook that unconditionally calls `sessionStorage.removeItem(DISCOVERY_REDIRECT_KEY)` as its first action (imported from `@/plugins/tenant-auth-fetch`). Second unconditional clear point of the Fix F flag lifecycle.
- The `isAuthError` state (SBDEV-2390) is **preserved** (§6 non-regression).

### 3.4 Fix D — short-circuit the no-client branch

- Add a `return` (route to bare `/mobile/unknown-tenant` via the Fix F arbiter) at the end of the `!clientInfo` branch (:58-62) **before** the fetch, so a tenant-less URL never dereferences `null` and never throws into the catch.
- Before routing, the no-client path MUST set `sessionStorage.setItem(DISCOVERY_REDIRECT_KEY, 'notfound')` (via the arbiter) — `initTenantAuth` is the **sole writer** of the flag and always sets it before any tenant-discovery redirect (§3.6). `'notfound'` reflects that a missing client in the URL is permanent.

### 3.5 Fix E — wrong-tenant realm-boot guard + `'null'`-as-missing reader guard + mobile tenant-change alignment

**Reader guard (keycloak.client.js:88-102):** `getKeycloakConfig()` treats the literal strings `'null'`, `'undefined'`, and `''` as **missing** by delegating to the shared `isMissingConfig` from `tenant-auth-fetch.js` (single source of truth, matching the web refactor). Belt-and-suspenders while the writers migrate to `removeItem`.

**Preserve-invariant (the C1 correctness rule):** On a **transient** failure, Fix E may preserve the previously-stored `tenantKeycloakConfig` **ONLY when the resolved identity (`clientName` + `warehouse`) matches the stored identity** (compare against the pre-overwrite `previousClientName`/`previousWarehouse`). On **ANY mismatch**, do **NOT** boot the stored config — `removeItem` + route to recovery. Booting tenant A's realm/clientId for a tenant-B user would be a silent cross-tenant auth defect (wrong realm), worse than the dead-end this plan fixes.

**Mobile-only addition — align the tenant-change branch to web (§2.4):** In the `previousClientName && previousClientName !== clientInfo.clientName` branch (:67-70), ADD `localStorage.removeItem('kcToken')` and `localStorage.removeItem('tenantKeycloakConfig')` alongside the existing `resetWarehouseTimezone(store)`. Also persist `localStorage.setItem('warehouseCode', clientInfo.warehouse)` next to the existing `setItem('clientName', …)` so the identity check can compare **both** halves (clientName + warehouse). Without this, the mobile preserve path is unsound (a stale cross-tenant config survives). This addition brings mobile to parity with the shipped web source (`initTenantAuth.client.js:110-129`).

**Files changed:** `plugins/initTenantAuth.client.js`, `plugins/keycloak.client.js`, `plugins/tenant-auth-fetch.js` (new), `pages/unknown-tenant.vue`.

### 3.6 Fix F — single-writer redirect discipline (arbitration rule)

There are **three** tenant-error redirect surfaces on mobile:
- `keycloak.client.js:127` — bare `/mobile/unknown-tenant` (no-config).
- `keycloak.client.js:230` — `/mobile/unknown-tenant?reason=auth` (SBDEV-2390 init-throw terminal); `kc-redirect-guard.js:34` — same `?reason=auth` (loop-breaker).
- `initTenantAuth`'s new `/mobile/unknown-tenant?reason=unavailable` / bare not-found (Fix B/D).

**Rule:** `initTenantAuth` is the **SOLE writer of the tenant-discovery redirect reason**. It owns `404 → bare /mobile/unknown-tenant` and `transient → /mobile/unknown-tenant?reason=unavailable`. Before **any** tenant-discovery redirect it sets a **sessionStorage** flag `DISCOVERY_REDIRECT_KEY` = `'notfound' | 'unavailable'` (mirroring `kc-redirect-guard.js`'s sessionStorage pattern). The `redirectTenantDiscovery(outcomeKind)` helper wraps the `sessionStorage.setItem` in a try/catch (SecurityError-defensive) and then `window.location.replace(classifyRedirect(outcomeKind))` — ported from the shipped web `initTenantAuth`, with `classifyRedirect` returning `/mobile/`-prefixed targets.

- **sessionStorage, not a module var:** the redirect tears the page down; a module-scoped variable would not survive. sessionStorage survives the tearing-down page, is tab-scoped, and clears on tab close (same rationale as SBDEV-2390's `kcRedirectAttempts`).
- **`keycloak.client.js:121-129`'s bare redirect becomes reason-aware:** if `DISCOVERY_REDIRECT_KEY` is already set in-flight (read via `sessionStorage.getItem`), `keycloak.client.js` **skips its own bare redirect** (so a cross-load race cannot *downgrade* an in-flight `?reason=unavailable` to the terminal bare dead-end). The `?reason=auth` surfaces (`:230`, guard `:34`) are a **separate** concern (KC auth, not tenant discovery) and are left intact (§6).
- **Flag clear-lifecycle (MANDATORY — two unconditional clear points):**
  **(a)** `pages/unknown-tenant.vue` clears the flag in a **newly-added** `mounted()` hook (`sessionStorage.removeItem(DISCOVERY_REDIRECT_KEY)`) as its first lifecycle action.
  **(b)** `initTenantAuth` clears the flag **unconditionally at the very start of every discovery run** (and `fetchAuthConfig` also clears it at its own start), before the fetch — mirroring SBDEV-2390's unconditional `resetRedirectCount()`. Every successful run wipes any flag set by a prior failed run.
  **Invariant:** the flag is written **ONLY** immediately before a tenant-discovery redirect (by `initTenantAuth`, the sole writer) and cleared unconditionally (a) at run-start and (b) on `unknown-tenant.vue` mount. It can never survive a successful run and mask a later genuine not-found.

---

## 4. V1/V2 Applicability

v2-only. The v1 mobile stack (`v1/wms-mobile-ui`) has a different (pre-per-tenant-discovery) bootstrap and is out of scope. This plan is itself the **v2 mobile port of the v2 web plan** — no v1 porting required.

| Aspect | V1 mobile | V2 mobile | Impact |
|--------|----|----|--------|
| Tenant-discovery plugin | different bootstrap | `initTenantAuth.client.js` (per-tenant authConfig) | v2-only defect |
| authConfig endpoint | n/a in this form | `GET /api/public/authConfig` | v2-only |
| Router base | (varies) | `/mobile/` | redirect targets must be `/mobile/`-prefixed |

### What Does NOT Need Porting
- All of B–F — v1 mobile does not have this `authConfig`-driven per-tenant discovery flow. Fix A is a no-op on v2 mobile (already present).

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | N/A | — | Pure frontend defect; no schema/rows involved (`db_verified: false`). |
| 2 | **Feature flags / system properties** | N/A | — | No toggles. |
| 3 | **Config / env changes** | N/A | — | Uses existing `app.$config.axios.baseURL`. |
| 4 | **Deploy-order dependencies** | N/A | — | Client-bundle-only; no backend contract change (relies on existing `authConfig` 404-vs-5xx semantics). |
| 5 | **Data migration** | N/A | — | None. |
| 6 | **External systems** | `GET /api/public/authConfig?key={warehouse}-{client}` returns a config for a valid tenant and `404` for an unknown one | — | Confirm the endpoint returns **404** (not 200-with-error-body / 5xx) for a genuinely unknown tenant so Fix B's permanent/transient split is correct. Same open question as the web plan (§10). |
| 7 | **Access / permissions** | N/A | — | Endpoint is `/api/public/*`, unauthenticated. |
| 8 | **Test runner (NEW for mobile)** | add jest + babel-jest + vue-jest + @vue/test-utils + a `test` script + a babel config | — | Mobile repo has **no** test runner today. This is a **reviewable decision** — see §9 risk. CI has **no test stage** (mobile CLAUDE.md §CI/CD) — tests run **locally only** unless `.gitlab-ci.yml` is updated; that CI change is **OUT of scope** for this plan (note only). |
| 9 | **Monitoring / alerts** | N/A (optional) | — | Optional: a client-side log/metric on `reason=unavailable` renders would help correlate with backend blips, but not required. |

### 5.2 Implementation Checklist (ordered, atomic)

- [ ] **Step 0 (Jest harness — do first, enables the test gate):** Add the mobile test runner. Create `jest.config.js` (jsdom env; `moduleNameMapper` `^@/(.*)$` and `^~/(.*)$` → `<rootDir>/$1`, `^vue$` → `vue/dist/vue.common.js`; `transform` `^.+\.js$` → `babel-jest`, `.*\.vue$` → `vue-jest`; `transformIgnorePatterns` allowing `keycloak-js` ESM per `build.transpile`; `testEnvironment: 'jsdom'`). Add a babel config (`.babelrc` with the `env.test` `@babel/preset-env` `targets.node: current` preset — copy the web `.babelrc`). Add devDependencies matching web's pinned versions (§6 table). Add `"test": "jest"` to `package.json` scripts. Run `yarn install`. **Gate:** `yarn test` runs (even with zero specs) without a config error.
- [ ] **Step 1 (Fix B — prerequisite helper):** Create `plugins/tenant-auth-fetch.js` ported from the shipped web helper, with the two mobile deltas: `classifyRedirect` returns `/mobile/`-prefixed targets, and the success mapping uses `body.mobileRedirectUrl` for `redirectUri`. Export `fetchAuthConfig`, `shouldPreserveStoredConfig`, `classifyRedirect`, `isMissingConfig`, `MAX_ATTEMPTS`, `TIMEOUT_MS`, `BACKOFF_MS`, `DISCOVERY_REDIRECT_KEY`.
- [ ] **Step 2 (Fix D):** Add a `return` (via the Fix F arbiter → bare `/mobile/unknown-tenant`, flag `'notfound'`) at the end of the `!clientInfo` branch (:58-62), before the fetch. Convert its `setItem('tenantKeycloakConfig', null)` → `removeItem`.
- [ ] **Step 3 (Fix B wiring):** Replace the raw `fetch` + `!response.ok throw` (:86-90) and the config-mapping block (:96-105) with a call into `fetchAuthConfig(BASE_URL, key)`. Map `notfound → removeItem + bare /mobile/unknown-tenant`; `unavailable → removeItem (or same-tenant preserve per Fix E) + ?reason=unavailable`; `ok → setItem(JSON.stringify(config))`. Keep the catch as a defensive `unavailable` recovery (ported from web). Convert the catch-path `setItem('tenantKeycloakConfig', null)` (:120) → `removeItem`.
- [ ] **Step 4 (Fix E):**
  - Add the `isMissingConfig`-based `'null'`/`'undefined'`/`''`-as-missing guard in `getKeycloakConfig()` (keycloak.client.js:88-102), importing `isMissingConfig` from `./tenant-auth-fetch`.
  - Add the same-tenant identity check on the transient preserve path in initTenantAuth (capture `previousClientName`/`previousWarehouse` **before** the overwrite; compare via `shouldPreserveStoredConfig`; mismatch → do not preserve/boot, clear + recover).
  - **Mobile-only addition (§2.4):** in the tenant-change branch (:67-70) ADD `localStorage.removeItem('kcToken')` + `localStorage.removeItem('tenantKeycloakConfig')`; persist `localStorage.setItem('warehouseCode', clientInfo.warehouse)`.
- [ ] **Step 5 (Fix F):** Add the `DISCOVERY_REDIRECT_KEY` sessionStorage flag + the `redirectTenantDiscovery(outcomeKind)` arbiter (try/catch-wrapped setItem then `window.location.replace(classifyRedirect(...))`). Make `initTenantAuth` the sole writer. **Unconditionally `sessionStorage.removeItem(DISCOVERY_REDIRECT_KEY)` at the very start of every run**, before the fetch. Make `keycloak.client.js:121-129` skip its bare redirect when the flag is set in-flight (read via `sessionStorage.getItem`, gated on `process.client`). Leave `?reason=auth` (:230, guard :34) untouched.
  - ⚠️ **DO NOT change the `route.path === '/unknown-tenant'` guards** at `initTenantAuth.client.js:47` and `keycloak.client.js:80`. Nuxt `route.path` is **base-stripped** — under `router.base: '/mobile/'` the path on the recovery page is still `'/unknown-tenant'`, so these guards must stay **bare**. Only `window.location.replace(...)` targets carry the `/mobile/` prefix. Rewriting a guard to `'/mobile/unknown-tenant'` would make it never match and reintroduce the SBDEV-2390 loop. (The Fix C `mounted()` flag-clear does not depend on these guards — it runs whenever the page renders.)
- [ ] **Step 6 (Fix C):** Add `isUnavailable` computed + Retry button (`window.location.reload()`) to `pages/unknown-tenant.vue`. **ADD a `mounted()` hook** (page currently has none) containing `sessionStorage.removeItem(DISCOVERY_REDIRECT_KEY)` as its first line. Preserve `isAuthError`.
- [ ] **Step 7 (tests):** Port `test/plugins/tenant-auth-fetch.spec.js` + `test/plugins/initTenantAuth.spec.js` from web, adapting redirect targets to `/mobile/` and the config field to `mobileRedirectUrl`. The 12 named methods + the plugin-level behavioral tests (§8).
- [ ] `yarn test` → all SBDEV-2391 specs green; `bash sbdocs/9-System/scripts/verify-SBDEV-2391-mobile-wms-refresh-tenant-not-recognized.sh` → 0 fail.
- [ ] Code review completed (test-runner introduction + auth-adjacent + cross-tenant C1).

---

## 6. Test Plan

Mobile has **no test runner today** — this port ADDS Jest (Step 0). Once added, the ported specs are the behavioral gate; the verify script (§9) is the shape gate.

### Jest harness — exactly what to add

| Item | Value (match web) | Notes |
|------|-------------------|-------|
| `jest.config.js` | jsdom env; `moduleNameMapper` `^@/(.*)$`+`^~/(.*)$`→`<rootDir>/$1`, `^vue$`→`vue/dist/vue.common.js`; `transform` `^.+\.js$`→`babel-jest`, `.*\.vue$`→`vue-jest`; `moduleFileExtensions: ['js','vue','json']`; `testEnvironment: 'jsdom'` | **`transformIgnorePatterns` is defensive-only — NOT required** (review-verified: the shipped web suite runs green with **no** `transformIgnorePatterns`). The ported specs import only the Nuxt-free helper (`tenant-auth-fetch.js`) and invoke `initTenantAuth.client.js`, which does **not** import keycloak-js — only `keycloak.client.js` does, and no spec imports it. Keep `transformIgnorePatterns: ['node_modules/(?!(keycloak-js)/)']` for margin or omit it; either runs clean. |
| babel config | `.babelrc` — `env.test.presets = [['@babel/preset-env', { targets: { node: 'current' } }]]` (copy web) | Enables ESM `import`/`export` under Jest. |
| `package.json` scripts | add `"test": "jest"` | |
| devDependencies (add) | `jest ^27.4.4`, `babel-jest ^27.4.4`, `babel-core 7.0.0-bridge.0`, `@babel/preset-env` (transitive of babel-jest; add explicit if resolution fails), `vue-jest ^3.0.4`, `@vue/test-utils ^1.3.0` | Versions pinned to match the web repo's working set (web `package.json` devDependencies). `@babel/preset-env` is referenced by `.babelrc`; add it explicitly if not pulled in. |
| `test/plugins/` | `tenant-auth-fetch.spec.js`, `initTenantAuth.spec.js` (ported) | |

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Valid tenant, healthy backend | cold boot on valid `/mobile/` subdomain | success, config stored, KC boots |
| Valid tenant, 5xx blip | authConfig returns 5xx `MAX_ATTEMPTS` times | route to `/mobile/unknown-tenant?reason=unavailable`, never bare dead-end |
| Valid tenant, 5xx then recovers | 5xx on attempt 1, 200 on attempt 2 | success, config stored, no redirect |
| Unknown tenant | authConfig returns 404 | bare `/mobile/unknown-tenant` (not-found copy), no retry |
| No client in URL | tenant-less URL | short-circuit to bare `/mobile/unknown-tenant`, no fetch (Fix D) |
| Wrong-tenant-after-switch + transient | stored clientName=A, URL resolves clientName=B, transient on B | route to `?reason=unavailable`; **must NOT** retain/boot A's config (AC7) |

### New tests (ported from web, adapted to `/mobile/` + `mobileRedirectUrl`)

Test file `test/plugins/tenant-auth-fetch.spec.js` (imports `plugins/tenant-auth-fetch.js` directly — no Nuxt boot):

| # | Test method | What it asserts |
|---|-------------|-----------------|
| 1 | `retries_5xx_up_to_max_attempts_then_unavailable` | 5xx `MAX_ATTEMPTS` times → `{ok:false, reason:'unavailable'}`; exactly `MAX_ATTEMPTS` fetch calls (bounded — no storm) |
| 2 | `returns_notfound_on_404_without_retry` | `404` → `{ok:false, reason:'notfound'}`; exactly **one** fetch call |
| 3 | `aborts_and_retries_on_timeout` | attempt exceeding `TIMEOUT_MS` aborts via `AbortController`, counts as a retryable attempt, bounded by `MAX_ATTEMPTS` |
| 4 | `succeeds_on_first_ok_response` | `response.ok` → `{ok:true, config}`; **`redirectUri` mapped from `body.mobileRedirectUrl`** (mobile delta) |
| 5 | `recovers_after_transient_then_ok` | 5xx on attempt 1, 200 on attempt 2 → `{ok:true, config}` |
| 6 | `no_client_short_circuits_without_fetch` | `classifyRedirect('notfound')` → **`/mobile/unknown-tenant`** (mobile delta); no fetch on the no-client path (Fix D) |
| 7 | `wrong_tenant_after_switch_transient_does_not_boot_stored_config` | stored A, resolved B → `shouldPreserveStoredConfig` false (AC7 / C1) |
| 8 | `same_tenant_transient_may_preserve_stored_config` | stored A, resolved A → `shouldPreserveStoredConfig` true (C1) |
| 8b | `same_client_different_warehouse_transient_does_not_boot_stored_config` | same clientName, different warehouse → false (Fix E identity both-halves) |
| 9 | `transient_lands_on_reason_unavailable_never_bare_unknown_tenant` | `classifyRedirect('unavailable')` → **`/mobile/unknown-tenant?reason=unavailable`**, never bare (mobile delta / C2 / Fix F) |
| 10 | `null_string_treated_as_missing_config` | `isMissingConfig('null'/'undefined'/'')` → true; a JSON config → false (Fix E reader guard) |
| 11 | `sbdev2390_guardedLogin_non_regression` | `guardedLogin` still redirects **`/mobile/unknown-tenant?reason=auth`** after `MAX_KC_REDIRECTS`; `resetRedirectCount` clears the counter (SBDEV-2390 not regressed; **imports from mobile `kc-redirect-guard.js`**) |
| 12 | `stale_discovery_flag_cleared_on_success_does_not_mask_later_notfound` | set flag → successful `fetchAuthConfig` clears it → later `classifyRedirect('notfound')` reaches bare `/mobile/unknown-tenant` (AC8) |

Test file `test/plugins/initTenantAuth.spec.js` (invokes the plugin default export with a mocked Nuxt context — catches the runtime-wiring class of bug, e.g. an unimported `DISCOVERY_REDIRECT_KEY`):

| Test method | What it asserts |
|-------------|-----------------|
| `notfound_404_sets_flag_and_replaces_bare_mobile_unknown_tenant` | 404 → flag `'notfound'` + `window.location.replace('/mobile/unknown-tenant')` |
| `transient_5xx_sets_flag_unavailable_and_replaces_reason_unavailable` | persistent 5xx → flag `'unavailable'` + `replace('/mobile/unknown-tenant?reason=unavailable')` |
| `no_client_fix_d_sets_flag_notfound_and_bare_redirect_before_any_fetch` | tenant-less host → **zero** fetches + flag `'notfound'` + `replace('/mobile/unknown-tenant')` |

### Manual test plan (mobile viewport)

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| 1 | Happy path | staging | Cold-load a valid tenant subdomain in a mobile-sized viewport (`/mobile/`) | Loads normally, no redirect | |
| 2 | Transient blip → recoverable | staging | Restart wms2-api / block authConfig, refresh valid tenant | `/mobile/unknown-tenant?reason=unavailable` recoverable page + Retry; Retry after backend up → app loads | |
| 3 | Retry preserves deep link | staging | On `?reason=unavailable` reached from a deep-linked `/mobile/<op>` path, click Retry | Reloads the ORIGINAL `/mobile/` deep-linked URL (not `/mobile/`), tenant subdomain preserved | |
| 4 | Genuine unknown tenant | staging | Load a non-existent tenant subdomain (authConfig 404) | Bare "Tenant Not Recognized" (not-found copy), no retry loop | |
| 5 | Wrong-tenant-after-switch | staging | Auth on tenant A, navigate to tenant B while B's authConfig blips | Routes to `?reason=unavailable`; does NOT silently boot tenant A's realm | |
| 6 | SBDEV-2390 non-regression | staging | Reproduce SBDEV-2390 KC-loop conditions | Loop-breaker still terminates at `/mobile/unknown-tenant?reason=auth`; no new tenant-discovery interference | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `yarn test --testPathPattern=tenant-auth-fetch` | | |
| `yarn test --testPathPattern=initTenantAuth` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2391-mobile-wms-refresh-tenant-not-recognized.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Backend `authConfig` 404-vs-5xx behavior | Backend contract; validated by prerequisite §5.1 row 6, not this frontend plan |
| CI test stage wiring (`.gitlab-ci.yml`) | Out of scope (mobile CI has no test stage); tests run locally only — noted in §9 risk |

---

## 7. Horizontal Scalability Validation (v2 plan)

> This is a **frontend** change (client bundle). The HSV table proves the change does not create a client-driven scaling hazard against the multi-replica `wms2-api`. Backend/Java-specific rows are **N/A** (this is a Nuxt/Vue client-only change).

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | In-JVM state | introduce backend in-JVM state? | No (N/A — frontend) | Client-only; sessionStorage flag is per-browser-tab. |
| 2 | Connection pool math / **request amplification** | change per-client request volume against wms2-api? | **Yes** | Adds a bounded retry (`MAX_ATTEMPTS=3`, `TIMEOUT_MS=5000`, linear `BACKOFF_MS=300`). The hard `MAX_ATTEMPTS` cap + per-attempt `AbortController` timeout bound the burst so a rapid-refresh storm cannot amplify across replicas. No retry on 4xx. **This is the mitigation for the retry-storm bound.** |
| 3 | Scheduled jobs | add a `@Scheduled`/cron job? | No (N/A — frontend) | Frontend. |
| 4 | Long transactions | hold a DB transaction? | No (N/A — frontend) | Frontend. |
| 5 | Request affinity | assume same-replica follow-up? | No | authConfig is stateless/public; any replica serves it. |
| 6 | Retry / idempotency | rely on single-execution semantics? | **Yes** | authConfig is a **read** (GET, idempotent); retrying is safe. Bounded by `MAX_ATTEMPTS`. |
| 7 | Tenant context | use ThreadLocal across async? | No (N/A — frontend) | Frontend. |
| 8 | Distributed lock correctness | rely on cross-replica locks? | No (N/A — frontend) | Frontend. |
| 9 | Cache invalidation | write to a cached entity? | No (N/A — frontend) | Frontend. |
| 10 | External notifications | send HTTP inside a transaction? | No (N/A — frontend) | Frontend. |

### v2 constraint checklist

| Constraint | Status | Note |
|---|---|---|
| No JPA association annotations | N/A | Java-backend constraint; frontend change. |
| Entity comparison by ID not `.equals()` | N/A | Java-backend constraint. |
| Mockito 3.3.3 no `mockStatic()` | N/A | Java-backend constraint; this uses Jest. |
| Retry storm bound | **PASS** | `MAX_ATTEMPTS=3` hard cap + `AbortController` timeout; asserted by test `retries_5xx_up_to_max_attempts_then_unavailable` (exactly `MAX_ATTEMPTS` calls). |
| SBDEV-2390 non-regression | **PASS (verified)** | §6 test #11 + §9 NR checks. |

### Evidence (for "Yes" rows)

| Concern # | What was done / verified | File:line or test reference |
|-----------|--------------------------|------------------------------|
| 2 | `MAX_ATTEMPTS` hard cap + `AbortController` timeout bound the request burst | `plugins/tenant-auth-fetch.js`; test `retries_5xx_up_to_max_attempts_then_unavailable` asserts exactly `MAX_ATTEMPTS` calls |
| 6 | GET is idempotent; retry is safe | `plugins/tenant-auth-fetch.js` |

---

## 8. Acceptance Criteria & Named Tests

### Acceptance criteria (adapted for mobile)

- **AC1** — On a valid tenant with a healthy backend, cold boot resolves the config and boots Keycloak without any `/mobile/unknown-tenant` redirect.
- **AC2** — On a **transient** backend failure (5xx / network / timeout), the plugin performs a bounded retry (`MAX_ATTEMPTS`) and, if still failing, routes to `/mobile/unknown-tenant?reason=unavailable` with a recoverable Retry action — never the terminal bare dead-end.
- **AC3** — On a **permanent** failure (`authConfig` 404 / genuinely unknown tenant), the app routes to the bare `/mobile/unknown-tenant` (not-found copy) with **no** retry.
- **AC4** — A tenant-less URL (`!clientInfo`) short-circuits before the fetch (no `authConfig` request, no `TypeError`) and routes to bare `/mobile/unknown-tenant` (Fix D).
- **AC5** — `getKeycloakConfig()` treats the stored string `"null"`/`"undefined"`/`""` as missing config; **no `setItem('tenantKeycloakConfig', null)` sites remain** (both migrated to `removeItem`).
- **AC6** — Retry from the recoverable page re-runs the cold boot on the **original** URL/path (`window.location.reload()`), preserving the tenant subdomain and deep link (not `replace('/mobile/')`).
- **AC7** — After a tenant switch (stored `clientName`=A, URL resolves `clientName`=B), a **transient** failure on B's authConfig MUST route to `/mobile/unknown-tenant?reason=unavailable` and MUST NOT retain or boot tenant A's config. (Backed by the mobile-only tenant-change alignment, §2.4/§3.5.)
- **AC8** — A `DISCOVERY_REDIRECT_KEY` flag set during a transient failure is unconditionally cleared at the start of the next discovery run and on `unknown-tenant.vue` mount, so a later genuine not-found is never suppressed by a stale flag.

### Named Jest test methods

Helper spec (`test/plugins/tenant-auth-fetch.spec.js`):
1. `retries_5xx_up_to_max_attempts_then_unavailable`
2. `returns_notfound_on_404_without_retry`
3. `aborts_and_retries_on_timeout`
4. `succeeds_on_first_ok_response` (asserts `mobileRedirectUrl` mapping)
5. `recovers_after_transient_then_ok`
6. `no_client_short_circuits_without_fetch` (`classifyRedirect('notfound')` → `/mobile/unknown-tenant`)
7. `wrong_tenant_after_switch_transient_does_not_boot_stored_config` (AC7 / C1)
8. `same_tenant_transient_may_preserve_stored_config` (C1)
8b. `same_client_different_warehouse_transient_does_not_boot_stored_config` (Fix E)
9. `transient_lands_on_reason_unavailable_never_bare_unknown_tenant` (`/mobile/unknown-tenant?reason=unavailable`; C2 / Fix F)
10. `null_string_treated_as_missing_config` (Fix E reader guard)
11. `sbdev2390_guardedLogin_non_regression` (SBDEV-2390; asserts `/mobile/unknown-tenant?reason=auth`)
12. `stale_discovery_flag_cleared_on_success_does_not_mask_later_notfound` (AC8)

Plugin spec (`test/plugins/initTenantAuth.spec.js`):
13. `notfound_404_sets_flag_and_replaces_bare_mobile_unknown_tenant`
14. `transient_5xx_sets_flag_unavailable_and_replaces_reason_unavailable`
15. `no_client_fix_d_sets_flag_notfound_and_bare_redirect_before_any_fetch`

### Completeness checklist

- [ ] Every §0 **yes** row (Fixes B/C/D/E/F + Jest harness) has a POSITIVE verify-script check.
- [ ] Every §0 site that removes old code (`setItem(…,null)`) has a NEGATIVE verify-script check.
- [ ] §0 row 2 (Fix A already-present: `!response.ok` throw) and row 7 (`?reason=auth`) have **non-regression** verify-script checks.
- [ ] All redirect targets asserted with the `/mobile/` base.
- [ ] AC1–AC8 each map to at least one named Jest test.
- [ ] The mobile-only tenant-change alignment (§2.4) is covered by AC7 + test #7/#8b + a verify-script POSITIVE check.
- [ ] SBDEV-2390 non-regression covered by named Jest test #11 + §9 NR checks.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script (machine-checkable)

Executable acceptance script: `sbdocs/9-System/scripts/verify-SBDEV-2391-mobile-wms-refresh-tenant-not-recognized.sh` (modelled on the web script; greps against `v2/wms2-mobile-ui`).

> **What grep can and cannot prove:** the verify script proves **presence/absence of code shape only**. Behavior is proven by the named Jest tests (§6/§8). Both are required.

Checks enumerated by the script:

- **(a) NON-REGRESSION (Fix A already-present)** — `initTenantAuth.client.js` still has the `!response.ok` throw (mobile never had a dead `status===500` branch; assert it stays correct).
- **(b) NEGATIVE** — zero `setItem('tenantKeycloakConfig', null)` remain in `initTenantAuth.client.js` (was :60, :120).
- **(c) POSITIVE** — the `!clientInfo` branch has a `return` **before** the fetch (Fix D).
- **(d) POSITIVE** — `response.ok` / `res.status === 404` handling present in `tenant-auth-fetch.js` (Fix B).
- **(e) POSITIVE** — `MAX_ATTEMPTS` + `TIMEOUT_MS` + `BACKOFF_MS` + `AbortController` present in `tenant-auth-fetch.js`.
- **(f) POSITIVE** — `classifyRedirect` returns `/mobile/`-prefixed targets (`/mobile/unknown-tenant`, `/mobile/unknown-tenant?reason=unavailable`).
- **(g) POSITIVE** — `isUnavailable` / `reason === 'unavailable'` + `location.reload()` present in `unknown-tenant.vue`; NEGATIVE — no `location.replace('/mobile/')` retry.
- **(h) POSITIVE** — `isMissingConfig`-based `'null'`-as-missing guard present in `keycloak.client.js`.
- **(i) POSITIVE (Fix F)** — `DISCOVERY_REDIRECT_KEY`/`tenantDiscoveryRedirect` in initTenantAuth; sessionStorage used; `?reason=unavailable`/`classifyRedirect` written; keycloak.client.js reads the flag (`getItem`) before its bare redirect; initTenantAuth clears the flag at run-start; `unknown-tenant.vue` `mounted()` clears the flag.
- **(j) POSITIVE (Fix E mobile-only)** — tenant-change branch `removeItem('kcToken')` + `removeItem('tenantKeycloakConfig')`; `setItem('warehouseCode', …)` present.
- **(k) NON-REGRESSION (SBDEV-2390)** — `keycloak.client.js` still imports/calls `guardedLogin` + `resetRedirectCount`, still redirects `/mobile/unknown-tenant?reason=auth`, `onLoad:'check-sso'` still present; `unknown-tenant.vue` preserves `isAuthError`/`reason === 'auth'`.
- **(l) POSITIVE (Jest harness)** — `jest.config.js` exists; `package.json` has a `"test": "jest"` script; babel config exists; `test/plugins/tenant-auth-fetch.spec.js` + `test/plugins/initTenantAuth.spec.js` exist.

**Pre-implementation dry-run tally (this plan, before any code):** most POSITIVE checks are expected to **FAIL** (constructs not yet added); the SBDEV-2390 **NR checks and the Fix-A-already-present check are expected to PASS**; the `setItem(...,null)` NEGATIVE checks are expected to **FAIL** (the two null-set sites still exist). See §11 for the actual dry-run tally.

Workflow contract: author writes the script alongside the plan (done); the implementing agent runs it after every pass and pastes output; the orchestrator re-runs it; a "DONE" claim with FAIL lines is not accepted.

### 9.2 Recommended OMC composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard+ | Port of 5 fixes + arbitration rule + a NEW test-runner introduction (2 plugins + 1 page + 1 new helper + jest/babel/package.json). |
| **Pre-draft step** | ralplan consensus | web design already consensus-approved; this is a port — Architect/Critic review of the port + the test-runner decision. |
| **Plan-review step** | critic | Standard+ requires critic; the test-runner introduction is a reviewable decision. |
| **Implementation shape** | executor | single subsystem; verify script + Jest are the exit gate. |
| **Verification step** | verify-script + verifier (mandatory) | always. |
| **Code-review step** | code-reviewer | auth-adjacent + cross-tenant C1 + new test infra. |
| **Commit step** | git directly (branch off `main` first) | single logical commit. |

---

## 10. Resolved Decisions & Notes

### Resolved decisions (this session)

- **D1 — FULL PARITY (locked).** Port Fixes D + E + B + C + F to mobile, not just the latent fixes. Fix A is a documented no-op (mobile already throws on `!response.ok`).
- **D2 — ADD a Jest harness (locked).** Introduce jest + babel-jest + vue-jest + @vue/test-utils + a `test` script + a babel config, matching the web repo's versions, so the ported helper spec + a plugin-level `initTenantAuth` spec are runnable. The mobile repo has no test runner today.
- **D3 — Mobile-only tenant-change alignment (§2.4).** The mobile tenant-change branch only resets the timezone; it does NOT clear stale config/token. Aligned to the web behavior (add the two `removeItem`s + persist `warehouseCode`) so the Fix-E preserve invariant is sound on mobile.
- **D4 — CI test-stage wiring is OUT of scope.** Mobile CI has no test stage; tests run locally only. Updating `.gitlab-ci.yml` is explicitly deferred (noted as a risk/follow-up, not implemented here).

### ADR — Port the transient-vs-permanent tenant-discovery fix to mobile with a Jest harness

**Decision.** Port the shipped web design (bounded, Nuxt-free `fetchAuthConfig` helper classifying `notfound` vs `unavailable`; recoverable `?reason=unavailable` page + Retry-reload; `'null'`-as-missing reader guard; same-tenant identity preserve guard; single-writer `DISCOVERY_REDIRECT_KEY` arbitration) to `wms2-mobile-ui`, adapting all redirect targets to the `/mobile/` router base and the config mapping to `mobileRedirectUrl`. Fix A is a no-op (mobile already throws on `!response.ok`). Add the mobile-only tenant-change alignment (§2.4). Introduce a minimal Jest harness (mobile has none today) and port the two web specs.

**Decision drivers.** (1) A transient blip must not be reported as a permanent "tenant not found" (R1). (2) The user must have a recovery path (R2). (3) The retry must be bounded so it cannot storm the multi-replica backend (§7 row 2). (4) A cross-tenant mismatch must never boot the wrong realm (C1). (5) Parity with the shipped, code-reviewed web fix reduces divergence and future sync-sweep cost.

**Alternatives considered.**
- **O1 (chosen)** — full parity port + Jest harness. Meets R1/R2, testable, bounded backend blast radius, keeps web/mobile in lockstep. Larger diff (new helper + page state + arbitration + test infra).
- **O2 — port only the latent fixes (D + E), skip B/C/F and the harness.** Smaller diff; but leaves AC2 (transient recovery) unmet (mobile still dead-ends on a blip) and adds no regression protection. **Rejected** — violates the locked FULL-PARITY decision (D1) and R2.
- **O3 — port B/C/D/E/F but skip the Jest harness (verify-script only).** Smaller infra footprint; but the retry/classification/arbitration logic (AC2/AC7/C1/C2/AC8) is behavior that grep cannot prove, and the web fix caught a runtime-fatal wiring bug (unimported `DISCOVERY_REDIRECT_KEY`) only via a plugin-level spec. **Rejected** — the harness is the only way to prove the ported behavior and catch the same wiring class of bug.

**Why chosen.** O1 is the only option that satisfies R1, R2, the backend-safety bound, the cross-tenant guard, AND provides behavioral proof + regression protection for a mobile repo that currently has none — while keeping web and mobile in parity for future sync sweeps.

**Consequences.** New `plugins/tenant-auth-fetch.js` module + a first-ever test runner in the mobile repo (jest/babel config, devDependencies, `test` script) to maintain; one new sessionStorage key (`tenantDiscoveryRedirect`) alongside SBDEV-2390's `kcRedirectAttempts`; tests run **locally only** until CI is wired (deferred). Users on a transient outage see a recoverable page instead of a dead-end (net improvement).

**Follow-ups.** (1) Confirm backend `authConfig` returns 404 (not 5xx) for genuinely unknown tenants (§5.1 row 6). (2) Wire a mobile CI test stage in `.gitlab-ci.yml` (deferred, D4). (3) Consider extracting a shared `tenant-auth-fetch` package across web+mobile (currently duplicated per-app, same posture as SBDEV-2390's `kc-redirect-guard.js`). (4) Optional: emit a client-side metric on `reason=unavailable` renders.

### Rollback

Client-bundle change only. Rollback = redeploy the prior bundle. No DB migration, no backend contract change. The new jest/babel devDependencies are dev-only and do not affect the production bundle.

### Notes

- Shares files with SBDEV-2390 mobile (`keycloak.client.js`, `kc-redirect-guard.js`, `unknown-tenant.vue`). The SBDEV-2390 fixes (check-sso, `guardedLogin`, `resetRedirectCount`, `?reason=auth`, `/mobile/`-prefixed targets, `bumpRedirectCount` init-throw) are load-bearing and covered by the §9(k) non-regression checks + Jest test #11.
- Line numbers verified against the live mobile source on 2026-07-04.

### Open Questions

See `.omc/plans/open-questions.md`. Chief item (shared with the web plan): does `GET /api/public/authConfig` return **404** for a genuinely unknown tenant, or a 5xx/200-with-error-body? Fix B's permanent-vs-transient classifier assumes 404 = permanent; if the backend uses a different signal, the classifier's `status === 404` branch must be adjusted before AC3 can pass. Secondary: ~~is the `transformIgnorePatterns` keycloak-js allowance actually needed~~ — **RESOLVED (review):** not needed. The ported specs invoke `initTenantAuth.client.js`, which imports only `tenant-auth-fetch.js` (never keycloak-js); the web suite runs green without `transformIgnorePatterns`. Keep it defensively or omit it.

---

## 11. Consensus / Revision / Port History

- **Source design:** `SBDEV-2391-wms-refresh-tenant-not-recognized.md` (web) — ralplan consensus round 2 → Architect SOUND-WITH-CHANGES + Critic APPROVE; implemented + code-reviewed → SHIP (PR #7), §12 shipped source is the reference implementation ported here.
- **Round 0 (this doc — Planner port draft):** ported Fixes B/C/D/E/F to mobile line numbers; documented Fix A as already-present (mobile `!response.ok` throw); added the mobile-only tenant-change alignment (§2.4); adapted all redirect targets to `/mobile/`; adapted config mapping to `mobileRedirectUrl`; added the Jest harness plan (Step 0) since mobile has no test runner; ported 12 helper tests + 3 plugin tests with `/mobile/` + `mobileRedirectUrl` adaptations; authored the mobile verify script.
- **Port review:** Architect → SOUND-WITH-CHANGES (M1: `transformIgnorePatterns` defensive-only, empirically de-risked; M2: keep `route.path === '/unknown-tenant'` guards bare — base-stripped) — both folded into this doc. Jest-runnability risk resolved by the passing web suite.
- **Implemented + reviewed:** code-reviewer → **SHIP-WITH-NITS** (0 Critical/High/Medium; 1 LOW `roots` footgun + 2 nits, all optional). Web CRITICAL (unimported `DISCOVERY_REDIRECT_KEY`) not reproduced — import present and gated by the plugin-level spec (proven red→green by mutation).

## 12. Implementation Status (2026-07-04)

Implemented in `v2/wms2-mobile-ui`, committed `3a4df8a` on branch `feature/SBDEV-2391-mobile-tenant-not-recognized-refresh` (off `origin/develop`, which already contains SBDEV-2390 via PR #6) → **[mobile PR #7](https://github.com/SiteBossInc/wms2-mobile-ui/pull/7)** into `develop`, paired with web [PR #7](https://github.com/SiteBossInc/wms2-web-ui/pull/7). Faithful port of the shipped web fix with `/mobile/` + `mobileRedirectUrl` adaptations. TDD: plugin spec proven to gate the import bug (RED `ReferenceError` → GREEN).

**Files changed:**
- `plugins/tenant-auth-fetch.js` (new) — Fix B; ported from web with 2 deltas: `redirectUri ← body.mobileRedirectUrl`, `classifyRedirect` returns `/mobile/`-prefixed targets. Exports `DISCOVERY_REDIRECT_KEY`, `isMissingConfig`, `shouldPreserveStoredConfig`.
- `plugins/initTenantAuth.client.js` — Fix D (no-client early return + flag `'notfound'`), Fix E (2 `setItem(...,null)`→`removeItem`; identity-matched preserve; **mobile-only** tenant-change hardening: `removeItem('kcToken')`+`removeItem('tenantKeycloakConfig')`+persist `warehouseCode`), Fix F (sole-writer arbiter, unconditional flag clear at run start, defensive catch). Route guard `:80` left bare.
- `plugins/keycloak.client.js` — Fix E (`getKeycloakConfig` → shared `isMissingConfig`), Fix F (`!config` block flag-aware, `process.client`-gated). Route guard `:81` left bare. SBDEV-2390 wiring untouched.
- `pages/unknown-tenant.vue` — Fix C (`isUnavailable` state, Retry via `window.location.reload()`, `mounted()` clears flag). `isAuthError` preserved.
- `jest.config.js` (new), `.babelrc` (new), `package.json` — **first test runner in this repo**: jsdom + babel-jest/vue-jest, `roots: ['<rootDir>/test']` to exclude the Playwright e2e specs, devDeps pinned to web's versions, `"test":"jest"`.
- `test/plugins/tenant-auth-fetch.spec.js` (new, 13 incl. same-client/different-warehouse) + `test/plugins/initTenantAuth.spec.js` (new, 3 plugin-level).

**Verification:** `yarn test` → **16 passed, 16 total** (2 suites); verify script → **42 pass, 0 fail, 2 skip**; no lint script in mobile (skipped, expected). Verify-script `check_A_already_present` re-pointed to the helper (`$FETCH`) since Fix B moved `response.ok` there — semantics preserved (matches web structure), confirmed legitimate by review.

**Optional follow-ups (non-blocking, from review):** (1) LOW — `jest.config.js roots` silently ignores future co-located specs; consider `testPathIgnorePatterns: ['/node_modules/','/tests/e2e/']` instead. (2) Enable the deferred `BT1/BT2` behavior checks in the verify script now that the harness runs. (3) Wire a CI test stage in `.gitlab-ci.yml` (mobile CI has none) — out of scope here. (4) Commit pending user approval (branch off `develop`).

### Verify-script dry-run tally (pre-implementation)

_Filled in after authoring the script (see §9 for expectations)._ Recorded in this session's return summary; expect mostly FAIL on the yes-row POSITIVE checks, PASS on the Fix-A-already-present and SBDEV-2390 NR checks, FAIL on the `setItem(...,null)` NEGATIVE checks (both null-set sites still present pre-fix).

### Completeness checklist

- [x] §0 affected-sites table uses MOBILE line numbers (verified on-disk 2026-07-04).
- [x] Fix A documented as already-present (no re-add).
- [x] Mobile-only additions called out explicitly (tenant-change alignment §2.4/§3.5; `/mobile/` targets; `mobileRedirectUrl` mapping; Jest harness).
- [x] ADR present (Decision, Drivers, Alternatives, Why chosen, Consequences, Follow-ups).
- [x] AC1–AC8 adapted for mobile; each maps to a named Jest test.
- [x] Verify-script path + dry-run expectation documented.


> **Archived 2026-07-25.** Acceptance script retired to `sbdocs/4-Archieves/scripts/verify-SBDEV-2391-mobile-wms-refresh-tenant-not-recognized.sh`.
