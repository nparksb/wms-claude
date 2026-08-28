---
title: "Audit — moving WMS2 admin access off Keycloak groups onto the super-admin role"
type: report
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-26
updated: 2026-08-26
status: "COMPLETE — §1 ANSWERED 2026-08-26: /actuator/** stays on wms_admin, so the decision is scoped to business access and CONFIRMS role matrix §1.1. All §7 doc rewrites applied except item 10 (verify scripts, correct until the migration lands). Central finding: `wms_admin` grants almost nothing; the gate actually blocking WMS admins is `sb_admin`, 20 @PreAuthorize sites."
db_verified: true
db_verified_rationale: "Role/group/function populations and the absence of wms_admin from mywms_role and mywms_group measured on dev_wh01_om1 (wms2-wineco-dev) 2026-08-26 — see §3."
related:
  - SBDEV-3017-B1-mvc-write-surface-gating.md
  - wms2-keycloak-role-matrix.md
tags: [report, security, authorization, keycloak]
---

# Moving WMS2 admin access onto `super-admin` — audit

**The decision being audited (Nam Park, 2026-08-26).** Keycloak carries only coarse access: every WMS2
user is assigned the **`wms_user`** group and nothing more. **WMS V2 owns all fine-grained access
control** through its own `group → role → function` model. All WMS admins go in the **`super-admin`**
group, and membership there confers the admin functions. Access currently given to `wms_admin` is to
move to the `super-admin` role.

Graded on `origin/develop` (`wms2-api` @ `353a348`, `wms2-web-ui` @ `685546d`), plus a full sweep of
`sbdocs`, plus live queries on `dev_wh01_om1`. Working trees never read — `wms2-web-ui`'s was 29
commits behind.

---

## 1. The finding that reframes the instruction — and the actuator carve-out

**`wms_admin` grants almost nothing today. It has exactly ONE enforcing site in the entire wms2-api
codebase:** `SecurityConfiguration.java:147`, the `/actuator/**` matcher. Every other occurrence — 12
sites in the API, 125 hits across 18 vault files — is javadoc, history, a dead test property, an
inert test fixture, or a *proposal*.

**The gate that actually blocks WMS admins is `sb_admin`, not `wms_admin`:** 20
`@PreAuthorize(Authority.IS_SB_ADMIN)` sites. That is the population your decision needs to move.

So the audit's answer to "change the access given to `wms_admin` to `super-admin`" is:

| | Sites | Action |
|---|---|---|
| **`sb_admin` business gates** | **20** `@PreAuthorize(IS_SB_ADMIN)` | ✅ **This is the migration.** Move onto `FunctionEnum` functions granted to `super-admin` |
| **`wms_admin`** | 1 live gate (`/actuator/**`) | ✅ **Stays put** by decision — it also *cannot* move; see below. Everything else is docs to correct |

✅ **ANSWERED (Nam, 2026-08-26): `/actuator/**` stays on `wms_admin`.** The decision is scoped to
business access, so it **confirms** role matrix §1.1's target state rather than changing it, and the
*"`/actuator/**` only"* phrasing stays true. The reasoning that led there is kept below.

**And it could not have gone the other way.** Role matrix C-1 and the code agree: actuator is
**per-JVM, not per-tenant**. `TenantFilter:40-49` derives the tenant *only* from the `X-Tenant-ID` +
`facility_code` headers, which Prometheus scrapers, k8s probes and CI do not send, so `TenantContext`
is `null` and `TenantDynamicRoutingDataSource:49-54` routes to the **landlord** DB — where
`mywms_user` / `mywms_function` do not exist. A function check there yields PostgreSQL `42P01` →
**HTTP 500, not 403**, so header-less monitoring would break loudly and misleadingly. Nor can it drop
to `permitAll`: it exposes metrics, pool and tenant-topology data. So `wms_admin` survives as an
**ops/infra-only authority with exactly one consumer**, `SecurityConfiguration:147`.

