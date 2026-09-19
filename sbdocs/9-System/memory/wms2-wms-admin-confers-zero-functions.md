---
name: wms2-wms-admin-confers-zero-functions
description: "Widening a wms2 @PreAuthorize to wms_admin cannot unlock a screen — the web UI gates screens on FUNCTIONS via require-function.js, and wms_admin confers zero functions; also no test lane in the repo evaluates @PreAuthorize at all"
metadata:
  node_type: memory
  type: project
---

Found 2026-08-26 reviewing SBDEV-3017 §8.13 (putaway config off `sb_admin`). **Two axes, routinely
confused:**

- **Keycloak group authorities** (`wms_user`, `wms_admin`, `sb_admin`) — arrive in the `groups` claim,
  harvested by `JwtAccessTokenCustomizer.extractRoles`, tested by `@PreAuthorize`/`hasAuthority`.
- **`FunctionEnum` functions** (`WEB_UI_VIEW_*`, `WEB_UI_ACTION_*`) — tenant-DB rows reached by
  `user → group → role → function`. `super-admin` is a **`UserRole` row**, NOT a Keycloak group.

**`wms_admin` confers ZERO functions.** So widening a `@PreAuthorize` to `wms_admin` does not let that
user reach the screen: `wms2-web-ui/middleware/require-function.js:32-80` is a live fail-closed route
guard reading `store.state.functions` (`store/index.js:175-220` ← `getAllRoles/<username>`);
`util/appMenuList.js:98` gates SKU Data on `WEB_UI_VIEW_ITEM_DATA`; `pages/admin.vue:55-63` gates
Parameters & Configuration on `WEB_UI_VIEW_SYSTEM_PROPERTY` and Shippers on `WEB_UI_VIEW_CLIENT`. The
redirect to `/not-authorized` happens **before any request reaches the annotation**.

⚠ **Under OR-semantics (`wms_admin` OR `sb_admin`) the failure is SILENT** — a pure widening 403s
nobody, so a wrong population guess yields today's behaviour with a fully green suite. Every AC can
pass against a synthetic token while the real user stays locked out.

The role matrix records the general lesson (§2.1 📌): *"When a new guard lands on a different axis from
the one that already grants access, prefer moving the guard onto the existing axis over verifying that
the two populations coincide."*

**Separately, and reusable everywhere:** **no test lane in wms2-api evaluates `@PreAuthorize`.** Not a
trap — a structural absence, asserted in src/main and src/test alike (`UserAdministrationController:56-60`
"no controller test in this repo evaluates @PreAuthorize", `BaseControllerUnitTest:82`,
`FunctionGuardArchTest:778` and `:214`). `standaloneSetup` installs no method-security advisor and the
`@SpringBootTest` web lane is still blocked. So a `@PreAuthorize` change is **live-probe-only**; the
substitutes are named reflection assertions on `Method.getAnnotation(PreAuthorize.class).value()` plus
`CustomMethodSecurityExpressionRootUnitTest`'s production-faithful `evaluate(...)` harness (`:433-459`).
This is a stronger version of [[wms2-function-gate-anti-drift-only-covers-guarded-classes]]'s
`setupMockMvc` trap: there an honest lane exists, here there is none.

Also: a `@PreAuthorize` 403 carries no `X-Authz-Denied` (`Authority.java:90` — emitted by
`FunctionGuardInterceptor` and nowhere else), so it misses axios's clean denial path
(`plugins/axios.js:39-66`) and lands on **silent no-op** or forced logout. Merge API before web-ui.

See [[wms2-putaway-config-is-sb-admin-only]], [[sb-admin-is-siteboss-super-admin-via-groups-claim]].
