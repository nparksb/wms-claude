---
name: wms2-authz-axis-keycloak-coarse-functions-fine
description: "Nam 2026-08-26 DECISION: Keycloak carries only coarse access (every WMS2 user gets the wms_user group, nothing more); ALL fine-grained authorization lives in WMS V2's group->role->function model, so no business endpoint may gate on wms_admin or sb_admin"
metadata:
  node_type: memory
  type: project
---

**Decision — Nam Park, 2026-08-26. Target architecture for all wms2 authorization.**

- **Keycloak side is COARSE ONLY.** Every user who may use WMS V2 is assigned the **`wms_user`** group
  and nothing more. That group means "may reach the app" — it is not a permission.
- **WMS V2 owns fine-grained access control**, through its own `group → role → function` model in the
  tenant DB (`mywms_group` → `mywms_group_mywms_role` → `mywms_role` → `mywms_role_mywms_function` →
  `mywms_function`).
- **All WMS admins go in the `super-admin` group**, and membership there is what confers the admin
  functions. `super-admin` is a **`mywms_role`/`mywms_group`**, NOT a Keycloak group.

**Therefore, as a rule: no business endpoint may gate on `wms_admin` or `sb_admin`.** Business
authorization belongs on `FunctionEnum` functions. `@PreAuthorize(Authority.IS_SB_ADMIN)` on a
business write is the anti-pattern this decision retires — it is the reason no customer user can
configure putaway destinations today.

**Measured on `dev_wh01_om1` 2026-08-26:**
- `super-admin` **group** = **38 users**; the `super-admin` **role** holds **79 of 82** functions.
  Five further groups also map to that role (`GROUP000102/175/013/038/109`).
- The 3 functions super-admin lacks are deliberate: `MOBILE_UI_NEVER_TIME_OUT`,
  `MOBILE_UI_VIEW_LPN_ASSOCIATION`, `SPECIAL_DEVELOPER`.
- **`wms_admin` is NEITHER a `mywms_role` NOR a `mywms_group` (0 and 0).** It exists only in Keycloak.
  So "move wms_admin's access to super-admin" is a **cross-axis migration**, never a rename.

✅ **DECIDED (Nam, 2026-08-26): `/actuator/**` STAYS on `wms_admin`.** So the decision is scoped to
**business access**, and it *confirms* role matrix §1.1's target state rather than changing it — the
*"`/actuator/**` only — never business functions"* phrasing stays TRUE.

⚠ **And it could not have gone the other way.** `SecurityConfiguration:120` gates it on
`hasAnyAuthority("ADMIN", WMS_ADMIN_ROLE)`, and actuator is **per-JVM, not per-tenant** — those
requests carry no `TenantContext`, so a function check has no tenant DB to read and the mechanism
physically cannot reach. Role matrix C-1 records this. `wms_admin` therefore survives as an
ops/infra-only authority with exactly that one consumer.

This supersedes SBDEV-3017 §8.13's `wms_admin OR sb_admin` disjunction (retired) and reinstates
§8.11's function-gate design. It also resolves §8.14's B1 — the reason the disjunction could not work
is precisely this axis mismatch. See [[wms2-wms-admin-confers-zero-functions]],
[[wms2-putaway-config-is-sb-admin-only]], [[sb-admin-is-siteboss-super-admin-via-groups-claim]],
[[wms2-only-one-of-80-functions-is-enforced]].

**Audit + doc sweep done 2026-08-26.** `wms_admin` has exactly ONE enforcing site in wms2-api
(`SecurityConfiguration:120`); the gate actually blocking WMS admins is **`sb_admin`, 20 sites**
(count was documented as 18 in five places — wrong, it missed `AdminController#importUsersFromCsvText`
and `AdminActionController:341`). Three of the 20 arguably stay `sb_admin`: `AdminController:236`
(staff CSV import), `ReplenishmentReconciliationController:37` (curl-only), `AdminActionController:341`
(`/accessAudit` — gating the rollout instrument on the rollout). Dead code to delete with the
migration: `"ADMIN"` at `SecurityConfiguration:120` (a Spring Boot 2→3 placeholder from `09eb2f06`),
`Authority.getExpAppAdminGroupOrSbAdminGroup` + `getExpAppUserGroupOrAppAdminGroup` +
`NO_ASSIGN_USER_ROLE` (zero callers), `security.oauth2.app.admin.group` (bound by nothing), and rule C
at `SecurityConfiguration:130-133` (identical to rule D yet labelled "Admin-Only WMS Endpoints").
Report: `sbdocs/3-Resources/reports/260826-wms-admin-to-super-admin-authz-axis-audit.md`; plan:
SBDEV-3017-B1 §8.15.

**Migration scope fixed 2026-08-26: 17 of the 20 `IS_SB_ADMIN` sites move** — `AdminController` ×8,
`PutawayConfigController` ×3, `PutawayConfigService` ×5, `ItemDataController:105`.

**THREE STAY on `sb_admin` (Nam, 2026-08-26)** — all staff-only tools with no customer surface:
`AdminController:236` `importUserWithCsv` (`GET /v3/admin/importUsersFromCsvText` — creates loginable
Keycloak identities; caller is SiteBoss staff on a client migration), 
`ReplenishmentReconciliationController:37` (`POST /v3/reconcile-stranded-reservations`, no UI caller),
and `AdminActionController:341` `accessAudit` (the **rollout instrument** for this migration — a
function gate there gates the tool that measures the rollout).

⚠ **The argument that covers all three, and the one to reuse:** while `UserFunctionRepository`'s SDR
write stays open a function is **self-grantable**, so it is *weaker* than `sb_admin` (which arrives via
the `groups` claim and cannot be self-granted). **Moving a staff-only tool onto a function REDUCES its
protection.** So "everything onto functions" is not unconditional — staff tools are the exception.

Also dead and deletable, found 2026-08-26: `appAdminGroup` in **both** UIs' `nuxt.config.js`
(`wms2-web-ui:199`, `wms2-mobile-ui:134`, defaulting to `/wms/wh/wms_admin`) has **no runtime consumer** —
`skuData.spec.js:226` asserts `not.toContain('appAdminGroup')`, a test pinning its removal.