**Same constraint, same answer, for every other surface that cannot resolve a tenant:**
`/api/public/**` (explicitly skipped by `TenantFilter:34-38` — it *resolves* the tenant, so it cannot
presuppose one), `/error` (context already cleared by the `finally` at `:53-55`), `/rest/**` (OMS
sends no Keycloak JWT at all), and `IdempotencyFilter`, which runs before `AuthorizationFilter` and
must therefore check an **authority**, never a tenant-DB function.

---

## 2. What the decision vindicates

Worth recording, because it means this is not a reversal but a completion:

- Role matrix §1.1 already contains the verbatim rule — *"configuring default putaway locations is a
  **WMS application admin (`super-admin`)** responsibility, not a SiteBoss one — and, more broadly,
  **there is currently no function that should be restricted to `sb_admin`.**"*
- `Authority.java:53-60` already states it: *"business authorization belongs on `FunctionEnum`
  functions."*
- `UserAdministrationController:42` records the same reasoning as precedent: gating on the
  `wms_admin` group *"would have put the API gate on a second, independent axis from the one that
  grants the screen."*
- SBDEV-2870's redesign onto `WEB_UI_VIEW_USER_MANAGEMENT` and SBDEV-1921's rejection of `wms_admin`
  for a mobile menu item are both instances of the same rule.

It also **resolves SBDEV-3017 §8.14's blocking finding B1** in the reviewers' favour, and retires
§8.13's `wms_admin OR sb_admin` disjunction — written the same day, and the only place in the vault
that was prescribing *new* `wms_admin` gating.

---

## 3. DB evidence — `super-admin` is real, populated, and already holds nearly everything

Measured on `dev_wh01_om1`, 2026-08-26:

| Fact | Value |
|---|---|
| `super-admin` **group** members | **38 users** |
| `super-admin` **role** → functions | **79 of 82** |
| Other groups mapping to the `super-admin` role | 5 (`GROUP000102`, `000175`, `000013`, `000038`, `000109`) |
| `wms_admin` as a `mywms_role` | **0** |
| `wms_admin` as a `mywms_group` | **0** |
| Functions `super-admin` lacks | 3, all deliberate: `MOBILE_UI_NEVER_TIME_OUT`, `MOBILE_UI_VIEW_LPN_ASSOCIATION`, `SPECIAL_DEVELOPER` |

Next tier down for scale: `inventory-manager` 34 functions / 11 users; `CS-REP` 28 / 4;
`outbound-manager` 26 / 10; `receiving` 16 / 7.

**`wms_admin` exists only in Keycloak.** So this is a **cross-axis migration**, never a rename — which
is exactly why §8.13's disjunction could not have worked.

---

## 4. The 20 `sb_admin` sites — the actual migration surface

| Class | Sites | Notes |
|---|---|---|
| `AdminController` | 9 — `:79, :107, :120, :133, :142, :154, :175, :236, :246` | `:236` is `importUsersFromCsvText`; its javadoc (`:197-201`) records that its caller is **SiteBoss staff**, so it is the one site that may legitimately stay `sb_admin` |
| `PutawayConfigService` | 5 — `:96, :128, :165, :257, :287` | `:257`/`:287` are the HAL/SDR channel boundaries |
| `PutawayConfigController` | 3 — `:183, :215, :233` | tiers 1/2/3 |
| `ItemDataController` | 1 — `:105` | `setPutAwayLocation`, a **`@GetMapping`** |
| `AdminActionController` | 1 — `:341` | `/accessAudit` — the rollout instrument; gating it on a function would gate its own audit tool |
| `ReplenishmentReconciliationController` | 1 — `:37` | curl-only support tool, no UI |

✅ **DECIDED — NINE stay on `sb_admin`** (three 2026-08-26; +`PutawayConfigService:258`/`:288` by §8.16.5; +the four `AdminController` identity WRITES 2026-08-27, §9.14) — `AdminController:237`,
`ReplenishmentReconciliationController:37` and `AdminActionController:341`. **So the migration surface
is ~~17~~ ~~15~~ **9 of 20** — SBDEV-3017 §8.16 found that `PutawayConfigService:257` and `:287` cannot be
function-gated **by annotation** at all (reached from SDR event handlers, where `@RequiresFunction` is
inert), and §8.16.5 decided 2026-08-26 (option **(a)**) that they are **carved out** and keep
`@PreAuthorize(IS_SB_ADMIN)`. So **11 stay, 9 move** (revised 2026-08-27: all four AdminController identity WRITES stay — SBDEV-3017 §9.14). Programmatic gating was considered and rejected
as a net regression while function grants remain self-grantable (§8.16.6). The 7 that move: `AdminController` **×0 — it moves nothing** (§9.18), `PutawayConfigController` ×3, `PutawayConfigService` **×3** (`:97`, `:129`, `:166` — **not** `:257`/`:287`),
`ItemDataController:105`.

