---
name: wms2-mobile-kc-facade-logout-never-ends-sso
description: "wms2-mobile-ui $kc.logout() nulls keycloakInstance before calling ?.logout — always a local reload, never an IdP logout; check-sso re-signs the same user"
metadata:
  node_type: memory
  type: project
  originSessionId: 4f730ef6-ac41-4240-99fc-f26d5d7db864
  modified: 2026-09-25T22:04:45.298Z
---

`v2/wms2-mobile-ui` `plugins/keycloak.client.js` façade `logout()` sets `state.keycloakInstance = null`
and THEN runs `state.keycloakInstance?.logout(opts) || window.location.replace(redirectUri)` — so it is
always just a reload. With `onLoad: 'check-sso'` the same Keycloak session signs the same user back in.
(The internal `logout()` further down captures `kc` first and does end the session.)

Consequences found 2026-09-26 (SBDEV-3518, WineCo ST#1268 "mobile lag"):
- Every workflow exit (`home/refreshMenus`) was a full app reload — the lag. Fixed on branch
  `bugfix/SBDEV-3518-mobile-exit-no-reload` by resetting every module's `resetState` in-app.
- The **Logout button** (`layouts/default.vue`, `layouts/no-tenant.vue`) uses the same façade, so it does
  NOT hand a shared handheld to the next operator. FILED 2026-09-26 as **SBDEV-3534** (T2, High, Nam's
  call). Keycloak `om1` accepts every `/mobile` post-logout URI on dev/UAT/prd — probe the public
  logout endpoint with `post_logout_redirect_uri` + no session: 302 to the URI = allowed, 400 = not.
  Web UI façade is NOT affected. Test M6 in keycloak-logout-clears-state.spec.js pins the buggy path.
- The in-app exit no longer discards in-flight responses; the late-response race was accepted as a Medium.
- SBDEV-3534 fix = PR wms2-mobile-ui #73 (2026-09-26). Second trap it found: keycloak-js 26 fires
  `onAuthRefreshError` BEFORE a failed `updateToken` rejects, and that handler already runs a real logout.
  So any `catch` around `updateToken` that logs out AGAIN navigates over the IdP redirect. Three such
  catches existed (axios retryCondition, the 60s interval, onTokenExpired); all are now guarded. On a 400
  refresh, `clearToken()` → `onAuthLogout` nulls the instance first → bare reload (accepted by Nam).
- wms2-web-ui checked 2026-09-26: NOT affected by the null-before-call bug (its instance is never nulled;
  3/3 headless runs end on the Keycloak login form). BOTH apps share a narrower bug: tapping Logout while
  init is still running (`authenticated:false`, no idToken) sends a logout with no `id_token_hint` →
  Keycloak's "Do you want to log out?" page. If the user doesn't tap it, the session survives (3/3 on each
  app). FILED 2026-09-26 as **SBDEV-3538** (T2, Normal, both repos). PRs web #146 / mobile #74. The
  "just await ready" fix needed 4 more pieces that reviews found, and each one applies to ANY logout change:
  bound the wait (keycloak-js silent check-sso has NO timeout); don't log out if init settles unauthenticated
  (init is already navigating to login); clear storage again on `pagehide` (the page lives until the IdP
  redirect completes, so late writers run); and once a logout starts, a late-settling init must stop (on
  mobile it crashes into the unknown-tenant redirect). Web menus also did `router.push('/')` before logout,
  which remounted Home and re-wrote the vuex blob (security High). Headless trap: "app shell visible" ≠ signed in;
  wait for `$kc.authenticated` to stay true, or the verdict inverts.

**How to apply:** never read "calls `$kc.logout()`" in this app as "the user is logged out". Related:
[[sbdev-2930-mobile-page-reset-and-picking-timer-landmine]], [[wms2-ui-openobserve-rum-rollout]].
