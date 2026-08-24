---
title: "WMSv2 web UI: an authorization 403 logs the operator out instead of denying them"
ticket: "SBDEV-2967"
ticket_url: "https://app.clickup.com/t/868krr3rq"
type: "bugfix"
priority: "high"
status: "IMPLEMENTED 2026-08-21 on bugfix/SBDEV-2967-A-axios-403-denial-not-logout (wms2-web-ui, off origin/develop 99e2359). 7/7 new tests green; SBDEV-2554 regression suite 36/36 green; full suite 448 passed / 0 failing tests with the 2 known always-red labelPrinting SUITES unchanged. Verify script 18 pass / 0 fail, negative-tested (reverting the fix reds A2-A4). Two mutants caught with exact selectivity. ✅ COMPLETE — MERGED, DEPLOYED and END-TO-END VERIFIED on WineCo dev 2026-08-21 — [wms2-web-ui #70](https://github.com/SiteBossInc/wms2-web-ui/pull/70), merge `46dd072`. Deploy verified by the live bundle containing the fix; CORS readability proven in a real browser. Must land BEFORE slice C and, per SBDEV-3013 §2, before that ticket's door ② too."
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-21
updated: 2026-08-21
db_verified: n/a
related:
  - SBDEV-2967-web-ui-function-gating-enforcement.md
  - SBDEV-2967-B-web-view-gating.md
  - SBDEV-2967-C-web-action-gating.md
  - SBDEV-2968-mobile-ui-function-gating-enforcement.md
tags:
  - plan
  - security
  - authorization
---

# SBDEV-2967-A — An authorization 403 logs the web operator out