All thirteen are staff-only tools or sites where the annotation is inert with no customer surface, and one argument covers all of them: while
`UserFunctionRepository`'s SDR write stays open a function is **self-grantable** and therefore *weaker*
than `sb_admin`, which arrives via the `groups` claim. Moving them onto functions would reduce their
protection. `AdminActionController:341` has an additional reason — it is the **rollout instrument** for
this migration, so a function gate there gates the tool that measures the rollout.

⚠ **STALE MECHANISM (corrected 2026-08-27):** the claim that a function is self-grantable *because `UserFunctionRepository`'s SDR write is open* stopped describing a live route when **PR #209** withdrew those verbs. The real mechanism is stronger: `UserController.saveUserGroups:536` accepts **any** `userId` with no self-scope, so `WEB_UI_VIEW_USER_MANAGEMENT` is the **root of the function lattice** — any holder can grant themselves every other function in one request. `sb_admin` is unreachable from WMS *structurally* (only `/wms_user` and `/warehouse/<facility>` are joinable, matched by exact path). See SBDEV-3017 §9.14.4 / §9.15.

---

## 5. Dead code the audit surfaced — delete alongside

| Item | Evidence | Why |
|---|---|---|
| `"ADMIN"` in `SecurityConfiguration:147` | Traced to commit `09eb2f06`, *"Simplified - you may need custom authority mapping"* — a Spring Boot 2→3 migration placeholder its own author flagged | Unreachable. Authorities come only from `resource_access.*.roles` + `groups` verbatim; no Keycloak role or group named `ADMIN` exists anywhere. `@WithMockUser(roles={"ADMIN"})` prefixes to `ROLE_ADMIN` and would not match either |
| `security.oauth2.app.admin.group=wms_admin` (`src/test/resources/application.properties:93`) | No `@ConfigurationProperties(prefix="security.oauth2")` anywhere; `SecurityProperties` binds `rest.security` only; `KeycloakService.getAdminGroupPath()` no longer exists | Bound by nothing |
| `Authority.getExpAppAdminGroupOrSbAdminGroup`, `getExpAppUserGroupOrAppAdminGroup`, `NO_ASSIGN_USER_ROLE` | **Zero** consumers in `src/main` **and** `src/test` | The first is the helper §8.13 was going to use; with this decision it should be deleted, not called |
| **Rule C**, `SecurityConfiguration:157-160` | Requires `hasAnyAuthority(WMS_USER_ROLE)` — **identical** to rule D at `:151`, and all but three of its patterns already fall under `/v3/**`. The three un-prefixed ones (`/userDetailsById/**`, `/userGroup/**`, `/user/**`) match no controller | Changes no outcome anywhere, yet its section comment reads **"Admin-Only WMS Endpoints"** — false, and the kind of thing a reader trusts |
| `appAdminGroup` in **both UIs** — `wms2-web-ui/nuxt.config.js:199`, `wms2-mobile-ui/nuxt.config.js:134`, both defaulting to `/wms/wh/wms_admin`, plus the env-var note at `wms2-web-ui/CLAUDE.md:70` | **No runtime consumer in either UI.** The only other hit is `test/components/masterData/material/skuData/skuData.spec.js:226` — `expect(s).not.toContain('appAdminGroup')` — a test **pinning its removal** (SBDEV-2643 r5 and earlier used `affiliatedGroups.includes($config.appAdminGroup)`, then moved off it) | ⚠ **Found 2026-08-26 when Nam reviewed the site list; the first audit pass was API-only and missed both UIs.** Deleting the config keys cannot regress anything — a test already asserts the identifier is absent from the component. The `CYPRESS_WMS_ADMIN_*` names in `admin.cy.js` are test-run toggles, unrelated to the group — **leave those** |
| `Authority.getExpForRole(String)` | **Zero** consumers in `src/main` (the only mention is a javadoc reference in `PutawayConfigService:38`); used solely by `CustomMethodSecurityExpressionRootUnitTest:463,469` | Test-only helper. Delete it **with** those two test cases, or keep both — do not leave a security helper alive for tests alone. Lower priority than the rest: unlike `getExpAppAdminGroupOrSbAdminGroup` it is not a loaded gun, since nothing has ever proposed calling it |
| `ClientControllerLegacyIntegrationTest:146` | A commented-out `//.with(user("functional_test_user")…roles("wms_admin")` inside an already-inactive block | Dead commented code carrying a `wms_admin` reference that a future grep will surface as a live gate. Delete the line |

