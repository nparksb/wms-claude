---
name: wms2-response-reset-strips-cors-headers
description: "In wms2-api, response.reset() in a controller error path strips the CORS headers Spring Security already wrote, so the browser blocks the error and the UI shows its generic network toast — use resetBuffer()"
metadata: 
  node_type: memory
  type: project
  originSessionId: c4efefbe-0109-422d-bcbf-bd1fa5a73aca
  modified: 2026-08-18T00:04:15.927Z
---

**wms2-api: never call `response.reset()` in a controller that writes its own error body. Use
`response.resetBuffer()`.**

Verified 2026-08-02 while planning SBDEV-2632 (cycle count bulk export). CORS is wired through
**Spring Security's** filter — `SecurityConfiguration.java:100` `.cors(cors -> cors.configurationSource(corsConfigurationSource()))`,
source at `:150-156` — so `CorsFilter` runs **before** the DispatcherServlet and
`DefaultCorsProcessor.handleInternal` has already physically written `Access-Control-Allow-Origin`
(and `Access-Control-Expose-Headers`) onto the response by the time the handler executes. It ends in
`response.flush()` → `ServletServerHttpResponse.writeHeaders()` → `addHeader`, which does **not**
commit the response.

`ServletResponse.reset()` is specified to clear "the buffer, the status code, **and the headers**".
So a `reset()` in an error path wipes those CORS headers → **the browser blocks the response** →
axios rejects with **no `error.response`** → any "read the JSON error body" logic falls through to its
generic fallback. Net effect: a carefully-built 422 surfaces to the operator as
`"Error: Request failed due to a network or server issue. Please retry."` — i.e. indistinguishable
from the bug you were fixing.

`resetBuffer()` clears only the body buffer, leaving headers and status intact.

**Why this is easy to ship broken:** MockMvc has **no `CorsFilter`**, so no controller unit test
catches it. It only manifests in a real browser against a real origin. Guard it explicitly — pre-seed
a `MockHttpServletResponse` with `Access-Control-Allow-Origin` and assert it survives the error path
(`MockHttpServletResponse.reset()` does clear headers while `resetBuffer()` does not, so the test has
real teeth).

**⚠ Verifying CORS exposure: `curl` and DevTools are both INADMISSIBLE.** Found 2026-08-17 re-scoping
SBDEV-2968's `X-Authz-Denied` header. The failure mode is "header emitted but JS cannot read it", and
neither instrument is subject to CORS filtering: **`curl` applies no CORS policy at all**, and the
**DevTools Network panel renders every response header regardless of exposure** — CORS restricts what
*JavaScript* may read, not what tools display. So both go green against a browser-blind config. The
only discriminating checks are JS `response.headers.get('x-…')` returning non-null, or the behaviour
itself. A cross-origin `curl -H 'Origin: …'` looks like the obvious verification and is worthless;
it was drafted twice into SBDEV-2968's manual matrix before this was noticed. Corollary: an
*unauthenticated* cross-origin request still shows `Access-Control-Expose-Headers` on its 401
(`CorsFilter` precedes authentication), which tempts a credential-free check — but with an
override-proof `addExposedHeader` there is no env drift for it to catch, so such a row can never fail.

**Local dev IS cross-origin for both UIs — check before relying on it.** `wms2-mobile-ui`'s
`nuxt.config.js` declares `modules: ['@nuxtjs/axios', '@nuxtjs/toast']` with **no `@nuxtjs/proxy`**,
and `axios.baseURL` is `http://localhost:8088/v3` while the app serves on `:3001` — different port,
different origin, CORS in full force. That makes a laptop a valid test bed for this whole defect
class. It is also fragile: **adding a Nuxt dev proxy would make every request same-origin and hide
all of it locally** while every test stayed green.

**Related:** `rest.security.cors.exposed-headers` **now exists** in `application.properties:106`
(`X-Export-Skipped-Cycle-Counts`) — added when SBDEV-2632 shipped; the earlier note here that it was
absent described pre-fix state. `allowed-origin-patterns` at `:98` is
`http://localhost:3000,http://localhost:3001,https://*.sbo.li`. Because the property is now populated,
the `contains()` de-duplication guard around `addExposedHeader` is load-bearing rather than
theoretical. The web UI is cross-origin in every deployed env
(`wms.<tenant>.dev.sbo.li` → `wms-api.<tenant>.dev.sbo.li`; `nuxt.config.js` `browserBaseURL`). If you
add a custom response header, the property alone is overridable by
`REST_SECURITY_CORS_EXPOSED_HEADERS`; prefer `configuration.addExposedHeader(...)` in
`corsConfigurationSource()` — additive, override-proof, and gateable by a verify row. Note
`allowed-headers=*` governs **request** headers and does not help.

Also: axios lower-cases response header names, so read `'x-export-skipped-cycle-counts'`, not the
mixed-case form.

See [[sbdev-2632-cycle-count-bulk-export-multi-id-500]].
