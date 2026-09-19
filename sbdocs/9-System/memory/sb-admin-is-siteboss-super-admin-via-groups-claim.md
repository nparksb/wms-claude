---
name: sb-admin-is-siteboss-super-admin-via-groups-claim
description: "`sb_admin` is the SiteBoss-employee super-admin role, delivered via Keycloak GROUP membership (the `groups` claim, NOT resource_access); customer WMS users only ever get wms_user and/or wms_admin."
metadata: 
  node_type: memory
  type: project
  originSessionId: f184cbe7-1bd3-4105-8a34-9f2b9e55d6f3
  modified: 2026-08-12T01:08:46.727Z
---

Told directly by Nam, 2026-08-11:

- **`sb_admin` = super-admin, assigned to SiteBoss employees** — SiteBoss is the company that owns this
  product. Same authority as an app admin, plus everything gated on it.
- **Customer WMS users are only ever assigned `wms_user` and/or `wms_admin`.** They never hold
  `sb_admin`. So every `@PreAuthorize(Authority.IS_SB_ADMIN)` endpoint is **SiteBoss-staff-only by
  design** — "a WMS admin sees this control disabled" is intended, not a bug, and not something to
  re-litigate per ticket.
- ⚠ **It arrives via Keycloak GROUP membership → the `groups` claim, NOT under `resource_access`.**

**Why the delivery mechanism is the load-bearing part.** `JwtAccessTokenCustomizer.extractRoles`
(wms2-api) flattens *both* `resource_access.<every client>.roles` **and** every entry of `groups` into
the granted authorities that `hasAuthority('sb_admin')` tests. But `keycloak-js`'s
`hasResourceRole(role, clientId)` reads `resource_access[clientId].roles` **only** — a group membership
is not there. So a client-side `hasResourceRole('sb_admin', …)` returns **false for every real
`sb_admin`, on every tenant, permanently**, regardless of `KEYCLOAK_CLIENT`.

SBDEV-2732's first Phase 2 UI gate did exactly that; the control would never have enabled for anyone
entitled to it. **Any client-side `sb_admin` check must read the `groups` claim** — mirror
`extractRoles` (see `wms2-web-ui/util/keycloakRoles.js`). Note no test caught this: every `$kc` mock
was synchronously-ready and returned `true`, so the suite asserted the answer it was checking.

**Escape hatch that exists but is unused:** `Authority.getExpAppAdminGroupOrSbAdminGroup(...)` and
`getExpAppUserGroupOrAppAdminGroup(...)` are defined and called nowhere; they render
`hasAuthority('X') or hasAuthority('Y')`. That is where a `wms_admin`-or-`sb_admin` expression would go
if product ever wants WMS admins to self-serve something currently sb_admin-gated. Product decision,
not a defect.

Canonical doc: `sbdocs/3-Resources/architecture/wms2-keycloak-role-matrix.md` §2.1 — updated 2026-08-11
with all of the above, and its gate count corrected 9 → **18** (SBDEV-2732 added 9: 3
`PutawayConfigController`, 5 `PutawayConfigService`, 1 `ItemDataController`).

Related: [[wms2-businessexception-key-vs-message-traps]],
[[verify-spring-bean-changes-clean-compile-and-context-load]].

## ⚠ CORRECTION 2026-08-26 — the mechanism here is wrong

Measured on kc2.dev.sbo.li realm `wineco` with a real `sb_admin` (`panderson`): the token carries
`groups: ['/sb_admin', ...]` — a FULL PATH, which `hasAuthority('sb_admin')` does **not** match — and
`resource_access[om1-api].roles: ['wms_admin','sb_admin','wms_user']`, **bare**. So the gate passes via
**resource_access**, not via the groups claim, and **`hasResourceRole` CAN see `sb_admin`** (under the
`om1-api` client, not the `om1` auth client — that clientId mismatch is the real reason the SBDEV-2732
UI gate failed, not the groups-claim story). See
[[wms2-keycloak-groups-claim-emits-full-paths]] for the full probe and the load-bearing risk.