⚠ **One item that looks deletable and is NOT.** `TenantPoolEndpointSecurityTest:66-73` is `@Disabled` with
an **empty body** and a reason string saying *"The `/actuator/**` ADMIN/wms_admin (403 vs 200) assertion is
added at implementation time"* — which never happened. So **no test anywhere asserts the actuator authority
rule**, which is exactly why a regression there would be silent. Now that `/actuator/**` is a settled,
permanent carve-out (§1), that test should be **implemented, not deleted** — it is the only tripwire the one
remaining `wms_admin` gate could ever have. Same for `UserControllerUnitTest:808,815`: its
`Arrays.asList("wms_user", "wms_admin", "picking_user")` fixture is semantically wrong (that query returns
`mywms_function.name` rows, not Keycloak groups) but authorization-inert — **fix the fixture, do not delete
the test**.

---

## 6. Doc drift found — two claims are already false in code

| Site | Claim | Reality |
|---|---|---|
| `AdminController:183` | `// SBDEV-2870 — gated on wms_admin 2026-08-16` | The annotation on that method is `@PreAuthorize(Authority.IS_SB_ADMIN)` (`:236`) |
| `UserAdministrationController:76` | *"`/admin/importUsersFromCsvText` … stays on `wms_admin` in `AdminController`"* | Same — the code says `sb_admin` |

Both predate this decision and should be corrected regardless.

---

## 7. Docs to rewrite, ranked — a reader acting on these does the wrong thing

1. **`wms2-keycloak-role-matrix.md:188-190`** — *"Treat 'a WMS admin sees this control disabled' as
   intended, not a bug."* An imperative telling the next reader to close this decision's originating
   complaint as working-as-intended. **Rewrite first.**
2. **`SBDEV-3017-B1` `status:` + §8.13** — stamp the disjunction SUPERSEDED. It is a live DRAFT a
   fresh session would implement, and §8.13.5 would have them edit the role matrix in the *wrong*
   direction. *(Done — see §9.)*
3. **Role matrix §2.1 "Unused escape hatch" box (`:208`) and its duplicate at `SBDEV-2732:2605`** —
   both name `getExpAppAdminGroupOrSbAdminGroup` as the sanctioned answer for WMS admins self-serving
   putaway config. Record as considered-and-rejected 2026-08-26.
4. **Role matrix `:94`, plus verbatim copies at `SBDEV-2968:893` and the path table at `:686`** — the
   *"`/actuator/**` only — never business functions"* row. Edit all three in lockstep, **and only
   after §1's question is answered.**
5. **Role matrix `:334` and `:716`** — still assert `:190` is gated on `wms_admin`. Superseded
   2026-08-17.
6. **`wms2-project-analysis.md:286`** — a **fabricated** `@PreAuthorize("hasAnyAuthority('ADMIN','wms_admin')")`
   presented as v2's authorization model. Delete.
7. **`1-Projects/wms2/plan/README.md:64`** — the MOC entry still recommends *"`wms_admin`, not
   `sb_admin`, per the target state."*
8. **The "18 active gates" count** at role-matrix `:74, :122, :213, :334, :716` — actual is **20**,
   and it changes again as gates re-home. Fix once.
