---
name: wms2-only-one-of-80-functions-is-enforced
description: "SUPERSEDED on develop 2026-08-24 — server-side function gating is now live and verified with a real 403; the original 2026-08-15 audit (1 of 80 enforced) describes main/prd only"
metadata: 
  node_type: memory
  type: project
  originSessionId: d594027c-8456-4059-886b-9bb9c11c997b
  modified: 2026-08-16T01:55:02.851Z
---

## ⚠️ SUPERSEDED ON `develop` — verified live 2026-08-24

**"1 of 80 enforced" and "no `MOBILE_UI_VIEW_*` is checked anywhere" are NO LONGER TRUE on `develop`.**
Measured against `wms-api.dev.sbo.li`, tenant wineco/wsl, with a two-sided differential:

| user | endpoint | result |
|---|---|---|
| `sbtest` (lacks fn) | `GET /v3/picking/pickTimeOutValue` | **403**, `X-Authz-Denied: MOBILE_UI_VIEW_PICKING`, body `reason: MISSING_FUNCTION` |
| `panderson` (holds fn) | same | **200** |
| `sbtest` | `/v3/truckLoading/orderList`, `/v3/cancellation/list` | **403** + the matching function name |
| `sbtest` | `/v3/lookup/search/…` (fn it DOES hold) | **200** |

Both controls hold, so the denial is the *function*, not the endpoint and not the token.
`FunctionGuardInterceptor` reaches requests via a `MappedInterceptor` bean
([[wms2-sdr-is-gatable-via-mappedinterceptor-bean]]); **14** controllers are in its `GUARDED` set.

**Two caveats that keep this memory relevant:**
- ⚠ **CORRECTED 2026-09-01 — this caveat is now wrong and it inverts the memory's usefulness.**
  Enforcement is **no longer `develop`-only**: `FunctionGuardInterceptor` ships at tag `v0.0.21`, the build
  running on prd, and `origin/main` carries **161** `@RequiresFunction` sites (develop has 177). So the
  audit below does **NOT** describe production any more — production is gated. Treat a gating gap on
  `develop` as a prd concern once released, not a hypothetical. See
  [[wms2-gating-programme-is-live-on-prd]].
- The `X-Authz-Denied` header + `reason` body field are populated and both UIs read them (SBDEV-2967-A/-C).
  Do not re-file that as a gap — I filed SBDEV-3078 on that false premise and closed it as invalid.

**Updated "how to apply":** grep `@RequiresFunction` **and** `FunctionGuardInterceptor.GUARDED` — not just
`doesUserHaveAccess`. A controller outside `GUARDED` with no annotation still falls through **allowed**
([[wms2-function-gate-anti-drift-only-covers-guarded-classes]]).

---

## Original audit — 2026-08-15, still accurate for `main`/prd

The v2 `WmsConstants.FunctionEnum` access model (80 constants → `mywms_function` → role → group → user) is
almost entirely **decorative**. Audited 2026-08-15 on develop; filed as SBDEV-2967 (web, high) and
SBDEV-2968 (mobile, normal).

- **`wms2-web-ui` has no authorization layer at all.** `layouts/default.vue:284-285` returns
  `menuList["super-admin"]` unconditionally, so all 30 menu items — Admin included — render for every
  authenticated user. 4 of the 5 persona menus in `util/appMenuList.js` are dead code. `store/index.js:92-101`
  fetches `/user/getAllRoles/{username}` and **discards it**. No `middleware/`, no route guards.
  `pages/admin.vue:51-58` hardcodes all 6 tabs including User Management.
- **`AccessService.doesUserHaveAccess()` has 5 call sites, all passing the same constant**
  (`WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`): `StockunitService:232`, `MobileMoveStockService:251,256`,
  `MobileMoveUnitloadService:277,282`. No `MOBILE_UI_VIEW_*` is checked anywhere. **1 of 80 enforced.**
- **Only real gate in either UI:** `wms2-mobile-ui/store/home.js` menu filter (client-side only).

**Why:** the constants read like gates and the docs described them as "service-level FunctionEnum checks",
so it is very easy to assume a page or action is protected when nothing checks it. This burned the
role-matrix doc itself — §3.7 claimed all 8 `WEB_UI_ACTION_*` were enforced; 7 were not.

**How to apply:** never infer enforcement from a `WEB_UI_*` / `MOBILE_UI_*` constant existing, being seeded
to a persona, or appearing in a menu — grep `doesUserHaveAccess` and `@PreAuthorize` for the actual gate.
Adding a constant creates provisioning metadata only. Before enabling web-menu filtering, note live tenants
have drifted badly (Hydra UAT: 15/19 users in `super-admin`; WineCo dev: custom `CS-REP` role, 39/96 in
`super-admin`) — filtering will hide pages from real users, so ship it sysprop-gated default-OFF.

Full inventory in `sbdocs/3-Resources/architecture/wms2-keycloak-role-matrix.md` §3.9 (web menu), §3.8
(mobile), §4.1 (live drift). Related: [[sb-admin-is-siteboss-super-admin-via-groups-claim]],
[[wms2-controller-mappings-must-carry-v3-standalonesetup-cannot-see-it]].
