---
title: "SBDEV-2391 — Refresh on a valid tenant intermittently shows \"Tenant Not Recognized\" (web UI)"
ticket: "SBDEV-2391"
ticket_url: "https://app.clickup.com/t/868jwjyg1"
type: "bugfix"
priority: "High"
status: "implemented"
project: ["wms2-web-ui"]
version: "v2"
requester: "Brent Campbell"
created: "2026-07-04"
updated: "2026-07-04"
db_verified: false
related:
  - "SBDEV-2390-web-pickpack-keycloak-refresh-loop.md"
  - "SBDEV-2390-mobile-pickpack-keycloak-refresh-loop.md"
tags:
  - plan
  - wms2-web-ui
  - keycloak
  - auth
  - tenant-discovery
  - multi-tenant
---

# SBDEV-2391 — Refresh on a valid tenant intermittently shows "Tenant Not Recognized" (web UI)

**Ticket:** [SBDEV-2391](https://app.clickup.com/t/868jwjyg1)
**Project:** wms2-web-ui | **Version:** v2 | **Type:** bugfix
**Priority:** High
**Status:** implemented (ralplan consensus reached round 2 → Critic APPROVE; implemented + code-reviewed → SHIP on 2026-07-04; uncommitted working-tree in `v2/wms2-web-ui`, see §12)
**Date:** 2026-07-04

**Sibling plan:** `SBDEV-2390-web-pickpack-keycloak-refresh-loop.md` (same tenant-discovery / Keycloak-bootstrap subsystem — this plan shares its files and MUST NOT regress its fixes; see §6 non-regression).

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep across `v2/wms2-web-ui` (`fetch`, `response.json`, `status ===`, `setItem('tenantKeycloakConfig'`, `location.replace/href`, `getKeycloakConfig`, redirect targets) and confirmed against the live source (Architect confirmed line numbers 2026-07-04) — not from memory.

| # | File:line | Construct | Root-cause contribution | In-scope this plan? |
|---|-----------|-----------|-------------------------|---------------------|
| 1 | plugins/initTenantAuth.client.js:56-60 | `if (!clientInfo) { … setItem('tenantKeycloakConfig', null) … }` then **falls through** with no `return` into the fetch at :82 (builds `authConfig?key=undefined-undefined`) | **deterministic defect** — a genuinely tenant-less URL still fires a garbage fetch instead of short-circuiting | **yes** — Fix D |
| 2 | plugins/initTenantAuth.client.js:82-91 | `const response = await fetch(...)` then `if (tenantConfig.status === 500)`. `fetch` does NOT throw on 5xx and the parsed authConfig body has no `status` field — so this branch is **dead code** and a real 5xx/timeout is silently treated as a "valid" (garbage) config OR falls into `catch` | **primary defect** — transient backend failure is indistinguishable from "tenant not found"; both paths null the config | **yes** — Fix A + Fix B |
| 3 | plugins/initTenantAuth.client.js:58, 87, 117 | **exactly three** `localStorage.setItem('tenantKeycloakConfig', null)` sites (no-client / dead 500-branch / catch). `setItem(key, null)` stores the **string** `"null"`, not JS `null` | contributing — poisons the value the KC plugin reads; see Fix E `'null'`-guard | **yes** — Fix A/E (rework these three sites; line 120 is `resetWarehouseTimezone`, NOT a null-set; the tenant-change branch at :67 already correctly uses `removeItem` and is left intact) |
| 4 | plugins/keycloak.client.js:16-31 | `getKeycloakConfig()` → `JSON.parse(localStorage.getItem('tenantKeycloakConfig'))`. The stored string `"null"` is **truthy** at :18, so `JSON.parse("null")` returns JS `null`, which then flows to :31 `const config = getKeycloakConfig()` | contributing — the `"null"` string is the poisoned value that makes `config` null and triggers the bare redirect | **yes** — Fix E (`'null'`-as-missing guard) |
| 5 | plugins/keycloak.client.js:33-39 | `if (!config) { window.location.replace('/unknown-tenant') }` — **bare** redirect, no `reason`, cannot distinguish "tenant not found" from "backend was briefly down" | **primary user-visible symptom** — a transient failure dead-ends on the terminal "Tenant Not Recognized" page with no retry | **yes** — Fix F (single-writer arbitration; reason-aware) |
| 6 | plugins/keycloak.client.js:108 | `window.location.replace('/unknown-tenant?reason=auth')` (SBDEV-2390 loop-breaker terminal) | separate cause (KC auth loop, not tenant discovery) | no — **must not regress** (§6 non-regression); documented as the third redirect surface for Fix F arbitration |
| 7 | pages/unknown-tenant.vue:34-36 | `isAuthError()` reads `reason === 'auth'`; page has exactly two copy states (auth vs not-found) | needs a **third** state for transient/unavailable | **yes** — Fix A (recoverable `reason=unavailable` copy + retry) |

Every **yes** row maps to a POSITIVE (and, where it replaces old code, a NEGATIVE) check in `verify-SBDEV-2391-wms-refresh-tenant-not-recognized.sh` (§9). Row 6 maps to a **non-regression** check.

---

## 1. Problem Statement

> **`db_verified: false`** — This is a pure frontend tenant-discovery / auth-routing defect (Nuxt 2 / Vue 2 client plugins). No database state is involved and **no DB check is required** before implementation; the DB-verification gate is N/A. Optional non-blocking backend sanity: `GET /api/public/authConfig?key={warehouse}-{client}` returns a Keycloak config for a healthy tenant, and returns a 5xx (or times out / is unreachable) during a backend blip — but the fix does not depend on reproducing that.

**User-visible symptom** (ClickUp SBDEV-2391, reported by Brent Campbell, High):
- A user on a **known-good tenant** refreshes the page and lands on the **"Tenant Not Recognized"** dead-end (`/unknown-tenant`) even though the tenant exists.
- Recovering requires the user to manually refresh again (sometimes several times); there is no in-app retry.
- Correlated with brief `wms2-api` unavailability (rolling deploy, replica restart, cold-start latency, or a transient network blip) rather than any change to the tenant.

**Root symptom in one line:** a *transient* backend failure during tenant discovery is being reported to the user as a *permanent* "tenant does not exist" error, with no retry and no recovery path.

**Reproduction** (intermittent — timing-dependent):
1. Be on a valid tenant subdomain (e.g. `warehouse.client.wms.example.com`), authenticated and working.
2. During a `wms2-api` rolling restart / brief outage / cold start, refresh the page (or the cold boot re-runs the tenant-discovery fetch).
3. `GET /api/public/authConfig?key={warehouse}-{client}` returns 5xx, times out, or the connection is refused.
4. **Expected:** a brief "temporarily unavailable, retrying…" experience that self-heals, or at worst a *recoverable* page with a Retry action.
5. **Actual:** `tenantKeycloakConfig` is set to the string `"null"`, `keycloak.client.js` reads it as no-config, and the app hard-redirects to the terminal **"Tenant Not Recognized"** page — the same page shown for a genuinely non-existent tenant.

---

## 2. Root Cause Analysis

The tenant-discovery bootstrap runs in `plugins/initTenantAuth.client.js` (loaded before `keycloak.client.js` — see project CLAUDE.md plugin order). Three independent defects combine so that a *transient* failure is misclassified as a *permanent* "no tenant":

### 2.1 The 5xx branch is dead code (primary defect)

At **initTenantAuth.client.js:82-91**:

```js
const response = await fetch(`${BASE_URL}/api/public/authConfig?key=${clientInfo.warehouse}-${clientInfo.clientName}`)
const tenantConfig = await response.json()
if (tenantConfig.status === 500) {         // :86 — DEAD
  localStorage.setItem('tenantKeycloakConfig', null)   // :87
  resetWarehouseTimezone(store)
  return
}
```

- `fetch` does **not** reject on HTTP 5xx (only on network failure / abort). So a 5xx response falls straight through `await response.json()`.
- The parsed authConfig success body has **no `status` field** — `tenantConfig.status` is `undefined`, so `=== 500` is never true. The guard at :86 is **unreachable dead code**.
- Consequences of a real transient failure:
  - **5xx with a JSON error body:** `response.json()` succeeds, `status===500` is false, code proceeds to build `keycloakConfig` from `undefined` fields (`authServerUrl`, `realm`, …) and stores a **malformed** config — a different, worse failure.
  - **Network error / connection refused / DNS blip:** `fetch` rejects → the `catch` at :115-121 fires → `setItem('tenantKeycloakConfig', null)` at :117. This is the common transient path, and it is **indistinguishable** from a legitimate "tenant not found".
- There is **no retry** and **no distinction** between "backend said this tenant doesn't exist" and "backend was briefly unreachable".

### 2.2 `!clientInfo` falls through into the fetch (deterministic defect)

At **initTenantAuth.client.js:56-60**:

```js
if (!clientInfo) {
  console.log('No client found in URL or localStorage, using default config')
  localStorage.setItem('tenantKeycloakConfig', null)   // :58
  resetWarehouseTimezone(store)
  // <-- NO return here
}
// falls through to :82
const response = await fetch(`${BASE_URL}/api/public/authConfig?key=${clientInfo.warehouse}-${clientInfo.clientName}`)
```

- There is **no `return`** after the no-client branch. Execution falls through to the fetch at :82, which dereferences `clientInfo.warehouse` / `clientInfo.clientName` on a `null` `clientInfo` → `TypeError` → caught at :115 → config nulled. A genuinely tenant-less URL therefore fires a garbage `authConfig?key=undefined-undefined` request (or throws) instead of cleanly short-circuiting to the not-found page.

### 2.3 `setItem(key, null)` stores the string `"null"`, which the reader treats as present (contributing)

- At **initTenantAuth.client.js:58, 87, 117**, `localStorage.setItem('tenantKeycloakConfig', null)` coerces `null` to the **string** `"null"`.
- At **keycloak.client.js:17-18**, `getKeycloakConfig()` does `const storedConfig = localStorage.getItem('tenantKeycloakConfig'); if (storedConfig) {`. The string `"null"` is **truthy**, so it enters the `try`, `JSON.parse("null")` returns JS `null`, and that `null` becomes `config` at :31.
- At **keycloak.client.js:33-39**, `if (!config)` fires the **bare** `window.location.replace('/unknown-tenant')` with no `reason` — the terminal dead-end. The reader cannot tell a transient failure from a real "no tenant".

### 2.4 Interaction with SBDEV-2390's tenant-change-clear branch

The SBDEV-2390 tenant-change-clear branch at **initTenantAuth.client.js:62-72** already `removeItem`s `kcToken` + `tenantKeycloakConfig` when `previousClientName && previousClientName !== clientInfo.clientName`. Critically, that branch:
- runs **only** inside the non-null-`clientInfo` else-branch (:61+), and
- runs **before** the fetch.

So on a genuine tenant switch the *previous* tenant's stored config is already cleared before we attempt discovery of the *new* tenant. We **derive** (not assert) from this that any "preserve last-known-good on transient failure" behavior is only ever safe in the **same-tenant** case — because a cross-tenant navigation has already wiped the stored config. Fix E adds a belt-and-suspenders identity check anyway (§5 Fix E, C1) rather than relying on this ordering alone.

### Affected Locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | plugins/initTenantAuth.client.js | 56-60 | `!clientInfo` branch has no `return`; falls through into the fetch (Fix D) |
| 2 | plugins/initTenantAuth.client.js | 82-91 | fetch has no `response.ok`/404 handling; dead `status === 500` branch at :86 (Fix A + Fix B) |
| 3 | plugins/initTenantAuth.client.js | 58, 87, 117 | three `setItem('tenantKeycloakConfig', null)` sites — string `"null"` poisoning (Fix A/E rework) |
| 4 | plugins/initTenantAuth.client.js | 115-121 | catch nulls config, no transient/permanent distinction, no retry (Fix A + Fix B) |
| 5 | plugins/keycloak.client.js | 16-31 | `getKeycloakConfig()` treats string `"null"` as present (Fix E `'null'`-guard) |
| 6 | plugins/keycloak.client.js | 33-39 | bare `/unknown-tenant` redirect, not `reason`-aware (Fix F) |
| 7 | pages/unknown-tenant.vue | 34-36 | only two copy states (auth / not-found); needs recoverable `unavailable` (Fix A) |
| 8 | plugins/tenant-auth-fetch.js | (new) | extracted, Nuxt-free fetch/retry/classification helper (Fix B, prerequisite) |

---

## 3. Design / Proposed Fix

Locked UX decisions carried from round 1 (ralplan step-2 alignment):
- **R1** — distinguish *transient* (retryable) from *permanent* (tenant not found) failures.
- **R2** — on a transient failure, perform a **bounded** in-plugin retry, then route to a **recoverable** page (`?reason=unavailable`) with a Retry action, rather than the terminal dead-end.

Five fixes (A–E) plus one arbitration rule (Fix F). Fix B is delivered via a **new extracted helper** so the fetch/retry/classification logic is unit-testable without booting Nuxt.

### 3.1 Fix A — classify the failure and route to the right page

- Replace the dead `status === 500` guard with real HTTP-status handling driven by the extracted helper (Fix B): `response.ok` → success; `res.status === 404` → **permanent** (tenant not found); 5xx / network error / timeout → **transient** (retryable).
- On **permanent**: clear config (`removeItem`, not `setItem(…, null)`) and route to the **bare** `/unknown-tenant` (not-found copy).
- On **transient** (after retries exhausted): route to `/unknown-tenant?reason=unavailable` (recoverable copy + Retry).
- `pages/unknown-tenant.vue` gains a third state `isUnavailable` (`reason === 'unavailable'`) with recoverable copy and a Retry button (Fix C wiring).

### 3.2 Fix B — extracted, bounded, Nuxt-free retry helper (`plugins/tenant-auth-fetch.js`)

New module `plugins/tenant-auth-fetch.js` (module-scope exports, mirroring `kc-redirect-guard.js`) so Jest can import it without booting Nuxt.

- Constants: `MAX_ATTEMPTS = 3`, `TIMEOUT_MS = 5000`, `BACKOFF_MS = 300` (linear or capped backoff between attempts).
- Uses `AbortController` to enforce `TIMEOUT_MS` per attempt.
- **Retry policy (explicit):** the helper retries on **5xx**, **network errors**, and **its OWN `AbortController` timeout**. It does **NOT** retry on `4xx` (a `404` is a definitive "tenant not found" — surfaced immediately as permanent). Retrying is **bounded by the `MAX_ATTEMPTS` hard cap** so that a rapid-refresh burst cannot amplify into a request storm against all `wms2-api` replicas (this is the mitigation for §7 concern row 2 — see HSV).
- Returns a discriminated result: `{ ok: true, config }` | `{ ok: false, reason: 'notfound' }` | `{ ok: false, reason: 'unavailable' }`.
- Exports the classification + retry functions for direct unit testing.

### 3.3 Fix C — recoverable page + retry action

- `pages/unknown-tenant.vue` adds `isUnavailable` computed and a Retry button.
- **Retry re-runs the cold boot on the ORIGINAL URL/path** via `window.location.reload()` — **NOT** `window.location.replace('/')`. `extractClientFromUrl()` reads `window.location.href`, so reloading preserves the tenant subdomain and deep link; `replace('/')` would discard the deep link and (on a non-tenant root) could re-trigger the not-found path.
- **`unknown-tenant.vue` clear-lifecycle (MANDATORY):** `pages/unknown-tenant.vue` is currently a computed-only SFC with **no** `mounted()` hook. The executor MUST **ADD** a `mounted()` hook (not extend an existing one) that unconditionally calls `sessionStorage.removeItem('tenantDiscoveryRedirect')` as its first action. This ensures that any stale `tenantDiscoveryRedirect` flag is cleared immediately when the recovery page mounts — preventing a stale flag from suppressing a later genuine not-found redirect when the user navigates away and returns. See invariant in §3.6.

### 3.4 Fix D — short-circuit the no-client branch

- Add a `return` (route to bare `/unknown-tenant` via the Fix F arbiter) at the end of the `!clientInfo` branch (:56-60) **before** the fetch, so a tenant-less URL never builds `authConfig?key=undefined-undefined` and never dereferences `null`.
- Before routing to bare `/unknown-tenant`, the no-client path MUST set `sessionStorage.setItem('tenantDiscoveryRedirect', 'notfound')` — consistent with the invariant that `initTenantAuth` is the **sole writer** of the `tenantDiscoveryRedirect` flag and always sets it before any tenant-discovery redirect (see §3.6). The value `'notfound'` reflects that a missing client in the URL is a permanent (not transient) condition.

### 3.5 Fix E — wrong-tenant realm-boot guard + `'null'`-as-missing reader guard

**Reader guard (keycloak.client.js:16-31):** `getKeycloakConfig()` treats the literal string `'null'` (and `'undefined'`) as **missing** — i.e. `if (!storedConfig || storedConfig === 'null' || storedConfig === 'undefined') return null`. Belt-and-suspenders while the writers migrate to `removeItem`, and defends against any other code path that might still write `"null"`.

**Preserve-invariant (the C1 correctness rule):** On a **transient** failure, Fix E may preserve the previously-stored `tenantKeycloakConfig` (to avoid nulling a still-valid same-tenant config during a blip) **ONLY when the resolved identity (`clientName` + `warehouse`) matches the stored `clientName`**. On **ANY mismatch**, do **NOT** boot the stored config — clear it (`removeItem`) and route to recovery.

> **Why the identity check is mandatory (do not rely on the :62-72 ordering alone):** §2.4 shows the SBDEV-2390 tenant-change branch already `removeItem`s on a cross-tenant switch, which makes same-tenant the *only* case where a stored config survives to the preserve path. But that branch runs only in the non-null-`clientInfo` else-branch and before the fetch — a future refactor, a race across two cold loads, or a partially-applied clear could leave tenant A's config in storage while the URL resolves tenant B. Booting tenant A's realm/clientId for a tenant-B user would send the user to the **wrong realm** (a silent cross-tenant auth defect, worse than the dead-end this plan fixes). The preserve path therefore performs its **own** identity check and refuses to preserve/boot on mismatch.

**Files changed:** `plugins/initTenantAuth.client.js`, `plugins/keycloak.client.js`, `plugins/tenant-auth-fetch.js` (new), `pages/unknown-tenant.vue`.

### 3.6 Fix F — single-writer redirect discipline (arbitration rule)

There are **three** tenant-error redirect surfaces:
- `keycloak.client.js:36` — bare `/unknown-tenant` (no-config).
- `keycloak.client.js:108` — `?reason=auth` (SBDEV-2390 KC loop-breaker terminal).
- `initTenantAuth`'s new `?reason=unavailable` / bare not-found (Fix A/D).

**Rule:** `initTenantAuth` is the **SOLE writer of the tenant-discovery redirect reason**. It owns `404 → bare /unknown-tenant` and `transient → ?reason=unavailable`. Before **any** tenant-discovery redirect it sets a **sessionStorage** flag `tenantDiscoveryRedirect` = `'notfound' | 'unavailable'` (mirroring `kc-redirect-guard.js`'s sessionStorage pattern).

- **sessionStorage, not a module var:** the redirect tears the page down, so a module-scoped variable would not survive to the next plugin/load. sessionStorage survives the tearing-down page, is tab-scoped, and clears on tab close — the correct mechanism (same rationale `kc-redirect-guard.js` documents for the KC counter).
- `keycloak.client.js:33-39`'s bare redirect becomes **reason-aware**: if `tenantDiscoveryRedirect` is already set in-flight, `keycloak.client.js` **skips its own bare redirect** (so a cross-load race cannot *downgrade* an in-flight `?reason=unavailable` to the terminal bare dead-end). The `?reason=auth` loop-breaker at :108 is a **separate** concern (KC auth, not tenant discovery) and is left intact (§6 non-regression).
- **Flag clear-lifecycle (MANDATORY — two unconditional clear points):**
  **(a) `pages/unknown-tenant.vue` clears the flag in a `mounted()` hook** — specifically `sessionStorage.removeItem('tenantDiscoveryRedirect')` — as its first lifecycle action. This page is currently a computed-only SFC with **no** `mounted()` hook; the executor MUST **ADD** the hook rather than extending an existing one.
  **(b) `initTenantAuth` clears the flag UNCONDITIONALLY at the very start of every discovery run**, before the fetch, mirroring SBDEV-2390's unconditional `resetRedirectCount()` at `keycloak.client.js:76` / `kc-redirect-guard.js:21-23`. This means every successful run wipes any flag set by a prior failed run.
  **Invariant:** the flag is written **ONLY** immediately before a tenant-discovery redirect (by `initTenantAuth`, the sole writer) and cleared unconditionally (a) at the top of each discovery run in `initTenantAuth`, and (b) on `unknown-tenant.vue` mount. This ensures the flag can never survive a successful run and mask a later genuine not-found redirect.

---

## 4. V1/V2 Applicability

v2-only. The v1 stack (`v1/wms-web-ui`) has a different (pre-per-tenant-discovery) bootstrap and is out of scope. No porting required.

| Aspect | V1 | V2 | Impact |
|--------|----|----|--------|
| Tenant-discovery plugin | different bootstrap | `initTenantAuth.client.js` | v2-only defect |
| authConfig endpoint | n/a in this form | `GET /api/public/authConfig` | v2-only |

### What Does NOT Need Porting
- All of A–F — v1 does not have this `authConfig`-driven per-tenant discovery flow.

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
| 6 | **External systems** | `GET /api/public/authConfig?key={warehouse}-{client}` returns a config for a valid tenant and `404` for an unknown one | — | Confirm the endpoint returns **404** (not 200-with-error-body) for a genuinely unknown tenant so Fix A's permanent/transient split is correct. If it returns 5xx for unknown tenants, adjust the classifier and note it (see §8 Open Questions). |
| 7 | **Access / permissions** | N/A | — | Endpoint is `/api/public/*`, unauthenticated. |
| 8 | **Monitoring / alerts** | N/A (optional) | — | Optional: a client-side log/metric on `reason=unavailable` renders would help correlate with backend blips, but not required for the fix. |

### 5.2 Implementation Checklist (ordered, atomic)

- [ ] **Step 1 (PREREQUISITE — do first):** Create `plugins/tenant-auth-fetch.js` with module-scope exports (`MAX_ATTEMPTS=3`, `TIMEOUT_MS=5000`, `BACKOFF_MS=300`, `AbortController`, `response.ok`/`res.status===404` classification, discriminated result). The fetch/retry/classification logic **MUST be exported from here** so Jest imports it without booting Nuxt (mirrors `kc-redirect-guard.js`). This is a hard prerequisite for the Fix B tests and for wiring Fix A — not an afterthought.
- [ ] **Step 2 (Fix D):** Add a `return` (via the Fix F arbiter → bare `/unknown-tenant`) at the end of the `!clientInfo` branch (:56-60), before the fetch.
- [ ] **Step 3 (Fix A + Fix B):** Replace the fetch block (:82-91) and catch (:115-121) with a call into `tenant-auth-fetch.js`. Map `notfound → removeItem + bare redirect`; `unavailable → removeItem (or same-tenant preserve per Fix E) + ?reason=unavailable`; `ok → setItem(JSON.stringify(config))`. Remove the dead `status === 500` branch. Replace all `setItem('tenantKeycloakConfig', null)` with `removeItem` (or a same-tenant-guarded preserve on the transient path).
- [ ] **Step 4 (Fix E):** Add the `'null'`/`'undefined'`-as-missing guard in `getKeycloakConfig()` (keycloak.client.js:16-31). Add the same-tenant identity check on the transient preserve path in initTenantAuth (compare resolved `clientName`+`warehouse` to stored `clientName`; mismatch → do not preserve/boot, clear + recover).
- [ ] **Step 5 (Fix F):** Add the `tenantDiscoveryRedirect` sessionStorage flag; make `initTenantAuth` the sole writer of tenant-discovery redirects; make keycloak.client.js:33-39 skip its bare redirect when the flag is set in-flight. Leave the `?reason=auth` loop-breaker (:108) untouched. **At the very start of every `initTenantAuth` discovery run (before the fetch), unconditionally call `sessionStorage.removeItem('tenantDiscoveryRedirect')` — mirroring SBDEV-2390's `resetRedirectCount()` pattern — so a flag from a prior failed run never masks a later genuine not-found.** The no-client path (Step 2) sets the flag to `'notfound'` before routing; the 404 path sets it to `'notfound'`; the transient path sets it to `'unavailable'` — all writes are immediately preceded by a clear at run-start.
- [ ] **Step 6 (Fix C + Fix F clear):** Add `isUnavailable` computed + Retry button (`window.location.reload()`) to `pages/unknown-tenant.vue`. Also **ADD a `mounted()` hook** (this page currently has none) containing `sessionStorage.removeItem('tenantDiscoveryRedirect')` as its first line — this is the second unconditional clear point of the Fix F flag lifecycle (see §3.6, §3.3).
- [ ] Unit tests added (§6) — the six named Jest methods + the three new ones (C1/C2/non-regression).
- [ ] `yarn lint` clean; `bash sbdocs/9-System/scripts/verify-SBDEV-2391-wms-refresh-tenant-not-recognized.sh` → 0 fail.
- [ ] Code review completed.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Valid tenant, healthy backend | cold boot on valid subdomain | success, config stored, KC boots |
| Valid tenant, 5xx blip | authConfig returns 5xx `MAX_ATTEMPTS` times | route to `?reason=unavailable`, never bare dead-end |
| Valid tenant, 5xx then recovers | 5xx on attempt 1, 200 on attempt 2 | success, config stored, no redirect |
| Unknown tenant | authConfig returns 404 | bare `/unknown-tenant` (not-found copy), no retry |
| No client in URL | tenant-less URL | short-circuit to bare `/unknown-tenant`, no fetch |
| Wrong-tenant-after-switch + transient | stored clientName=A, URL resolves clientName=B, transient on B | route to `?reason=unavailable`; **must NOT** retain/boot A's config (AC7) |

### New / updated tests

Test file: `test/plugins/tenant-auth-fetch.spec.js` (imports `plugins/tenant-auth-fetch.js` directly — no Nuxt boot), plus assertions in the existing keycloak/tenant plugin specs.

| Test method | What it asserts |
|-------------|-----------------|
| `retries_5xx_up_to_max_attempts_then_unavailable` | 5xx `MAX_ATTEMPTS` times → result `{ok:false, reason:'unavailable'}`; exactly `MAX_ATTEMPTS` fetch calls (bounded — no storm) |
| `returns_notfound_on_404_without_retry` | `404` → `{ok:false, reason:'notfound'}`; exactly **one** fetch call (no retry on 4xx) |
| `aborts_and_retries_on_timeout` | attempt exceeding `TIMEOUT_MS` aborts via `AbortController` and counts as a retryable attempt, bounded by `MAX_ATTEMPTS` |
| `succeeds_on_first_ok_response` | `response.ok` → `{ok:true, config}`; config fields mapped from body |
| `recovers_after_transient_then_ok` | 5xx on attempt 1, 200 on attempt 2 → `{ok:true, config}` |
| `no_client_short_circuits_without_fetch` | `!clientInfo` path performs **zero** authConfig fetches and routes to bare not-found (Fix D) |
| `wrong_tenant_after_switch_transient_does_not_boot_stored_config` | stored clientName=A, resolved clientName=B, transient on B → does **not** preserve/boot A's config; routes to `?reason=unavailable` (AC7, C1) |
| `same_tenant_transient_may_preserve_stored_config` | stored clientName=A, resolved clientName=A, transient → same-tenant preserve path is permitted (identity check passes) (C1) |
| `transient_lands_on_reason_unavailable_never_bare_unknown_tenant` | a transient failure routes to `?reason=unavailable` and **never** the bare `/unknown-tenant`; `tenantDiscoveryRedirect` flag set; keycloak.client.js bare redirect suppressed while flag in-flight (C2, Fix F) |
| `null_string_treated_as_missing_config` | `getKeycloakConfig()` returns JS `null` for stored string `"null"`/`"undefined"` (Fix E reader guard) |
| `sbdev2390_guardedLogin_non_regression` | keycloak.client.js still imports/calls `guardedLogin` + `resetRedirectCount`, still redirects `?reason=auth` on the KC loop-breaker path, and `onLoad:'check-sso'` is still present (SBDEV-2390 not regressed) |
| `stale_discovery_flag_cleared_on_success_does_not_mask_later_notfound` | Set `tenantDiscoveryRedirect` flag → run a successful discovery → assert flag is removed; then a subsequent no-config load reaches the bare not-found redirect (not suppressed by stale flag) (AC8) |

### Manual test plan

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| 1 | Happy path | staging | Cold-load a valid tenant subdomain | Loads normally, no redirect | |
| 2 | Transient blip → recoverable | staging | Restart wms2-api / block authConfig, refresh valid tenant | `?reason=unavailable` recoverable page with Retry; Retry after backend up → app loads | |
| 3 | Retry preserves deep link | staging | On `?reason=unavailable` reached from a deep-linked path, click Retry | Reloads the ORIGINAL deep-linked URL (not `/`), tenant subdomain preserved | |
| 4 | Genuine unknown tenant | staging | Load a non-existent tenant subdomain (authConfig 404) | Bare "Tenant Not Recognized" (not-found copy), no retry loop | |
| 5 | Wrong-tenant-after-switch | staging | Auth on tenant A, navigate to tenant B while B's authConfig blips | Routes to `?reason=unavailable`; does NOT silently boot tenant A's realm | |
| 6 | SBDEV-2390 non-regression | staging | Reproduce the SBDEV-2390 KC-loop conditions (desktop↔mobile SSO bounce) | Loop-breaker still terminates at `?reason=auth`; no new tenant-discovery interference | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `yarn test --testPathPattern=tenant-auth-fetch` | | |
| `yarn test --testPathPattern=keycloak` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2391-wms-refresh-tenant-not-recognized.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Backend `authConfig` 404-vs-5xx behavior | Backend contract; validated by prerequisite §5.1 row 6, not this frontend plan |

---

## 7. Horizontal Scalability Validation (v2 plan)

> This is a **frontend** change (client bundle). The HSV table exists to prove the change does not create a client-driven scaling hazard against the multi-replica `wms2-api`.

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | In-JVM state | introduce backend in-JVM state? | No | Client-only; sessionStorage flag is per-browser-tab. |
| 2 | Connection pool math / request amplification | change per-client request volume against wms2-api? | **Yes** | Adds a bounded retry (`MAX_ATTEMPTS=3`, `TIMEOUT_MS=5000`, linear `BACKOFF_MS=300`). The hard `MAX_ATTEMPTS` cap plus per-attempt timeout ensures a rapid-refresh burst cannot amplify into an unbounded request storm across replicas. No retry on 4xx. |
| 3 | Scheduled jobs | add a `@Scheduled`/cron job? | No | Frontend. |
| 4 | Long transactions | hold a DB transaction? | No | Frontend. |
| 5 | Request affinity | assume same-replica follow-up? | No | authConfig is stateless/public; any replica serves it. |
| 6 | Retry / idempotency | rely on single-execution semantics? | **Yes** | authConfig is a **read** (GET, idempotent); retrying is safe. Bounded by `MAX_ATTEMPTS`. |
| 7 | Tenant context | use ThreadLocal across async? | No | Frontend. |
| 8 | Distributed lock correctness | rely on cross-replica locks? | No | Frontend. |
| 9 | Cache invalidation | write to a cached entity? | No | Frontend. |
| 10 | External notifications | send HTTP inside a transaction? | No | Frontend. |

### Evidence (for "Yes" rows)

| Concern # | What was done / verified | File:line or test reference |
|-----------|--------------------------|------------------------------|
| 2 | `MAX_ATTEMPTS` hard cap + `AbortController` timeout bound the request burst | `plugins/tenant-auth-fetch.js`; test `retries_5xx_up_to_max_attempts_then_unavailable` asserts exactly `MAX_ATTEMPTS` calls |
| 6 | GET is idempotent; retry is safe | `plugins/tenant-auth-fetch.js` |

---

## 8. Acceptance Criteria & Named Tests

### Acceptance criteria

- **AC1** — On a valid tenant with a healthy backend, cold boot resolves the config and boots Keycloak without any `/unknown-tenant` redirect.
- **AC2** — On a **transient** backend failure (5xx / network / timeout), the plugin performs a bounded retry (`MAX_ATTEMPTS`) and, if still failing, routes to `/unknown-tenant?reason=unavailable` with a recoverable Retry action — never the terminal bare dead-end.
- **AC3** — On a **permanent** failure (`authConfig` 404 / genuinely unknown tenant), the app routes to the bare `/unknown-tenant` (not-found copy) with **no** retry.
- **AC4** — A tenant-less URL (`!clientInfo`) short-circuits before the fetch (no `authConfig?key=undefined-undefined` request) and routes to bare `/unknown-tenant` (Fix D).
- **AC5** — `getKeycloakConfig()` treats the stored string `"null"`/`"undefined"` as missing config; no `setItem('tenantKeycloakConfig', null)` sites remain (all migrated to `removeItem`).
- **AC6** — Retry from the recoverable page re-runs the cold boot on the **original** URL/path (`window.location.reload()`), preserving the tenant subdomain and deep link (not `replace('/')`).
- **AC7** — After a tenant switch (stored `clientName`=A, URL resolves `clientName`=B), a **transient** failure on B's authConfig MUST route to `/unknown-tenant?reason=unavailable` and MUST NOT retain or boot tenant A's config.
- **AC8** — A `tenantDiscoveryRedirect` flag set during a transient failure is unconditionally cleared at the start of the next discovery run and on `unknown-tenant.vue` mount, so a later genuine not-found is never suppressed by a stale flag.

### Named Jest test methods (§6 detail)

1. `retries_5xx_up_to_max_attempts_then_unavailable`
2. `returns_notfound_on_404_without_retry`
3. `aborts_and_retries_on_timeout`
4. `succeeds_on_first_ok_response`
5. `recovers_after_transient_then_ok`
6. `no_client_short_circuits_without_fetch`
7. `wrong_tenant_after_switch_transient_does_not_boot_stored_config` (AC7 / C1)
8. `same_tenant_transient_may_preserve_stored_config` (C1)
9. `transient_lands_on_reason_unavailable_never_bare_unknown_tenant` (C2 / Fix F)
10. `null_string_treated_as_missing_config` (Fix E reader guard)
11. `sbdev2390_guardedLogin_non_regression` (SBDEV-2390 non-regression)
12. `stale_discovery_flag_cleared_on_success_does_not_mask_later_notfound` (AC8) — set `tenantDiscoveryRedirect` flag → run a successful discovery → assert flag removed AND a subsequent no-config load reaches the bare not-found redirect (not suppressed by the stale flag)

### Completeness checklist

- [ ] Every §0 **yes** row (Fixes A/B/C/D/E/F) has a POSITIVE verify-script check.
- [ ] Every §0 site that removes old code (dead `status===500`, `setItem(…,null)`) has a NEGATIVE verify-script check.
- [ ] §0 row 6 (`?reason=auth`) has a **non-regression** verify-script check.
- [ ] AC1–AC8 each map to at least one named Jest test.
- [ ] The redirect-arbitration (Fix F) and SBDEV-2390 non-regression are covered by named Jest tests (#9, #11).
- [ ] AC8 (stale flag clear) is covered by named Jest test #12.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script (machine-checkable)

Executable acceptance script: `sbdocs/9-System/scripts/verify-SBDEV-2391-wms-refresh-tenant-not-recognized.sh`.

> **What grep can and cannot prove:** the verify script proves **presence/absence of code shape only** (a construct is present at the right site, or an old construct is gone). It does **not** prove behavior — behavior is proven by the named Jest tests in §6/§8. Both are required; neither alone is sufficient.

The script enumerates these executable checks:

- **(a) NEGATIVE** — dead `status === 500` gone from `initTenantAuth.client.js`.
- **(b) NEGATIVE** — zero `setItem('tenantKeycloakConfig', null)` remain in `initTenantAuth.client.js`.
- **(c) POSITIVE** — the `!clientInfo` branch has a `return` **before** the fetch (Fix D).
- **(d) POSITIVE** — `response.ok` / `res.status === 404` handling present in `tenant-auth-fetch.js`.
- **(e) POSITIVE** — `MAX_ATTEMPTS` + `AbortController` present in `tenant-auth-fetch.js`.
- **(f) POSITIVE** — `reason='unavailable'` / `isUnavailable` present in `unknown-tenant.vue`.
- **(g) POSITIVE** — `'null'`-as-missing guard present in `keycloak.client.js`.
- **(h) NON-REGRESSION (SBDEV-2390)** — `keycloak.client.js` still imports/calls `guardedLogin` + `resetRedirectCount`, still redirects `?reason=auth`, and `onLoad:'check-sso'` still present.

Workflow contract: author writes the script alongside the plan (done); the implementing agent runs it after every pass and pastes output; the orchestrator re-runs it; a "DONE" claim with FAIL lines is not accepted.

### 9.2 Recommended OMC composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 5 fixes + 1 arbitration rule, single subsystem (2 plugins + 1 page + 1 new helper) |
| **Pre-draft step** | ralplan consensus (analyst → planner → architect → critic) | already run; this is revision round 2 |
| **Plan-review step** | critic | Standard+ requires critic (this doc is the revised target for re-review) |
| **Implementation shape** | executor | single subsystem; verify script + Jest are the exit gate |
| **Verification step** | verify-script + verifier (mandatory) | always |
| **Code-review step** | code-reviewer | auth-adjacent + cross-tenant correctness (C1) warrants a review pass |
| **Commit step** | git directly | single logical commit |

---

## 10. ADR & Notes

### ADR — Distinguish transient from permanent tenant-discovery failures with a bounded retry + recoverable page

**Decision.** Extract a Nuxt-free, bounded (`MAX_ATTEMPTS=3`/`TIMEOUT_MS=5000`/`BACKOFF_MS=300`, `AbortController`) tenant-auth-fetch helper that classifies failures into **notfound** (404, permanent) vs **unavailable** (5xx/network/timeout, transient); route transient to a recoverable `/unknown-tenant?reason=unavailable` with Retry, permanent to the bare not-found page; add a `'null'`-as-missing reader guard and a same-tenant identity guard on the transient-preserve path; make `initTenantAuth` the sole writer of the tenant-discovery redirect via a `tenantDiscoveryRedirect` sessionStorage flag.

**Decision drivers.** (1) A transient blip must not be reported as a permanent "tenant not found" (R1). (2) The user must have a recovery path without guessing "refresh again" (R2). (3) The retry must be bounded so it cannot storm the multi-replica backend (§7 row 2). (4) A cross-tenant mismatch must never boot the wrong realm (C1).

**Alternatives considered.**
- **O1 (chosen)** — bounded-retry helper + recoverable page + arbitration flag. Fully meets R1/R2, testable without Nuxt, bounded blast radius on the backend. Larger diff (new helper + page state + arbitration).
- **O2 — inline retry in `initTenantAuth` (no extracted helper).** Smaller file count, but the retry/classification logic can't be unit-tested without booting Nuxt; rejected because it forfeits the Jest coverage that AC2/AC7/C1/C2 depend on.
- **O3 — pure backend fix (make `authConfig` always resolve / add server-side retry).** Doesn't help the network-error / connection-refused / DNS-blip case (the client never reaches the backend), and doesn't remove the client's dead `status===500` / string-`"null"` defects; rejected as insufficient on its own.
- **O_ArchB (Architect's minimal option) — Fix A + Fix D + `removeItem` only; NO retry helper, NO recovery UX.** Honest trade-off: fixes the deterministic no-client fall-through and the string-`"null"` clobber with the **smallest blast radius** (no new module, no page state, no arbitration flag). **But it leaves AC2 (transient recovery) unmet** — on a transient outage the user still dead-ends and must manually refresh; there is no bounded retry and no recoverable page. **Rejected** because locked UX decision **R2** requires a bounded retry + recoverable page, which O_ArchB explicitly omits. (Retained here as the documented fallback if R2 is ever de-scoped.)

**Why chosen.** O1 is the only option that satisfies all of R1, R2, the backend-safety bound, and the cross-tenant-correctness guard, while keeping the retry/classification logic unit-testable.

**Consequences.** Slightly larger client bundle and a new `plugins/tenant-auth-fetch.js` module to maintain; one new sessionStorage key (`tenantDiscoveryRedirect`) to reason about alongside SBDEV-2390's `kcRedirectAttempts`; users on a transient outage see a recoverable page instead of silently self-healing on some refreshes (net improvement — deterministic recovery).

**Follow-ups.** (1) Confirm backend `authConfig` returns 404 (not 5xx) for genuinely unknown tenants (§5.1 row 6). (2) Optional: emit a client-side metric/log on `reason=unavailable` renders to correlate with backend deploy windows.

### Rollback

This is a **client bundle** change only. Rollback = redeploy the prior bundle. There is **no DB migration to reverse** and no backend contract change to roll back.

### Notes

- Shares files with SBDEV-2390 (`keycloak.client.js`, `kc-redirect-guard.js`, `unknown-tenant.vue`). The SBDEV-2390 fixes (check-sso, `guardedLogin`, `resetRedirectCount`, `?reason=auth`, `/error` skip-guard) are load-bearing and covered by the §9(h) non-regression check + Jest test #11.
- Line numbers in this plan were verified against the live source on 2026-07-04.

### Open Questions

See `.omc/plans/open-questions.md`. Chief item: does `GET /api/public/authConfig` return **404** for a genuinely unknown tenant, or a 5xx/200-with-error-body? Fix A's permanent-vs-transient classifier assumes 404 = permanent; if the backend uses a different signal, the classifier's `res.status === 404` branch must be adjusted before AC3 can pass.

---

## 11. Consensus / Revision History

- **Round 1 (Planner draft):** Fixes A–E, §0 7-row table, new `plugins/tenant-auth-fetch.js` helper, recoverable `reason=unavailable` state, `getKeycloakConfig` `'null'`-guard, 6 named Jest methods, 6-row manual QA, ADR O1/O2/O3.
- **Round 1 review:** Architect → SOUND-WITH-CHANGES; Critic → ITERATE.
- **Round 2 (this doc):** incorporated C1 (wrong-tenant preserve invariant + AC7 + 2 tests), C2 (single-writer redirect discipline / Fix F + test), M1 (Retry → `reload()`), M2 (three null-set sites 58/87/117; :120 is `resetWarehouseTimezone`; :67 already `removeItem`), M3 (executable verify greps incl. SBDEV-2390 non-regression), M4 (Architect's Option B surfaced as O_ArchB with rejection rationale), plus the minor items (abort-vs-5xx retry policy, helper-as-prerequisite, client-bundle rollback, AC7 + new tests in the checklists).
- **Round 2 re-review:** Architect → SOUND-WITH-CHANGES (one new foldable bug: Fix F flag clear-lifecycle "and/or" → mandatory two-point unconditional clear); Critic → **APPROVE** with 5 required-edits folded in. Consensus reached.

## 12. Implementation Status (2026-07-04)

Implemented in `v2/wms2-web-ui`, committed `1ecaf08` on branch `feature/SBDEV-2391-tenant-not-recognized-refresh` → **[PR #7](https://github.com/SiteBossInc/wms2-web-ui/pull/7)** into `develop`. TDD gate: RED baseline written first (10 correct assertion failures), then GREEN.

**Files changed:**
- `plugins/tenant-auth-fetch.js` (new) — `fetchAuthConfig` (bounded retry `MAX_ATTEMPTS=3` + per-attempt `AbortController` `TIMEOUT_MS=5000` + linear `BACKOFF_MS=300`; discriminated result `{ok:true,config}` / `{ok:false,reason:'notfound'|'unavailable'}`; 4xx never retried, only 5xx/network/timeout consume attempts), `shouldPreserveStoredConfig` (clientName+warehouse identity), `classifyRedirect` (single-writer reason resolver), `isMissingConfig`, `DISCOVERY_REDIRECT_KEY` (single source of truth). — Fix A/B/E/F
- `plugins/initTenantAuth.client.js` — response.ok/404/transient split via helper; `!clientInfo` early return with flag `'notfound'`; three `setItem(...,null)` → `removeItem`; transient preserve only when identity matches (pre-overwrite `previousClientName`/`previousWarehouse` captured before persist); unconditional flag clear at run start; defensive `redirectTenantDiscovery`. — Fix A/D/E/F
- `plugins/keycloak.client.js` — `getKeycloakConfig` calls shared `isMissingConfig`; bare redirect is flag-aware (skips when `DISCOVERY_REDIRECT_KEY` set in-flight). SBDEV-2390 wiring untouched. — Fix E/F
- `pages/unknown-tenant.vue` — `isUnavailable` third state ("Couldn't Reach SiteBoss OWL" + Retry via `window.location.reload()`); `mounted()` clears the flag. `isAuthError` state preserved. — Fix C
- `test/plugins/tenant-auth-fetch.spec.js` (new) — helper unit tests incl. #8b same-client/different-warehouse preserve-guard and #10 real `isMissingConfig` gate.
- `test/plugins/initTenantAuth.spec.js` (new) — plugin-level behavioral tests (notfound / transient / no-client → flag + `window.location.replace` target); catches the constant-import class of bug.

**Verification:**
- `yarn test -- --no-coverage` → all SBDEV-2391 + SBDEV-2390 specs pass (pre-existing unrelated `NuxtLogo.spec.js` module-resolution failure left as-is).
- `bash sbdocs/9-System/scripts/verify-SBDEV-2391-wms-refresh-tenant-not-recognized.sh` → **Result: 25 pass, 0 fail, 2 skip** (2 skips are commented behavior placeholders, superseded by the Jest specs).
- Scoped `yarn lint` on the 6 touched files → 0 errors (only pre-existing `no-console` warnings, per codebase convention).

**Review trail:** code-reviewer round 1 → CHANGES-REQUIRED (CRITICAL: `DISCOVERY_REDIRECT_KEY` unimported → runtime `ReferenceError`, masked by helper-only tests). Fixed + added plugin-level test (proven red→green by mutation). code-reviewer round 2 (delta) → **SHIP** (CRITICAL closed by mutation-check; no new Critical/High/Medium; one LOW verify-script precision nit on F4, since folded in).

**Follow-ups:** (1) mobile-ui paired `SBDEV-2391` (Fix D + Fix E only — mobile already has `response.ok`; see §10 audit note). (2) Commit pending user approval (branch off `main` first).