9. **`9-System/templates/wms-plan-template.md:104`** — row 7's example teaches "add a role to the app
   admin group". Every new plan copies it.
10. **`verify-SBDEV-{2643,2732}-*.sh`** — pin `@PreAuthorize(IS_SB_ADMIN)` on the putaway sites and go
    red on merge. Mechanical, but they will look like a broken migration.

`verify-SBDEV-2870-*.sh` rows A2/A3/A4/B5/C5 — which pin `IS_WMS_ADMIN` as deleted and
`WMS_ADMIN_ROLE` to exactly one consumer — would have been **broken by §8.13** and are **rescued** by
this decision. Leave them.

**Do not edit** (append-only history): role-matrix §10 log rows; `SBDEV-2870` §11.x revert records;
`SBDEV-1921:953`; `SBDEV-3003:756`; `SBDEV-3013:97`; retired verify scripts; all v1 docs.

---

## 8. What the migration still needs before implementation

Carried from SBDEV-3017 §8.14, all still binding:

1. **The self-grant hole is a slice-wide blocker.** `UserFunctionRepository`'s SDR write is open, so
   any `wms_user` can grant themselves a function. Until it closes, **a function gate is weaker than
   `sb_admin`** — which arrives via the `groups` claim and cannot be self-granted. This decision does
   not change that; it makes closing it a prerequisite.
2. **`FunctionGuardInterceptor` is absent from `origin/main`** (branches diverged 39/112), so
   `@RequiresFunction` is inert in production. Dropping `@PreAuthorize` before the interceptor ships
   un-gates the endpoints on prd. **Merge order is load-bearing.**
3. **No test lane in this repo evaluates `@PreAuthorize`** (`UserAdministrationController:56-60`,
   `BaseControllerUnitTest:82`, `FunctionGuardArchTest:778`). Gate changes are live-probe-only;
   substitutes are named reflection assertions plus
   `CustomMethodSecurityExpressionRootUnitTest.evaluate(...)`.
4. **A separate live defect, unrelated to this decision but on the same surface:** a plain `wms_user`
   can silently remove the tier-3 putaway default, unaudited, by **renaming** the guarded syskey over
   SDR — both hooks branch on the *merged incoming* entity. Needs its own ticket.
5. **Web UI must move in step.** `resolveSbAdmin` (`util/keycloakRoles.js:70`) and its two callers
   gate on the Keycloak axis; the screens are already function-gated by `require-function.js`. Merge
   **API before web-ui** — a `@PreAuthorize` 403 carries no `X-Authz-Denied` and hits axios's
   silent-no-op / forced-logout path.

---

## 9. Actions taken with this audit

- SBDEV-3017 §8.13's mechanism stamped **SUPERSEDED**; its surface census and §8.14's two blocking
  findings retained.
- Decision recorded to durable memory as the standing authz axis for wms2.
- **§1 ANSWERED (Nam, 2026-08-26): `/actuator/**` stays on `wms_admin`**, so the decision is scoped to
  business access and *confirms* role matrix §1.1 rather than changing it.
- **§7 items 1-9 APPLIED 2026-08-26** — role matrix (the §1.1 row, C-1, the superseded bullet, §2.1's
  escape hatch, the path table, the 18→20 count at five sites, a §10 log row, frontmatter +
  `verified_by`), `SBDEV-2968`, `SBDEV-2732`, `9-System/templates/wms-plan-template.md`,
  `1-Projects/wms2/plan/README.md`, `wms2-project-analysis.md`.
- **Still outstanding — §7 item 10:** `verify-SBDEV-{2643,2732}-*.sh` pin `IS_SB_ADMIN` on the putaway
  sites and will go red when the migration lands. They are **correct today**; retire them with the
  migration PR, not before. `verify-SBDEV-2870-*.sh` rows A2/A3/A4/B5/C5 are **rescued** by this
  decision — leave them.
- **Needs a PR, not a doc edit:** the two false code comments in §6 (`AdminController:183`,
  `UserAdministrationController:76`). Editing them would dirty the sub-repo checkout, so they are
  recorded for the migration PR to carry.
- No code changed.