**Ticket:** [SBDEV-2967](https://app.clickup.com/t/868krr3rq) · **slice A of 3** (see the [index](SBDEV-2967-web-ui-function-gating-enforcement.md))
**Repo:** `v2/wms2-web-ui` — **one file**
**Tier:** T2 · **Blocked on:** nothing · **Blocks:** slice C

> **Why this is its own slice.** It was §5.1-**P8** of the monolithic plan: a prerequisite buried behind
> Brent's grant sign-off, which it does not need. It is one file, it is independently valuable today, and
> **slice C is actively harmful without it** — Fix E's entire purpose is a legible denial, and this defect
> converts every denial into a forced logout.

---

## 1. Problem statement

`wms2-web-ui/plugins/axios.js` treats an authorization **403** exactly like an authentication **401**:

```js
async retryCondition(error) {
  if (!error.response || (error.response.status !== 401 && error.response.status !== 403)) {
    return false
  }
  ...
```

> ⚠️ **Corrected 2026-08-21 during implementation — "it logs you out" is the worst case, not the only one,
> and not even the most common one.** Reading the branch through: `updateToken(5)` resolves **`false`** when
> the token is still valid for more than 5 seconds, and the very next line is `if (!refreshed) return false`.
> So which of *three* behaviours an operator hits is a timing coincidence:
>
> | Token state at the moment of the 403 | What the operator experiences |
> |---|---|
> | valid > 5s (**the common case**) | `updateToken` returns false → no retry → **silent no-op, no message at all** |
> | within 5s of expiry | refresh succeeds → 3 retries → `onMaxRetryTimesExceeded` → *"Maximum unauthorized request attempts reached"* → **logout after 3s** |
> | refresh throws | *"Session expired or invalid. Logging out…"* → **immediate logout** |
>
> **Measured, not reasoned:** the `surfacesTheDeniedFunctionName` test captured the toast text on the
> unfixed build as the empty string `""`. The common case is a control that silently does nothing, forever
> — arguably worse operationally than the logout, because nothing is reported and nothing looks broken.
> None of the three ever says "you do not have permission."

**Net effect:** an operator who lacks a function is never told so. Depending on token timing they either get
silence or lose their session, at up to 4× the request cost.

### 1.1 Verified on `origin/develop` 2026-08-21

`v2/wms2-web-ui` @ `99e2359`. The `status !== 403` clause and the authenticated-session `$kc.logout()`
branch are both present and unchanged. The file carries SBDEV-2554's fix comments, which correctly hardened
the *init-window* race — that work is sound and this slice must not disturb it.

### 1.2 Why it is live *now*, not only after slice C

This is not a latent defect waiting on the gating work:

- SBDEV-2968 **merged 2026-08-21** and its `FunctionGuardInterceptor` returns real 403s. Those gates are on
  mobile controllers, but `StockUnitController` is shared and now carries two `@RequiresFunction`
  annotations (`transferStock`, `storageLocationsForStockMovement`, both ANY-of).
- Any 403 from any source — a Spring Security path matcher, a proxy, a tenant misconfiguration — already
  logs a web operator out today.

---

## 2. Root cause

One boolean. The retry policy was written for token expiry, where a retry-after-refresh is the correct
response. 403 was folded into the same branch because both are "auth-ish" statuses. But 401 means *your
token is stale, refresh and retry* and 403 means *your token is fine and the answer is still no* — retrying
the second is guaranteed waste, and escalating it to a logout is a category error.

---

## 3. Fix design

**Discriminate on the `X-Authz-Denied` header, not on the bare status.** A 403 without that header keeps
today's behaviour, because it may genuinely be an authentication-shaped failure; a 403 *with* it is an
authorization verdict and must be surfaced, never retried.

### 3.1 The header contract already exists — consume it, do not build it

Landed by SBDEV-2968 and verified on `origin/develop` 2026-08-21:

| Piece | Location |
|---|---|
| Constant | `Authority.java:99` — `AUTHZ_DENIED_HEADER = "X-Authz-Denied"` |
| Emitted | `FunctionGuardInterceptor.java:184` — `response.setHeader(...)` on every denial |
| CORS exposed | `SecurityConfiguration.java:193-194`, with a de-duplication guard |
| Pinned | `SecurityConfigurationTest:91` — `containsExactlyInAnyOrder("X-Export-Skipped-Cycle-Counts", Authority.AUTHZ_DENIED_HEADER)` |

> ✅ **DEPLOY BLOCKER RESOLVED 2026-08-21 18:37Z — SBDEV-2968 is now live on WineCo dev, and the header
> contract is CONFIRMED IN THE RUNNING SYSTEM.**
>
> Earlier the same day this was blocked: `dev_wh01_om1` sat at V2.2.17 and responses carried **no**
> `access-control-expose-headers` at all. The GitHub Actions run for 2968's merge (`5506117`) had completed
> **successfully at 17:01Z** — image built, both Portainer webhooks returned 2xx — but the running container
> never picked up the new `:develop` image. **A green deploy pipeline is not evidence of a deployed build.**
> Re-firing the two webhooks from `.github/workflows/docker-image-develop.yml` forced the restart (observed
> as a transient 502), after which:
>
> | Check | Result |
> |---|---|
> | Flyway head on `dev_wh01_om1` | **V2.2.18** applied 18:37:01, `success=True` |
> | `Access-Control-Expose-Headers` | **`X-Export-Skipped-Cycle-Counts, X-Authz-Denied`** — matches `SecurityConfigurationTest:91` exactly |
> | `WEB_UI_VIEW_TRANSFER_ORDER` grants | now `inventory-manager, outbound-manager, super-admin` |
> | 4 gated mobile endpoints, super-admin | **200** — interceptor live, no over-denial |
>
> **`X-Authz-Denied` is therefore exposed to page JS on dev.** That is the one premise this slice rests on
> and the one no unit test can cover.
>
> ⚠️ **Still unverified: the DENY path.** The only dev credential available (`panderson`) is `super-admin`
> and holds all 11 gated functions plus all 8 `WEB_UI_ACTION_*`, so it cannot produce a 403. Confirming that
> a denial actually renders — and that the operator stays logged in — needs a deliberately under-privileged
> login, then `headers.get('x-authz-denied')` read from the page (never `curl`, never the DevTools Network
> panel: both ignore CORS filtering).

> ✅ **DENY PATH VERIFIED LIVE on WineCo dev, 2026-08-21** — using `sbtest`, a plain `/wms_user`
> (Keycloak groups `/wms_user`, `/warehouse/wsl`, `/warehouse/develop`) whose only functions are
> `MOBILE_UI_LOG_IN` + `WEB_UI_LOG_IN`. No account changes were needed.
>
> All four SBDEV-2968-gated endpoints denied correctly, each naming its own required function:
>
> | Endpoint | Status | `X-Authz-Denied` |
> |---|---|---|
> | `/v3/lookup/locationByLocationName/{n}` | 403 | `MOBILE_UI_VIEW_INFO` |
> | `/v3/replenish/requestLocation/{n}` | 403 | `MOBILE_UI_VIEW_REPLENISH_REQUEST` |
> | `/v3/putaway/scanPallet/{n}` | 403 | `MOBILE_UI_VIEW_PUT_AWAY` |
> | `/v3/cycleCountLos/orderList` | 403 | `MOBILE_UI_VIEW_CYCLE_COUNT` |
>
> Full denial response — **every link slice A depends on is present**:
>
> ```
> HTTP/2 403
> access-control-allow-origin:   https://wsl-wineco.wms.dev.sbo.li
> access-control-expose-headers: X-Export-Skipped-Cycle-Counts, X-Authz-Denied
> x-authz-denied:                MOBILE_UI_VIEW_INFO
> content-type:                  application/problem+json
> {"type":"about:blank","title":"Forbidden","status":403,
>  "reason":"MISSING_FUNCTION","requiredFunction":"MOBILE_UI_VIEW_INFO"}
> ```
>
> `allow-origin` **and** `expose-headers` both present ⇒ page JS can read `x-authz-denied`. The body is
> **flat** — `reason` and `requiredFunction` at top level, not nested under `properties` — confirming the
> interceptor's hand-built map survives the `@Primary` bare `ObjectMapper` in production, which is the
> silent-failure mode its own comment documents.
>
> ⚠️ Still browser-only: that the *page* renders the denial and the operator **stays logged in**. curl proves
> the header is exposed; it cannot prove the client behaves.

> ✅ **CORS EXPOSURE PROVEN IN A REAL BROWSER, 2026-08-21** — headless Chrome via playwright-core, page
> loaded at the real origin `https://wsl-wineco.wms.dev.sbo.li`, issuing a genuine **cross-origin** request
> to `https://wms-api.dev.sbo.li` as `sbtest`:
>
> ```json
> "denied":  { "status": 403, "authz": "MOBILE_UI_VIEW_INFO",
>              "reason": "MISSING_FUNCTION", "required": "MOBILE_UI_VIEW_INFO" }
> "allowed": { "status": 200, "authz": null }
> ```
>
> **`headers.get('x-authz-denied')` returns the function name from page JS.** This is the assertion neither
> `curl` nor the DevTools Network panel can make — both ignore CORS filtering and would show the header even
> if JS could not read it. The allowed control returning `null` proves the header is not spuriously present.
>
> ⚠️ **Trap found while running this, and it invalidated the first attempt.** The probe must use the
> **absolute** API URL. The web UI is served from `wsl-wineco.wms.dev.sbo.li` while the API is
> `wms-api.dev.sbo.li` — a relative `fetch('/v3/...')` hits the SPA's own catch-all and returns
> **`200 text/html`**, which reads as a passing check while testing nothing. First run returned exactly that.
>
> **Still outstanding (needs SBDEV-3013 door ② merged):** that the *app* renders the denial and the operator
> stays logged in. The web UI calls none of SBDEV-2968's mobile-gated endpoints, so no app-initiated 403
> exists on this UI yet — the first one will come from PR #179's user-admin gates. Reproduce then as
> `sbtest`: Admin → User Management → click a role (`userRoleDetailsById` 403s) → confirm a permission
> message appears and the session survives.

> ✅ **END-TO-END VERIFIED IN A REAL BROWSER SESSION, 2026-08-21 19:1x Z** — headless Chrome, logged into
> the live SPA at `https://wsl-wineco.wms.dev.sbo.li` as `sbtest` (plain `/wms_user`), driving **the app's
> own axios instance** (`$nuxt.$axios`) — the exact code path this slice changes, not a raw `fetch`.
>
> Trigger: `GET /userRole/userRoleDetailsById/51806`, now 403 thanks to SBDEV-3013 door ② (`808819d`).
>
> | Assertion | Result |
> |---|---|
> | request rejected, not retried into a logout | **403**, `rejected: true` |
> | the fix's branch actually executed | console: `[SBDEV-2967-A] Authorization denied (WEB_UI_VIEW_USER_MANAGEMENT); not retrying.` |
> | operator is TOLD | toast: *"You do not have permission for this action (WEB_UI_VIEW_USER_MANAGEMENT). Ask an administrator if you need access."* |
> | **session survives** | after **9 s** — outlasting the 3 s forced-logout timer — still on `/dashboard`, `$kc.authenticated === true` |
>
> Before this slice the same 403 produced either silence or a forced logout, depending on token timing.
>
> ⚠️ **Measurement trap, recorded because it produced a false negative on the first run.** `@nuxtjs/toast`
> is configured `duration: 4500` (`nuxt.config.js:86`), so sampling the DOM after the 9 s logout-timer wait
> finds **no toast** and reads as "no message shown". The toast must be sampled within ~4 s of the denial;
> the logout check needs the long wait. **They are two separate samples** — one probe cannot do both.

**Grep for `AUTHZ_DENIED_HEADER` on the base branch before writing a line.** If 2968 were ever reverted this
slice is inert, and it should fail loudly rather than silently stop discriminating.

### 3.2 The change

1. `retryCondition` returns `false` immediately when `error.response.status === 403` **and** the response
   carries `x-authz-denied`. No `awaitAuthReady()`, no token refresh, no logout timer.
2. A plain `401` — and a `403` **without** the header — keep the existing SBDEV-2554 path verbatim.
3. Surface the denial: a toast naming the function from the header value, rather than silence.

**Do not** simply drop `403` from the status check. That would also stop retrying the header-less 403s that
the init-window race can produce, re-opening what SBDEV-2554 closed.

---

## 4. Acceptance criteria

| # | Criterion | Test |
|---|---|---|
| A-1 | A 403 carrying `X-Authz-Denied` is not retried | `test/plugins/axios.spec.js#doesNotRetryWhenXAuthzDeniedHeaderPresent` |
| A-2 | A 403 carrying `X-Authz-Denied` does not log the user out | `…#doesNotLogOutOnAnAuthorizationDenial` |
| A-3 | A plain 401 is still retried, and the SBDEV-2554 init-window path is unchanged | `…#stillRetriesAPlain401WithoutTheHeader` |
| A-4 | A 403 **without** the header keeps today's behaviour | `…#stillRetriesAHeaderlessForbidden` |
| A-5 | The denial is surfaced to the operator, naming the function | `…#surfacesTheDeniedFunctionName` |
| A-6 | The header is referenced case-insensitively | `…#matchesTheHeaderRegardlessOfCase` — axios lowercases response header keys; a `'X-Authz-Denied'` lookup returns `undefined` and the fix silently does nothing |

All six are red today.

---

## 5. Test notes

**Baseline: `wms2-web-ui` `develop` has 2 always-red *suites* and 0 failing tests.** Compare the **tests**
count, never the suites count — the suites die at suite level, so `Tests: N passed` stays green while the
exit code is red.

No `yarn` on PATH — run with nvm node + `node_modules/.bin/jest`.

**Mutation-check A-1 and A-2** (the floor, at every tier): restore the `status !== 403` clause and confirm
both go red. An assertion that stays green with the fix reverted is pinning nothing.

### 5.1 🔴 How to verify this manually — not with `curl`, and not with the DevTools Network panel

`curl` applies no CORS policy, and the DevTools Network panel renders unexposed headers anyway. **Both will
show you `X-Authz-Denied` even in a world where page JavaScript cannot read it.** The only valid check is
from the page itself:

```js
// in the browser console, on the real origin
const r = await fetch('/v3/<a gated endpoint>', {headers: {...}})
r.status                          // 403
r.headers.get('x-authz-denied')   // must be the function name, NOT null
```

Then assert the behaviour: the denial renders and **the operator is still logged in**. Full reasoning in
SBDEV-2968 §14.4.

---

## 6. Risks

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| A-R1 | Dropping 403 wholesale re-opens SBDEV-2554's init-window logout loop | High | Gate on the header, not the status. A-4 pins the header-less path. |
| A-R2 | Case-sensitive header lookup silently no-ops | Medium | A-6. axios normalises response headers to lowercase. |
| A-R3 | 2968 reverted ⇒ no header is ever emitted and the fix is inert | Low | Grep `AUTHZ_DENIED_HEADER` on the base branch first; 2968 is merged at `5506117`. |

---

## 7. Out of scope

The mobile UI's equivalent (`wms2-mobile-ui/plugins/axios.js`) is **SBDEV-2968-P10** and ships with that
plan. Each plan fixes its own repo's file.
