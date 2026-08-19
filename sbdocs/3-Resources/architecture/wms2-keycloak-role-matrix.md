---
title: "WMS v2 — Keycloak Role Matrix"
type: architecture
status: active
version: v2
scope: authorization
owner: Nam Park
created: 2026-04-19
updated: 2026-08-17
last_verified: 2026-08-17
verified_by: 2026-08-17 (later pass) SBDEV-2870 REDESIGNED onto the function model at Nam Park's direction and reconciled across §1.1, §2.1, §5, §8: the four /v3/user/* warehouse-group endpoints now gate on the FunctionEnum function WEB_UI_VIEW_USER_MANAGEMENT via accessService.doesUserHaveAccess in a new UserAdministrationController (not on the wms_admin Keycloak group), because the function is already held by exactly the screen's users (39 live on WineCo dev via super-admin) whereas the group population was unverifiable from the repo — AC-4 is dissolved rather than deferred, and AC-5 is closed for 4 of 5 by unit tests (ablation-proven both ways), leaving only importUsersFromCsvText's @PreAuthorize(IS_SB_ADMIN) as a one-curl manual check — that endpoint moved to sb_admin (not wms_admin) once the owner confirmed its caller is SiteBoss staff, which also made Authority.IS_WMS_ADMIN dead code and it was deleted (WMS_ADMIN_ROLE survives with exactly one consumer, the /actuator/** matcher). A SIXTH endpoint was found by code review and gated in the same PR: POST /v3/user/saveUserGroups (UserController:263) writes mywms_group_mywms_user — the table the function gate resolves through — and was completely ungated, so it defeated the other four in one request; UserController has zero @PreAuthorize across all 12 of its endpoints. Its siblings /user/create, /user/importUser and /user/delete remain ungated and are tracked as ticket SBDEV-2984, so this ticket must NOT be closed with wording implying Keycloak identity creation is locked down. Also records the newly-found fact that AdminController is a base class for 43 controllers, each with its own class-level @RequestMapping, so its endpoints were registered under all 43 prefixes (176 paths for these 4, not 4) — which understates the endpoint inventories in SBDEV-2967 §0.B and SBDEV-2968. Prior 2026-08-17 pass: all five gated on wms_admin, 3 of 6 ACs. Plus the setLockDamaged finding. Prior 2026-08-16 TARGET STATE added (§1.1) — decision by Nam Park + Brent (BA) — no function should be sb_admin-only; three Keycloak groups retained (wms_user for app access + facility scope, wms_admin for /actuator only, sb_admin as identity only, never enforced). Carve-outs verified against SecurityConfiguration.java:117 (actuator) and wms2-mobile-ui/pages/index.vue:80 (token.warehouse → facility scope). Prior 2026-08-15 web+mobile menu audit (§3.9 added — wms2-web-ui layouts/default.vue:284-285, util/appMenuList.js, store/index.js:92-101, pages/index.vue:114, pages/admin.vue:51-58; wms2-mobile-ui store/home.js:19-118; grep of doesUserHaveAccess across wms2-api; live SELECTs on Hydra UAT + WineCo dev for §4.1) — CORRECTED §3.7 enforcement column and §8 item 3; prior 2026-08-07 SBDEV-2863 fix + code review (Authority.java, CustomMethodSecurityExpressionRoot/Handler, AdminController @PreAuthorize audit incl. the 5 ungated sites, SecurityConfiguration rule-precedence recheck); prior 2026-06-24 re-read of v2/wms2-api WmsConstants.FunctionEnum (344-423) + Authority.java + AdminController.java (@PreAuthorize audit) + UtilRestController.java (255-420 persona seed) + SecurityConfiguration.java (116-136) + wms2-mobile-ui store/home.js (setStaticMenus)
related:
  - ./wms2-end-to-end-request-journey.md
  - ./wms2-tenant-routing-datasource-topology.md
  - ../data-dictionary/wms2-sysprop-catalog.md
tags:
  - architecture
  - authorization
  - keycloak
  - roles
  - wms2
---

# WMS v2 — Keycloak Role Matrix

**Scope:** Every realm role referenced across `wms2-api`, `wms2-web-ui`, and `wms2-mobile-ui`, mapped to the feature it gates · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-08-07

---

## 1. Overview

> [!note] **Read §1.1 first.** As of 2026-08-16 there is an agreed target state that collapses the four namespaces below into one fine-grained mechanism. Everything in §2–§9 documents the **current** state, which is still what runs. Do not design new work against §2–§9 without checking §1.1.

v2 uses Keycloak realm roles for coarse page/feature gating and Keycloak group paths for tenant + warehouse scoping. There are **four** role-type namespaces in use:

| Namespace | Example | Gate style |
|---|---|---|
| `sb_admin` | `sb_admin` | Backend `@PreAuthorize(Authority.IS_SB_ADMIN)` — SiteBoss super-admin |
| `WEB_UI_*` | `WEB_UI_VIEW_ORDER_MONITOR`, `WEB_UI_ACTION_DELETE_UNIT_LOAD` | Web UI page + backend service-level checks (via `FunctionEnum`) |
| `MOBILE_UI_*` | `MOBILE_UI_VIEW_PICKING`, `MOBILE_UI_LOG_IN` | Mobile UI page (filtered from static menu by `store/home.js`) |
| `SPECIAL_*` | `SPECIAL_DEVELOPER` | Developer access; purpose currently unclear |

**Four load-bearing facts:**

1. **Realm roles are declared in `WmsConstants.FunctionEnum` (lines 344–423).** All **80** constants live there (66 `WEB_UI_*` at 344–409, 13 `MOBILE_UI_*` at 410–422, 1 `SPECIAL_*` at 423); grep for a role name in just this file to find where it's authoritative.
2. **Backend enforcement is mostly at the service layer, not annotation layer.** `@PreAuthorize(Authority.IS_SB_ADMIN)` guards **18 active gates** (8 `AdminController` + 1 `ReplenishmentReconciliationController` + 3 `PutawayConfigController` + 5 `PutawayConfigService` + 1 `ItemDataController` — the last three groups added by SBDEV-2732, verified on merged develop 2026-08-11), but most `WEB_UI_ACTION_*` and `WEB_UI_VIEW_*` roles are checked via `syspropService` / `functionService` calls inside service methods, not declarative annotations. ⚠️ **Two separate problems, both in §2.1:** (a) that annotation was **completely broken 2025-10-29 → 2026-08-07** and enforced nothing — it returned HTTP 500 to everyone (SBDEV-2863, now fixed); (b) **five** `AdminController` endpoints were ungated — **code written 2026-08-17, not yet merged: the four `/v3/user/*` endpoints gate on the function `WEB_UI_VIEW_USER_MANAGEMENT` (moved to `UserAdministrationController`), `importUsersFromCsvText` on `wms_admin`; SBDEV-2870 OPEN on 1 of 6 acceptance criteria** (§2.1). That change makes `WEB_UI_VIEW_USER_MANAGEMENT` the **second** enforced function — the first `WEB_UI_VIEW_*` ever enforced — alongside `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`, so the "1 of 80 functions enforced" figure becomes **2 of 80** once merged.
3. **Mobile menu gating is UI-side only.** The mobile UI calls `GET /user/getAllRoles/{username}` (`store/home.js:106`) on login and filters the static menu (filter at `store/home.js:108-113`). **The backend does not re-enforce mobile view roles** — an operator who bypasses the menu (deep link, API replay) will hit service logic without the role check. Check §6 for the implications.
4. 🔴 **The web UI has no gating at all — not even UI-side.** `layouts/default.vue:284-285` hardcodes `menuList["super-admin"]`, so **all 30 web menu items render for every authenticated user**, admin screens included. The web UI does fetch `/user/getAllRoles/{username}` and then throws the result away (`store/index.js:92-101`). **Everything §3.2–§3.7 calls a "Web UI gate" is design intent, not enforcement** — see §3.9 for the full inventory and the five code sites that prove it.

---

### 1.1 TARGET STATE — one fine-grained mechanism (decided 2026-08-16)

> [!important] **Everything below §1.1 describes the CURRENT state. This subsection describes where it is going.**
> Decision by Nam Park with Brent (BA), 2026-08-16. Not yet implemented — no code has changed.

**The business rule that unlocked it:** configuring default putaway locations is a **WMS application admin** (`super-admin`) responsibility, not a SiteBoss one — and, more broadly, **there is currently no function that should be restricted to `sb_admin`.**

That single statement collapses three parallel authorization mechanisms into one.

#### The target: three groups in Keycloak, one of which is never checked

| Keycloak group | Purpose | Enforced as a gate? |
|---|---|---|
| `wms_user` (via `/wms/wh/user`) | App access **and facility scope** — see the carve-out below | **Yes** — the `/v3/**` floor at `SecurityConfiguration.java:143` |
| `wms_admin` (via `/wms/wh/wms_admin`) | `/actuator/**` **only** — never business functions | **Yes**, narrowly |
| `sb_admin` | SiteBoss **identity**: audit, support context, future global actions | **No — retained, unused** |

Everything else — every page, every action, both UIs — is decided by the `UserFunction` → `UserRole` → `UserGroup` → `User` chain in the tenant DB (§4). The clean division:

- **Keycloak answers:** *is this a real user, do they belong to this client, may they open the app at all?*
- **WMS answers:** *what may they do once inside?*

#### The two carve-outs, and why they are structural rather than preference

**C-1 · `wms_admin` must keep `/actuator/**`.** Actuator is **per-JVM, not per-tenant**. Those requests carry no `TenantContext`, so there is no tenant DB to read a function from — the mechanism physically cannot reach. And actuator exposes metrics, env and thread dumps, so it cannot drop to `permitAll` either.

**C-2 · Facility scope cannot become a function.** This is the load-bearing one. `wms2-mobile-ui/pages/index.vue:80` populates the user's facility list from `tokenParsed.warehouse`, which is delivered by `/wms/wh/user` group membership. The dependency is circular:

```
token.warehouse → facility_code header → 4-char routing key
                                              ↓
                                  which tenant DB to connect to
                                              ↓
                          mywms_function lives in THAT database
```

Reading a user's functions requires having already chosen a facility, so *which facilities a user may access* cannot itself be a function — **picking the facility is what selects the function table.**

Consequence: the `wms_user` group does **two** jobs — app-access gate *and* facility-scope carrier — and cannot be thinned further. Per-facility *permissions* are already expressed naturally (each facility is its own DB with its own function rows); per-facility *access* stays in the token.

#### What moves

All **18 active `@PreAuthorize(Authority.IS_SB_ADMIN)` gates** (§2.1) re-home onto `FunctionEnum` constants:

| Site | Gates | Target function |
|---|---|---|
| `AdminController` :80, 108, 121, 134, 143, 155, 176, 200 | 8 | `WEB_UI_VIEW_USER_MANAGEMENT` (already exists, already seeded to `super-admin`) |
| `PutawayConfigService` :96, 128, 165, 257, 287 | 5 | new `WEB_UI_ACTION_CONFIGURE_PUTAWAY_DESTINATION` |
| `PutawayConfigController` :183, 215, 233 | 3 | same |
| `ItemDataController` :105 (`setPutAwayLocation`) | 1 | same — it is the same feature's write path |
| `ReplenishmentReconciliationController` :37 | 1 | admin function, or retained as break-glass (open item below) |

⚠️ **Two mechanisms, not one, because the layers differ.** SBDEV-2968's guard is a `HandlerInterceptor` — **HTTP layer only**. It covers the four controller sites. It **cannot** cover the five on `PutawayConfigService`, which sit at the service layer deliberately (Spring Data REST may capture the raw target rather than the security proxy, making a handler annotation inert — see that class's Javadoc), and whose write path is served by `RepositoryRestHandlerMapping`, which does not honour `addInterceptors` at all. Those five need an explicit `accessService.doesUserHaveAnyAccess(...)` call inside each method.

#### This unblocks SBDEV-2870

Its recorded blocker was: *"Do not simply restore the annotations — `wms2-web-ui` calls three of them from the User Management screen, so a guard would 403 that screen for every non-`sb_admin` admin."* Under function gating that objection **dissolves**: those endpoints take `WEB_UI_VIEW_USER_MANAGEMENT`, which the screen's legitimate users already hold. SBDEV-2870 becomes a self-contained API change rather than a coordinated API+UI negotiation.

✅ **This is what was implemented on 2026-08-17** (§2.1): four of the five endpoints gate on `WEB_UI_VIEW_USER_MANAGEMENT` via `accessService.doesUserHaveAccess`, in a new `UserAdministrationController`. Note it is an **explicit service call, not an annotation and not the 2968 interceptor** — for the same reason the `PutawayConfigService` five are: a declarative gate cannot express a per-tenant DB lookup, and nothing in this repo's test lanes can evaluate one. It is also the **first `WEB_UI_VIEW_*` function ever enforced anywhere in the codebase.**

#### Ordering — non-negotiable, and it fails in both directions

| If you… | Result |
|---|---|
| Remove `sb_admin` gates **before** enforcement is real | Controls become **fully open** to any `wms_user` — today only 1 of 80 functions is enforced anywhere (§3.7) |
| Add function gates **before** the Flyway seed reaches a tenant | Controls become **inaccessible to everyone** on that tenant — worse than today, where staff could at least act |

**Sequence: SBDEV-2968 lands → functions seeded and audited on every tenant → then swap the gates.** Never gates first. Migrate in tranches; putaway config is the natural pilot (smallest, and the one the BA actually asked for).

#### Consequences accepted deliberately

1. **Every authorization decision becomes a DB round-trip.** `sb_admin` was a free token check; `getAllRoles` is a 5-table join with no cache. SBDEV-2968's interceptor caps it at one query per *request* rather than per endpoint — that is what makes this affordable.
2. **"Logged in but can do nothing" becomes the dominant support call.** A Keycloak identity with no `mywms_user` row, or a row with no group, now fails totally. SBDEV-2968's typed deny reasons (`USER_NOT_PROVISIONED` vs `NO_FUNCTIONS` vs `MISSING_FUNCTION`) stop being nice-to-have.
3. **No mechanism remains for a genuinely global action** — hence `sb_admin` stays *defined* so reintroducing a gate is one line, not a re-architecture.
4. 🔴 **Break-glass disappears. OPEN ITEM.** Today, if a tenant's group/role/function data is wrong, SiteBoss staff can still act because `sb_admin` bypasses the DB model. Afterwards **nobody can repair a broken tenant through the app — including SiteBoss.** Recovery becomes direct SQL or a redeploy. Survivable, but it should be decided rather than discovered during an incident. Cheapest mitigation: keep one narrow `sb_admin`-gated repair endpoint (`ReplenishmentReconciliationController` is already shaped like one). **To be settled by Nam + Brent.**

#### `importUsersFromCsvText` — RESOLVED 2026-08-16: deliberately outside the function model

`AdminController.importUserWithCsv` (`GET /v3/admin/importUsersFromCsvText`) is **bulk Keycloak user creation from CSV** — it manufactures identities rather than performing a warehouse operation.

**Decision (Nam Park, 2026-08-16):** it is a one-off operational utility, written to migrate users out of a client's earlier Keycloak and retained for likely future reuse. It is **not** mapped to any `FunctionEnum` function — neither an existing one nor a new one — because functions describe what an operator may do *inside a warehouse*, and this is not that. It is **excluded from the migration above** and stays gated on the Keycloak authority directly:

```java
@PreAuthorize(Authority.IS_SB_ADMIN)   // = hasAuthority('sb_admin')
```

**`sb_admin`, not `wms_admin` — corrected 2026-08-17.** An interim revision used `wms_admin`; code review flagged the inconsistency with the comment three lines above the annotation, which describes the caller as an operator performing a **client migration**. That is SiteBoss staff work, and staff carry `sb_admin` (via the `groups` claim), not `wms_admin`. Under `wms_admin` the endpoint would have returned **403 to the only people it was retained for** while every other endpoint on the same class accepted them — a failure that surfaces the first time someone onboards a client. Owner confirmed the operator is staff.

This also *restores* the annotation `5ac0262c` (2024-10-16) commented out: the original intent was already `sb_admin`. Unlike the four warehouse-group endpoints — collateral damage from the SBDEV-2863 window — that comment-out predates the rename and was a deliberate choice.

**Consequence: `Authority.IS_WMS_ADMIN` is now deleted.** With the four warehouse-group endpoints on the function model and this one on `sb_admin`, the expression had zero references. A dead SpEL constant in a security class is a loaded gun, and §1.1's target state says `wms_admin` gates `/actuator/**` and nothing else. `WMS_ADMIN_ROLE` survives as the actuator matcher's constant — **exactly one consumer**, with a javadoc note recording why there is no expression beside it.

Implemented on `bugfix/SBDEV-2870-restrict-csv-user-import-to-wms-admin` (unmerged; branch name now predates the decision). ⚠️ This is the **only** gate on the branch that no test can evaluate — `standaloneSetup` cannot evaluate `@PreAuthorize` (RC-2) and SBDEV-2217 blocks the `@SpringBootTest` lane — so it is the entire residual of AC-5: one curl.

⚠️ **Precondition, unverified in code:** `JwtAccessTokenCustomizer.extractRoles` (`:86-107`) harvests `groups` claim entries **verbatim** — it does not strip group paths. So the Keycloak group-membership mapper must emit the bare name `wms_admin`, not the full path `/wms/wh/wms_admin`. `sb_admin` already relies on this and `/actuator/**` already depends on it, so it is almost certainly true — but it is a per-realm Keycloak setting, not a repo fact. **Confirm with one `curl /actuator/env` using a `wms_admin` token before trusting the new gate.**

---

## 2. Namespace Layout

### 2.1 `sb_admin` — SiteBoss super-admin

> 🔄 **Superseded in the target state (§1.1).** Per the 2026-08-16 decision, no function should be restricted to `sb_admin`; all 18 gates below re-home onto `FunctionEnum` constants and `sb_admin` is retained as **identity only, never enforced**. This section remains accurate for what runs today.

> [!important] **WHO HOLDS IT, AND HOW IT REACHES THE TOKEN — confirmed with Nam 2026-08-11.**
>
> - **`sb_admin` is the SUPER-ADMIN role, assigned to SiteBoss employees** — SiteBoss being the company
>   that owns this product. It carries the same authority as an app admin, plus everything gated on it.
> - **Customer WMS users are only ever assigned `wms_user` and/or `wms_admin`.** They never hold
>   `sb_admin`, so every `IS_SB_ADMIN`-gated endpoint is **SiteBoss-staff-only by design**, not by
>   oversight. Treat "a WMS admin sees this control disabled" as intended, not a bug.
> - ⚠ **It is delivered by Keycloak GROUP membership, so it arrives in the `groups` claim — NOT under
>   `resource_access`.** `JwtAccessTokenCustomizer.extractRoles` harvests both
>   (`GROUP_ELEMENT_IN_JWT = "groups"`, plus the roles of every client under `resource_access`) and
>   flattens them into the granted authorities that `hasAuthority('sb_admin')` tests.
>
> **Why that last point is load-bearing for any client-side gate:** `keycloak-js`'s
> `hasResourceRole(role, clientId)` reads `resource_access[clientId].roles` only. A group membership is
> not there, so such a check returns `false` for **every** real `sb_admin`, on every tenant,
> permanently. SBDEV-2732's first Phase 2 UI gate did exactly that and would have disabled the control
> for everyone entitled to it; it now mirrors `extractRoles` in `wms2-web-ui/util/keycloakRoles.js`.
> **A client-side `sb_admin` check must read the `groups` claim.**

> **Unused escape hatch, recorded so it is not rediscovered:**
> `Authority.getExpAppAdminGroupOrSbAdminGroup(appAdminRole, sbAdminRole)` and
> `getExpAppUserGroupOrAppAdminGroup(...)` are **defined and called nowhere**. They render
> `hasAuthority('X') or hasAuthority('Y')`. If product ever wants WMS admins to self-serve something
> currently gated on `sb_admin` — e.g. the SBDEV-2732 putaway-destination config — that helper is where
> the `wms_admin`-or-`sb_admin` expression already exists. A product decision, not a defect.


- Defined: `Authority.java:14` (`SB_ADMIN_ROLE = "sb_admin"`)
- Expression: `Authority.IS_SB_ADMIN` = `"hasAuthority('sb_admin')"` (`Authority.java`, declared immediately below `SB_ADMIN_ROLE`) — a **Spring built-in**, not a custom SpEL method.
- Enforced by: `@PreAuthorize(Authority.IS_SB_ADMIN)` on **18 active gates** (was 9 before SBDEV-2732, which added 3 on `PutawayConfigController`, **5 on `PutawayConfigService`** — the putaway-config write surface enforces at the service layer as well as the controller — and 1 on `ItemDataController`) — 8 on `AdminController`: `findUsers` (:80), `findUserByUsername` (:108), `deleteUserByUsername` (:121), `findUserGroupsByUsername` (:134), `createUser` (:143), `updateUser` (:155), `resetPassword` (:176), `findGroup` (:200) — plus **`ReplenishmentReconciliationController:37`** (per-tenant stranded-reservation reconciliation, SBDEV-2610 C1), which this doc previously omitted.
- Typical grantee: SiteBoss engineering / ops staff. Not tenant-scoped.

> ## 🔴 THIS EXPRESSION WAS BROKEN FOR ~9 MONTHS — 2025-10-29 → 2026-08-07 (SBDEV-2863)
>
> **Everything this section previously described as enforcement was not enforcement.** `IS_SB_ADMIN` read
> `"isSbAdmin()"`, and **no such method has ever existed** on `CustomMethodSecurityExpressionRoot` — its only
> admin predicate is `isAimAdmin()` (`:77`). Spring resolves a `@PreAuthorize` string reflectively against
> that root, so every one of the 9 annotated endpoints threw
> `SpelEvaluationException EL1004E` *inside the authorization check* and returned **HTTP 500 to every
> caller, `sb_admin` included.** Not a denial — a crash. Those endpoints were non-functional, not protected.
>
> **Provenance:** `ded4d644` (2025-10-29, "cleaned up the code") renamed `IS_AIM_ADMIN`/`"isAimAdmin()"` to
> `IS_SB_ADMIN`/`"isSbAdmin()"` and `AIM_ADMIN_ROLE` → `SB_ADMIN_ROLE`, but left the method on the
> expression root named `isAimAdmin()`. A half-finished `aim_admin` → `sb_admin` rebrand. **The expression
> worked before that commit.**
>
> **Operational consequence worth knowing:** `ReplenishmentReconciliationController:37` was added *after*
> 2025-10-29, so **it has never once worked** — every attempt to run the SBDEV-2610 stranded-reservation
> remediation returned 500. Reservations that remediation was meant to clear may still be stranded on every
> tenant.
>
> **Why no test caught it:** `CustomMethodSecurityExpressionRootUnitTest` called `isAimAdmin()` *directly*
> and never evaluated the SpEL string; and `BaseControllerUnitTest:50` uses `MockMvcBuilders.standaloneSetup`,
> which installs no security filter chain and no method-security advisor — so **no controller unit test in
> this repo evaluates `@PreAuthorize` at all.** The `@SpringBootTest` lane that would is down (SBDEV-2217).
>
> **Fixed by SBDEV-2863** → `hasAuthority('sb_admin')`, semantically identical to what `isAimAdmin()`
> delegates to. ⚠️ The constant is a **compile-time constant**, so javac inlines its value into every
> consumer class file — and `pom.xml:440` disables incremental compilation. **Verify this fix only against a
> `mvn clean` build**; a warm `target/` reproduces the old 500. The release path (`Dockerfile:10`,
> `mvn clean package`) is already safe. A durable guard for the whole defect class is tracked by **SBDEV-2872**.

> ⚠️ **SECURITY GAP — CODE WRITTEN 2026-08-17, NOT YET MERGED. [SBDEV-2870](https://app.clickup.com/t/868knqrwr) remains OPEN.**
>
> On branch `bugfix/SBDEV-2870-restrict-csv-user-import-to-wms-admin` (uncommitted), **two mechanisms**, because
> the five are not one category:
>
> | Endpoint | Gate | Where |
> |---|---|---|
> | `/v3/admin/importUsersFromCsvText` | `@PreAuthorize(Authority.IS_SB_ADMIN)` | stays in `AdminController` |
> | `POST /v3/user/saveUserGroups` | function **`WEB_UI_VIEW_USER_MANAGEMENT`** | `UserController` — **Fix E**, added by code review |
> | the four `/v3/user/*` warehouse-group endpoints | function **`WEB_UI_VIEW_USER_MANAGEMENT`** via `accessService.doesUserHaveAccess` | new `UserAdministrationController` |
>
> **The axis was corrected on 2026-08-17 (Nam Park).** The first implementation put all five on the `wms_admin`
> Keycloak group. That is a *different axis* from the one that already grants the screen — the
> `WEB_UI_VIEW_USER_MANAGEMENT` function, held by **39 live WineCo dev users** via `super-admin` — which made
> AC-4 unanswerable from the repo and left AC-5 untestable. Gating the four on the function puts screen and API
> on one axis, so no current user loses access. The CSV utility is tied to **no** function by standing
> instruction (it manufactures identities) and sits on **`sb_admin`**, because its caller is SiteBoss staff.
>
> **A sixth endpoint was found by review and gated in the same PR:** `POST /v3/user/saveUserGroups`
> (`UserController:263`) **writes `mywms_group_mywms_user`** — the table the function gate resolves through —
> and had no authorization at all (`UserController` has **zero** `@PreAuthorize` and zero function checks
> across all 12 of its endpoints). Ungated, it defeated the other four in a single request: grant yourself
> `super-admin`, walk back through. It also allowed `{"userId": <admin id>, "groups": []}` to strip an
> administrator of every function. **The transferable rule: gating on a DB table is only as strong as the
> weakest writer of that table — enumerate the writers, not just the readers.**
>
> ⚠️ Still open, own ticket **SBDEV-2984**: `/v3/user/create`, `/user/importUser`, `/user/delete/{userId}` on
> the same class remain ungated, and `/user/create` reaches `KeycloakService.createSingleUser` which adds the
> new account to the WMS **and** warehouse groups — reproducing the CSV import's capability one user at a time.
>
> **Two structural consequences worth carrying forward:**
> - **A plain method call, not an annotation.** `standaloneSetup` installs no method-security advisor, so no
>   controller test in this repo can evaluate `@PreAuthorize` — which is how SBDEV-2863 shipped a 500-for-everyone
>   guard for nine months. The function gate is ordinary code, so its deny path is unit-testable; that is what
>   closes AC-5 for four of the five.
> - **`AdminController` is a base class for 43 controllers**, each with its own class-level `@RequestMapping`.
>   Its endpoints were therefore registered under **all 43 prefixes** (`/v3/picking/user/isWarehouseUser`,
>   `/v3/report/user/existsInKeycloak`, …) — the four ungated endpoints were reachable on **176 paths, not 4**.
>   Extraction into `UserAdministrationController` removes 172 of them. ⚠️ **This means the endpoint inventories
>   in SBDEV-2967 §0.B and SBDEV-2968 are understated** for every `AdminController`-inherited mapping.
>
> 🔴 **Still not closed. 5 of 6 acceptance criteria met.** Outstanding:
> - **AC-5, residual** — only `/v3/admin/importUsersFromCsvText`. Its `@PreAuthorize` cannot be evaluated by any
>   test in this repo (`standaloneSetup`; `@SpringBootTest` lane down, SBDEV-2217), so it reduces to **one curl
>   that has not been run**. The other four are covered by 5 unit tests, ablation-proven in both directions
>   (remove the guards → 5/5 fail; move one guard inside its `try` → exactly that endpoint's test fails).
> - **AC-4 — dissolved, not deferred.** With the gate on the function, there is no Keycloak group population
>   left to confirm.
>
> The paragraphs below describe the pre-fix state and are retained as the record of what was wrong.
>
> **Five** `AdminController` endpoints were ungated. `/v3/**` → `hasAnyAuthority("wms_user")` (**rule D**, `SecurityConfiguration.java:136`) is what applies — *not* rule C's `/user/**` matcher at `:132`, which is root-relative and does **not** match `/v3/user/**`. Either way the effective gate is `wms_user`, so **any authenticated warehouse user** can reach all five:
> - `importUsersFromCsvText` — `AdminController.java:190` (commented), `GET /v3/admin/importUsersFromCsvText` — **bulk Keycloak user creation from CSV; a privilege-escalation path**
> - `addUserToWarehouseGroup` — `AdminController.java:261` (commented), `POST /v3/user/addUserToWarehouseGroup`
> - `removeUserFromWarehouseGroup` — `AdminController.java:285` (commented), `POST /v3/user/removeUserFromWarehouseGroup`
> - `isWarehouseUser` — `AdminController.java:315` (commented), `GET /v3/user/isWarehouseUser`
> - `userExistsInKeycloak` — `AdminController.java:359` (**never had a `@PreAuthorize`**), `GET /v3/user/existsInKeycloak` (Keycloak user-enumeration vector)
>
> **New finding (SBDEV-2863 review): four of the five were most likely commented out *because of* the defect above, not as a decision.** `c8ce58d9` (2026-02-01) *replaced* three previously-**guarded** group endpoints with these warehouse-group endpoints, committing their annotations **already commented out** — three months into the broken window, when the guard returned 500 to everyone. `:190` is the exception (commented by `5ac0262c`, 2024-10-16, before the rename) and is a genuine deliberate choice.
>
> **The original blocker, and how it was finally resolved:** `wms2-web-ui` calls four of them from the User Management screen (`store/admin/user.js:175, 193, 207, 218` via `components/admin/userManagement/users/userWarehouseEdit.vue:127-162`), so restoring an `sb_admin` guard would have 403'd that screen for every customer admin. The first attempt substituted `wms_admin`, which avoids *that* failure but only by swapping one unverified population for another — nobody could confirm from the repo that the screen's users are in the `/wms/wh/wms_admin` group, and a wrong guess would have logged them out (403 → axios retry ×3 → `$kc.logout()`). **Gating on `WEB_UI_VIEW_USER_MANAGEMENT` resolves it by construction instead of by assumption:** the screen's legitimate users already hold it, because it is what makes the screen visible.
>
> 📌 **The reusable lesson.** When a new guard lands on a *different axis* from the one that already grants access, prefer moving the guard onto the existing axis over verifying that the two populations coincide. Verification is a point-in-time claim about tenant data that drifts; the axis match is structural. Same shape as SBDEV-2947, where storage tier and picker eligibility sat on different axes and one `location_constraint` row was the entire difference between tenants.
>
> Related: `findUsers` (`:80-103`) reads a `jwt.getClaimAsStringList("authorities")` claim that `JwtAccessTokenCustomizer:86-107` never populates, so its SiteBoss-staff filter has never worked and its `else` branch is now unreachable — **SBDEV-2871**.

### 2.2 `WEB_UI_*` — Web UI page + action gates

**66 constants** at `WmsConstants.FunctionEnum:344–409`: 58 `WEB_UI_VIEW_*` / `WEB_UI_LOG_IN` page gates (344–401) plus 8 `WEB_UI_ACTION_*` destructive-action gates (402–409). Each typically corresponds to a top-level page or a sensitive action in `wms2-web-ui`. See §3 for the full table — and **§3.9 before you rely on any of it**, because none of these 66 are checked by the web UI and only one is checked by the backend.

### 2.3 `MOBILE_UI_*` — Mobile UI page gates

**13 constants** at `WmsConstants.FunctionEnum:410–422` (`MOBILE_UI_VIEW_CANCELLATION` at :422 was added since the prior audit). Each one (except `LOG_IN` and `NEVER_TIME_OUT`) is mapped to a mobile workflow page in `wms2-mobile-ui/store/home.js:setStaticMenus`.

### 2.4 `SPECIAL_DEVELOPER` (and the orphans)

`WmsConstants.FunctionEnum:423`. Defined but no referenced consumer found. §5.

---

## 3. Full Role Table

Rows marked — (em dash) in a column mean "not referenced there."

### 3.1 Administrative (backend-enforced)

| Role | Backend | Web UI gate | Mobile UI gate | Purpose |
|---|---|---|---|---|
| `sb_admin` | `Authority.IS_SB_ADMIN` → **18 active** `@PreAuthorize` gates (SBDEV-2732 added 9: 3 `PutawayConfigController`, 5 `PutawayConfigService`, 1 `ItemDataController`): `AdminController` :80,108,121,134,143,155,176,200 (`/v3/user/*` + `/v3/groups/*`) + `ReplenishmentReconciliationController:37` | — | — | SiteBoss global admin. ⚠️ **Enforced nothing 2025-10-29 → 2026-08-07 — the expression threw and returned 500 to everyone (SBDEV-2863, fixed).** ⚠️ **5 endpoints were ungated (:190, 261, 285, 315 commented + :359 never annotated). On an unmerged branch :190 is gated on `wms_admin`; the other four moved to `UserAdministrationController` and gate on the FUNCTION `WEB_UI_VIEW_USER_MANAGEMENT`, so they are no longer `@PreAuthorize` sites at all. SBDEV-2870 OPEN on AC-5 residual only, see §2.1** |

### 3.2 Web UI — `WEB_UI_LOG_IN` + admin pages

| Role | Web UI page / feature | Backend consumer | Purpose |
|---|---|---|---|
| `WEB_UI_LOG_IN` | Login gate | `UtilRestController` — assigned as baseline to most roles (admin user :258, inventory-manager :278, outbound-manager :302, receiving :331, super-admin :355) | App entry |
| `WEB_UI_VIEW_USER_MANAGEMENT` | User management page | `UtilRestController` — assigned to the `admin` user directly (:257) **and** `role_super_admin` (:406). **Not** `role_inventory_manager`. | User admin |
| `WEB_UI_VIEW_IMPORT_DATA` | Data import | `role_super_admin` (:370) | File import |
| `WEB_UI_VIEW_SYSTEM_PROPERTY` | Sysprop admin | `role_super_admin` (:401) | See [wms2-sysprop-catalog.md](../data-dictionary/wms2-sysprop-catalog.md) |
| `WEB_UI_VIEW_CLIENT` | Client/tenant admin | `role_super_admin` (:360) | Client config |
| `WEB_UI_VIEW_USER` | User list | `role_super_admin` (:405) | User listing |
| `WEB_UI_VIEW_GROUP` | Group admin | `role_super_admin` (:369) | Keycloak group mgmt |
| `WEB_UI_VIEW_ROLE` | Role admin | `role_super_admin` (:393) | Role mgmt |
| `WEB_UI_VIEW_FUNCTION` | Function admin | `role_super_admin` (:366) | Permission/function mgmt |
| `WEB_UI_VIEW_MESSAGES` | Message queue | `role_super_admin` (:381) | OMS message audit |

### 3.3 Web UI — Master data & inventory

| Role | Web UI page | Purpose |
|---|---|---|
| `WEB_UI_VIEW_STOCK_COUNT` | Stock count | Cycle-count list |
| `WEB_UI_VIEW_STORAGE_LOCATION` / `*_TYPE` | Location / type master | Location CRUD |
| `WEB_UI_VIEW_RACK` / `*_ROW` | Rack structure | Rack CRUD |
| `WEB_UI_VIEW_AREA` | Location areas | Area CRUD |
| `WEB_UI_VIEW_SECTION` | Warehouse sections | Section CRUD (drives picking type) |
| `WEB_UI_VIEW_ITEM_DATA` | SKU master | Item CRUD |
| `WEB_UI_VIEW_FIXED_ASSIGNMENT` | Fixed-location assignments | Replenishment-source config |
| `WEB_UI_VIEW_ITEM_UNIT` | UoM conversion | Item unit CRUD |
| `WEB_UI_VIEW_CASE_TYPE` | Case types | Box-type CRUD |
| `WEB_UI_VIEW_UNIT_LOAD_TYPE` | Unit load types | UL type CRUD |
| `WEB_UI_VIEW_STOCK_UNIT` | Stockunit list | Stock browser |
| `WEB_UI_VIEW_CONTAINER` | Container list | Unitload browser |
| `WEB_UI_VIEW_STOCK_UNIT_RECORD` | Stock ledger | Stockrecord audit |
| `WEB_UI_VIEW_UNIT_LOAD_RECORD` | UL history | UnitloadRecord audit |
| `WEB_UI_VIEW_INVENTORY_RECORD` | Inventory export | See `StockSummaryExportJob` |

### 3.4 Web UI — Inbound / Goods receipt

| Role | Purpose |
|---|---|
| `WEB_UI_VIEW_CREATE_INBOUND_BOL` | Inbound BOL entry |
| `WEB_UI_VIEW_RECEIVING` | Receiving dashboard |
| `WEB_UI_VIEW_INBOUND_BOL` / `WEB_UI_VIEW_INBOUND_BOL_ITEM_LINES` | Inbound BOL header + item lines |
| `WEB_UI_VIEW_GOODS_RECEIPT` / `*_POSITION` | Goods receipt detail |

### 3.5 Web UI — Outbound / Picking / BOL

| Role | Typical assignee | Purpose |
|---|---|---|
| `WEB_UI_VIEW_REPLENISHMENT_ORDER` | outbound ops | Replenish order list |
| `WEB_UI_VIEW_ORDER_BATCH` | `role_outbound_manager` | Order batch list |
| `WEB_UI_VIEW_ORDER` / `*_POSITION` | `role_outbound_manager` | Order detail |
| `WEB_UI_VIEW_PICKING_ORDER` / `*_POSITION` | `role_outbound_manager` | Picking detail |
| `WEB_UI_VIEW_BILL_OF_LADING` / `*_POSITION` | `role_outbound_manager` | BOL detail |
| `WEB_UI_VIEW_CLUB_LINE` | — (specific) | Club run UI |
| `WEB_UI_VIEW_TRANSFER_ORDER` | — | Transfer orders (also used by mobile menu — see §3.7) |

### 3.6 Web UI — Monitors / operations dashboards

| Role | Assigned to | Purpose |
|---|---|---|
| `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` | `role_inventory_manager` | Lock overview |
| `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` | inventory | Received stock summary |
| `WEB_UI_VIEW_LOCATION_OVERVIEW` | `role_outbound_manager` | Location monitor |
| `WEB_UI_VIEW_ORDER_MONITOR` | `role_outbound_manager` | Order monitor |
| `WEB_UI_VIEW_REPLENISHMENT_MONITOR` | `role_inventory_manager` + `role_outbound_manager` | Replenish monitor |
| `WEB_UI_VIEW_FLOWBIN_MONITOR` | `role_inventory_manager` + `role_outbound_manager` | Flowbin monitor |
| `WEB_UI_VIEW_PARCEL_MONITOR` | `role_inventory_manager` + `role_outbound_manager` | Parcel monitor |
| `WEB_UI_VIEW_ORDER_DETAIL_MONITOR` | outbound | Order drill-down |
| `WEB_UI_VIEW_CYCLECOUNT` / `*_POSITION` | inventory | Cycle count monitor |
| `WEB_UI_VIEW_DB_QUERIES` | `role_inventory_manager` + `role_outbound_manager` | Saved-query admin |
| `WEB_UI_VIEW_PRINTER` | ops | Printer config |
| `WEB_UI_VIEW_SEQUENCE_NUMBER` | admin | Sequence counter config |

### 3.7 Web UI — Destructive / sensitive actions

There are exactly **8** `WEB_UI_ACTION_*` constants (`WmsConstants.FunctionEnum:402–409`). All 8 are assigned to `role_super_admin` in `UtilRestController` (:351–354, 413–416).

> 🔴 **CORRECTED 2026-08-15.** This table previously listed all 8 as "Service-level `FunctionEnum` check". That was wrong for 7 of them. `AccessService.doesUserHaveAccess()` — the *only* function-checking method in the backend — has exactly **five call sites, all passing the same constant**: `StockunitService.java:232`, `MobileMoveStockService.java:251, 256`, `MobileMoveUnitloadService.java:277, 282`. A repo-wide grep for `doesUserHaveAccess` returns nothing else.
>
> **Net: 1 of 80 functions is enforced anywhere in the system.** The other 79 are provisioning metadata.

| Role | Constant line | Purpose | Enforcement (verified 2026-08-15) |
|---|---|---|---|
| `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` | :408 | Place damaged lock | ✅ **Real** — 5 sites: `StockunitService:232`, `MobileMoveStockService:251,256`, `MobileMoveUnitloadService:277,282` |
| `WEB_UI_ACTION_DELETE_UNIT_LOAD` | :402 | Delete unit load | ❌ **None** |
| `WEB_UI_ACTION_DELETE_UNIT_LOAD_RECURSIVE` | :403 | Recursive unit-load delete | ❌ **None** |
| `WEB_UI_ACTION_ADJUST_AMOUNT` | :404 | Adjust stockunit amount | ❌ **None** |
| `WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT` | :405 | Adjust reserved amount | ❌ **None** |
| `WEB_UI_ACTION_ADJUST_LOCK_RELEASE_LOCK` | :406 | Release stock lock | ❌ **None** |
| `WEB_UI_ACTION_ADJUST_LOCK_ON_HOLD` | :407 | Place on-hold lock | ❌ **None** |
| `WEB_UI_ACTION_PRINT_TOTE_LABELS` | :409 | Print tote labels | ❌ **None** |

### 3.8 Mobile UI — all 13 roles

These are the authoritative Mobile role set (13 `MOBILE_UI_*` constants, `WmsConstants.FunctionEnum:410–422`). Menu source: `wms2-mobile-ui/store/home.js:19-99` (`setStaticMenus`).

| Role | Mobile page | Link | Backend consumer |
|---|---|---|---|
| `MOBILE_UI_LOG_IN` | (gate) | — | `UtilRestController` — assigned to all 6 mobile personas (inventory-manager/-worker, outbound-forklift/-manager/-worker, receiving) + super-admin |
| `MOBILE_UI_NEVER_TIME_OUT` | session override | — | Not in menu / not seeded to any persona — Mobile UI session manager only (bypasses auto-logout). Orphan, §5 |
| `MOBILE_UI_VIEW_INFO` | Lookup | `/lookup` | — |
| `MOBILE_UI_VIEW_PUT_AWAY` | Putaway | `/putaway` | `role_receiving` (:327), `role_super_admin` (:346) (see [wms2-receiving-putaway-workflow.md](../workflows/wms2-receiving-putaway-workflow.md)) |
| `MOBILE_UI_VIEW_TRANSFER` | Move Unitload | `/move-unitload` | — |
| `MOBILE_UI_VIEW_STOCK_TRANSFER` | Move Stock | `/move-stock` | — |
| `MOBILE_UI_VIEW_PICKING` | Picking | `/picking` | `role_outbound_manager`/`-worker`, `role_super_admin` (see [wms2-picking-workflow.md](../workflows/wms2-picking-workflow.md)) |
| `MOBILE_UI_VIEW_PALLETIZING` | Palletizing | `/palletizing` | `role_outbound_manager`/`-worker`, `role_super_admin` |
| `MOBILE_UI_VIEW_TRUCK_LOADING` | Truck Loading | `/truck-loading` | `role_outbound_forklift`/`-manager`, `role_super_admin` (see [wms2-bol-truck-loading-workflow.md](../workflows/wms2-bol-truck-loading-workflow.md)) |
| `MOBILE_UI_VIEW_CYCLE_COUNT` | Cycle Count | `/cycle-count` | `role_inventory_manager`/`-worker`, `role_super_admin` |
| `MOBILE_UI_VIEW_REPLENISHMENT` | Replenish Process + Replenish Request | `/replenish`, `/replenish-request` | `role_receiving` (:328), `role_super_admin` (:347) |
| `MOBILE_UI_VIEW_CANCELLATION` | Cancellation Process | `/cancellation` | — (menu role at `store/home.js:89-92`; not seeded to any persona in `UtilRestController`). New since prior audit. Orphan, §5 |
| `MOBILE_UI_VIEW_LPN_ASSOCIATION` | (LPN Associate — menu block **commented out**, `store/home.js:94-98`) | — | Reserved for future LPN flow. Orphan, §5 |

**Note the odd one:** `WEB_UI_VIEW_TRANSFER_ORDER` appears in the mobile menu (`store/home.js:82-87`, the Transfer Process page) as the only mobile menu entry that uses a `WEB_UI_*` role — likely a naming oversight. Don't rename without coordinating a realm-role migration.

**Contrast with the web UI:** every mobile tile carries a `role` property and the menu is genuinely filtered. **The web UI menu has neither** — see §3.9.

### 3.9 Web UI — Menu Inventory (and why **none** of it is function-gated)

> [!warning] **All 30 web menu items are ungated. The web UI performs no function check of any kind.**
>
> `wms2-web-ui/layouts/default.vue:284-285`:
>
> ```js
> links() {
>   return menuList["super-admin"];   // ← no argument, no role lookup, no filter
> }
> ```
>
> Every authenticated user renders the full **super-admin** menu, regardless of which
> `UserRole`/`UserGroup` they hold. This is not a gap in one page — it is the absence of the
> entire client-side authorization layer that §3.2–§3.7 describe.

**Five independent code sites confirm it** (verified 2026-08-15 on `docs/wms2-plan-reconcile-2732-corrections`):

| Evidence | Site | What it shows |
|---|---|---|
| Menu is hardcoded | `layouts/default.vue:284-285` | Returns the `super-admin` key unconditionally |
| 4 of 5 menu variants are dead code | `util/appMenuList.js:2, 197, 355, 441, 545` | Keys `super-admin`, `inventory-manager`, `outbound-manager`, `outbound-manager,receiving`, `receiving` exist; only the first is ever read |
| Roles are fetched and **discarded** | `store/index.js:92-101` → `pages/index.vue:114` | `getUserRoles` calls `/user/getAllRoles/{username}`, commits nothing, returns a value the sole caller ignores |
| No route guards | no `middleware/` directory in the repo | Deep-linking any page works |
| Admin tabs hardcoded | `pages/admin.vue:51-58` | All 6 tabs render, **including User Management**, with no `WEB_UI_VIEW_USER_MANAGEMENT` check |

A repo-wide grep for `WEB_UI_VIEW` / `WEB_UI_ACTION` / `FunctionEnum` across `wms2-web-ui` returns **zero** hits outside Cypress fixtures. Contrast `wms2-mobile-ui/store/home.js`, where all 12 tiles carry a `role`.

#### 3.9.1 The 30 menu items

10 top-level entries → 30 leaf destinations. The **Intended function** column is *inferred* from the page's subject matter — it is **not** read from code, because no such binding exists anywhere. Treat it as the mapping to implement, not the mapping in force.

| # | Menu → item | Route | Intended function (⚠ not enforced) |
|---|---|---|---|
| 1 | Dashboard | `/dashboard` | `WEB_UI_VIEW_ORDER_MONITOR` / `_REPLENISHMENT_MONITOR` / `_FLOWBIN_MONITOR` / `_PARCEL_MONITOR` |
| 2 | Receiving → Inbound Notices | `/receiving/inbound-notices` | `WEB_UI_VIEW_INBOUND_BOL`, `WEB_UI_VIEW_RECEIVING` |
| 3 | Internal Ops → Replenishment | `/internalOps/replenishment` | `WEB_UI_VIEW_REPLENISHMENT_ORDER` |
| 4 | Internal Ops → Cycle Count | `/internalOps/cycle-count` | `WEB_UI_VIEW_CYCLECOUNT` |
| 5 | Outbound → Pick Pack | `/outbound/pick-pack` | `WEB_UI_VIEW_PICKING_ORDER` |
| 6 | Outbound → Club | `/outbound/club` | `WEB_UI_VIEW_CLUB_LINE` |
| 7 | Outbound → Transfer | `/outbound/transfer` | `WEB_UI_VIEW_TRANSFER_ORDER` |
| 8 | Outbound → Outbound BOL | `/outbound/outbound-bol` | `WEB_UI_VIEW_BILL_OF_LADING` |
| 9 | Processes → Club Run | `/processes/club-run` | `WEB_UI_VIEW_CLUB_LINE` |
| 10 | Processes → Transfer Picking | `/processes/transfer-picking` | `WEB_UI_VIEW_TRANSFER_ORDER` |
| 11 | Handling Units | `/handlingUnits/handling-units` | `WEB_UI_VIEW_CONTAINER`, `WEB_UI_VIEW_STOCK_UNIT` |
| 12 | Master Data → Location Data → Storage Locations | `/masterData/locationData/storage-locations` | `WEB_UI_VIEW_STORAGE_LOCATION` |
| 13 | … → Location Types | `/masterData/locationData/location-types` | `WEB_UI_VIEW_STORAGE_LOCATION_TYPE` |
| 14 | … → Fixed Locations | `/masterData/locationData/fixed-locations` | `WEB_UI_VIEW_FIXED_ASSIGNMENT` |
| 15 | … → Functional Areas | `/masterData/locationData/functional-areas` | `WEB_UI_VIEW_AREA` |
| 16 | … → Sections | `/masterData/locationData/sections` | `WEB_UI_VIEW_SECTION` |
| 17 | … → Unit Load Types | `/masterData/locationData/unit-load-types` | `WEB_UI_VIEW_UNIT_LOAD_TYPE` |
| 18 | Master Data → Material Data → SKU Data | `/masterData/materialData/sku-data` | `WEB_UI_VIEW_ITEM_DATA` |
| 19 | … → SKU Units | `/masterData/materialData/sku-units` | `WEB_UI_VIEW_ITEM_UNIT` |
| 20 | … → Packaging | `/masterData/materialData/packaging` | `WEB_UI_VIEW_CASE_TYPE` |
| 21 | Reports → Inventory Report | `/reports/inventory-report` | `WEB_UI_VIEW_INVENTORY_RECORD` |
| 22 | Reports → Lock Report | `/reports/lock-report` | `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` |
| 23 | Reports → Receiving Report | `/reports/receiving-report` | `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` |
| 24 | Reports → SKU Location Report | `/reports/sku-location-report` | `WEB_UI_VIEW_LOCATION_OVERVIEW` |
| 25 | Reports → Flowbin Report | `/reports/flowbin-report` | `WEB_UI_VIEW_FLOWBIN_MONITOR` |
| 26 | Reports → Parcel Picking Report | `/reports/parcel-picking-report` | `WEB_UI_VIEW_PARCEL_MONITOR` |
| 27 | Reports → Outbound Parcel Report | `/reports/outbound-parcel-report` | **no plausible constant exists** |
| 28 | Reports → Stock Unit Record | `/reports/stock-unit-record` | `WEB_UI_VIEW_STOCK_UNIT_RECORD` |
| 29 | Reports → Container Record | `/reports/container-record` | `WEB_UI_VIEW_UNIT_LOAD_RECORD` |
| 30 | Admin (6 tabs, §3.9.2) | `/admin` | `WEB_UI_VIEW_USER_MANAGEMENT` + per-tab |

Commented-out menu entries (present in source, not rendered): Receiving → Lookup, Reports → Data Report, Master Data → Strategies (Test).

#### 3.9.2 Admin tab → function

`pages/admin.vue:51-58`. All six render for everyone; component roots are under `components/admin/<tab>/`.

| Tab | Component dir | Intended function (⚠ not enforced) |
|---|---|---|
| System Management | `systemManagement/` | `WEB_UI_VIEW_IMPORT_DATA` (hosts the CSV upload screens) |
| Parameters & Configuration | `parametersAndConfiguration/` | `WEB_UI_VIEW_SYSTEM_PROPERTY` |
| Shippers | `shippers/` | **no constant exists** |
| User Management | `userManagement/` | `WEB_UI_VIEW_USER_MANAGEMENT`, `_USER`, `_GROUP`, `_ROLE`, `_FUNCTION` |
| Printer Setup | `printerSetup/` | `WEB_UI_VIEW_PRINTER` |
| Service Log | `serviceLog/` | `WEB_UI_VIEW_MESSAGES` |

⚠️ **User Management is the sharp edge.** It is the screen that edits `UserRole`/`UserGroup`/`UserFunction` rows, it is reachable by any `wms_user`, and the `AdminController` endpoints behind it were the five ungated ones in §2.1. On an unmerged branch (SBDEV-2870) the four write/read endpoints now require **`WEB_UI_VIEW_USER_MANAGEMENT`** — the same function that *should* gate the tab — so once merged the server half of this screen is closed on the same axis the client half will use. The client half is still fully open: `pages/admin.vue:51-58` renders all 6 tabs unconditionally (SBDEV-2967).

#### 3.9.3 Reverse gap — `WEB_UI_VIEW_*` constants with no page at all

Grepped `pages/` + `components/` for each; no page or component exists. All 8 are seeded to `role_super_admin` (§4), so they are granted and inert:

`WEB_UI_VIEW_RACK` · `_RACK_ROW` · `_TYPE_CAPACITY_CONSTRAINT` · `_STOCK_COUNT` · `_SEQUENCE_NUMBER` · `_DB_QUERIES` · `_CLIENT` · `_ORDER_DETAIL_MONITOR`

Four of these (`CLUB_LINE`, `CONTAINER`, `SEQUENCE_NUMBER`, `STOCK_COUNT`) are called out as **v1-only** in [wms1-function-permission-map.md](./wms1-function-permission-map.md) §"Key point for v1→v2 migrations" — that claim is now stale for `CLUB_LINE` and `CONTAINER` (both exist in v2's enum and have v2 pages) but holds for `SEQUENCE_NUMBER` and `STOCK_COUNT`.

**Not in this list, and not a gap:** the `*_POSITION`, `*_ITEM_LINES`, `_GOODS_RECEIPT*`, `_ORDER*`, `_PICKING_*`, `_BILL_OF_LADING_POSITION`, `_CYCLECOUNT_POSITION` constants. Those correspond to `_id.vue` detail routes reached from a list page, which legitimately have no menu entry.

#### 3.9.4 What this means when reading §3.2–§3.7

Those tables answer *"which page was this constant minted for?"* — they remain the correct design intent and the right reference when provisioning. They do **not** answer *"what happens if the user lacks it?"* On the web UI today the answer is uniformly **nothing happens** — the page renders. Only §3.8 (mobile) describes a gate that actually fires.

---

## 4. Personas (DB-backed `UserRole` / `UserGroup` seed rows) → Function Assignments

`UtilRestController` seeds a fixed set of **7 personas** on first run (`:239-245` create `UserRole`s; `:247-253` create matching `UserGroup`s). **These are NOT Keycloak realm/composite roles** — they are rows in the tenant DB `UserRole` / `UserGroup` tables, created via `userRoleService.createEntity(...)` and `userGroupService.createEntity(...)`, then wired by `accessService.addFunctionToRole(...)` / `addRoleToGroup(...)` / `addGroupToUser(...)`. The `WEB_UI_*` / `MOBILE_UI_*` "roles" they grant are `UserFunction` rows (the `FunctionEnum` constants). The mapping is code-declared in `UtilRestController` — changing it requires a backend deploy, not a Keycloak admin change.

The 7 seeded `UserRole`s (`:239-245`):

| Persona (`UserRole`) | Job title | Granted functions (from `UtilRestController`) |
|---|---|---|
| `inventory-manager` (:239) | Warehouse inventory ops lead | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_CYCLE_COUNT`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER`, `WEB_UI_LOG_IN`, `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW`, `WEB_UI_VIEW_REPLENISHMENT_MONITOR`, `WEB_UI_VIEW_FLOWBIN_MONITOR`, `WEB_UI_VIEW_PARCEL_MONITOR`, `WEB_UI_VIEW_DB_QUERIES` (:273-283) |
| `inventory-worker` (:240) | Floor inventory worker | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_CYCLE_COUNT`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER` (:285-289) |
| `outbound-forklift` (:241) | Forklift operator | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_TRUCK_LOADING` (:291-293) |
| `outbound-manager` (:242) | Outbound ops lead | Mobile: `LOG_IN`, `INFO`, `PALLETIZING`, `PICKING`, `STOCK_TRANSFER`, `TRANSFER`, `TRUCK_LOADING`; Web: `LOG_IN`, `BILL_OF_LADING`(+`_POSITION`), `ORDER`(+`_BATCH`/`_POSITION`), `PICKING_ORDER`/`_POSITION`/`_UNIT_LOAD`, `LOCATION_OVERVIEW`, `ORDER_MONITOR`, `REPLENISHMENT_MONITOR`, `FLOWBIN_MONITOR`, `PARCEL_MONITOR`, `DB_QUERIES` (:295-316) |
| `outbound-worker` (:243) | Packing/palletizing floor | `MOBILE_UI_LOG_IN`, `MOBILE_UI_VIEW_INFO`, `MOBILE_UI_VIEW_PALLETIZING`, `MOBILE_UI_VIEW_PICKING`, `MOBILE_UI_VIEW_STOCK_TRANSFER`, `MOBILE_UI_VIEW_TRANSFER` (:318-323) |
| `receiving` (:244) | Inbound / receiving | Mobile: `LOG_IN`, `INFO`, `PUT_AWAY`, `REPLENISHMENT`, `STOCK_TRANSFER`, `TRANSFER`; Web: `LOG_IN`, `CREATE_INBOUND_BOL`, `GOODS_RECEIPT`(+`_POSITION`), `INBOUND_BOL`(+`_ITEM_LINES`), `RECEIVED_STOCK_OVERVIEW`, `RECEIVING`, `REPLENISHMENT_ORDER` (:325-339) |
| `super-admin` (:245) | SiteBoss / global admin | Nearly every `WEB_UI_*` and `MOBILE_UI_*` function, including all 8 `WEB_UI_ACTION_*`, all 8 admin-panel `WEB_UI_VIEW_*`, and `WEB_UI_VIEW_USER_MANAGEMENT` (:341-416) |

**Group wiring** (`:260-271`): each `UserGroup` aggregates one or more `UserRole`s — e.g. `group_inventory_manager` contains both `role_inventory_manager` and `role_inventory_worker` (:260-261); `group_outbound_manager` contains forklift+manager+worker (:264-266); `group_receiving` aggregates `inventory-worker` + `outbound-worker` + `receiving` (:268-270). The seed `admin` user is placed directly in `group_super_admin` (:255) and additionally granted `WEB_UI_VIEW_USER_MANAGEMENT` + `WEB_UI_LOG_IN` as user-level functions (:257-258).

### 4.1 Live drift — the seed is a starting point, not the current state

Sampled 2026-08-15. `initDB` runs once; everything after that is admin-UI edits, so **do not assume a tenant matches the code seed.**

| | Hydra UAT | WineCo dev |
|---|---|---|
| `mywms_function` rows | 80 (= enum exactly) | 80 |
| Named roles / groups | 7 / 7 | **11 / 11** |
| Users | 19 | 96 |
| Users in `super-admin` | **15 of 19** | **39 of 96** |

Four things to know before trusting §4's table:

1. **`super-admin` is the de-facto default.** 79% of Hydra UAT users hold it. Persona-based reasoning describes almost nobody.
2. **Tenants author their own roles.** WineCo dev has a hand-built **`CS-REP`** role (28 functions, 3 users) that exists in no code path — plus Cypress debris (`cy-test-role-*`, `cy-test-group-*`, `test role`, `test group`, all 0 functions / 0 users) that a cleanup should sweep.
3. **Grants drift from the seed.** `MOBILE_UI_VIEW_CANCELLATION` is granted to `super-admin` on Hydra UAT although `UtilRestController` never grants it — someone added it through the admin UI. Verified role function-counts otherwise match the seed exactly (11 / 5 / 3 / 23 / 7 / 15 / 77).
4. **Connector rows accumulate.** Hydra UAT has 7 connector roles + 22 connector groups; **5 of the 7 reach no user at all** (`ROLE000010`–`ROLE000014`, holding `WEB_UI_VIEW_USER_MANAGEMENT`, `WEB_UI_LOG_IN`, `SPECIAL_DEVELOPER`, `MOBILE_UI_VIEW_LPN_ASSOCIATION`, `MOBILE_UI_NEVER_TIME_OUT`) — orphaned leftovers of `addFunctionToUser`/`removeFunctionFromUser`. They inflate role/group counts and are invisible in the admin UI. WineCo dev additionally attaches a connector role to every named group (`ROLE000082`–`ROLE000088`), from group-level function grants.

**Also live:** 4 of Hydra UAT's 19 users (`anonymous`, `omallozzi2`, `oms_integration`, `pesposito`) belong to **no group**, so `getAllRoles` returns an empty list and the mobile app bounces them to `/not-authorized` (§9, "user can't see a page").

---

## 5. Orphans

**Defined but no consumer found (as of 2026-06-24):**

The 8 admin-panel `WEB_UI_VIEW_*` (`IMPORT_DATA`, `SYSTEM_PROPERTY`, `CLIENT`, `USER`, `GROUP`, `ROLE`, `FUNCTION`, `MESSAGES`) and **all 8 `WEB_UI_ACTION_*`** are **no longer orphans** — each is now assigned to `role_super_admin` in `UtilRestController` (admin-panel views at :360-405, actions at :351-354, 413-416). The only remaining true orphans:

| Role | Likely status |
|---|---|
| `SPECIAL_DEVELOPER` (`FunctionEnum:423`) | Defined; never seeded to any persona, no consumer found. Purpose unclear |
| `MOBILE_UI_VIEW_LPN_ASSOCIATION` (`:421`) | Menu block commented out (`store/home.js:94-98`); not seeded. Reserved for future LPN flow |
| `MOBILE_UI_VIEW_CANCELLATION` (`:422`) | ⚠️ **No longer an orphan in practice.** Present in the mobile menu (`store/home.js:89-92`, tile titled "Return to Stock (RTS)") and **not seeded** by `UtilRestController` — but it **is** granted to `super-admin` on Hydra UAT via a runtime admin-UI edit (§4.1). Code-orphan, live-active |
| `MOBILE_UI_NEVER_TIME_OUT` (`:411`) | Session-timeout override; not a view role, not in the menu, not seeded |

Orphans fall into two honest categories:

1. **UI-only gated** — web UI hides the page or button, backend does not re-enforce. A determined user can bypass by direct API call.
2. **Reserved** — defined for future use; no feature yet exists.

Audit recommendation: grep the `wms2-web-ui` repo for each "orphan" to classify definitively. This matrix only reports what `wms2-api` + `wms2-mobile-ui` know about.

---

## 6. Group Paths (NOT roles)

Two sysprop-backed group paths gate tenant / warehouse scoping. They are Keycloak **group paths**, not realm roles:

| Sysprop | Default | Purpose |
|---|---|---|
| `APP_GROUP` | `/wms/wh/user` | Standard user — implied warehouse membership |
| `APP_ADMIN_GROUP` | `/wms/wh/wms_admin` | Admin — implied warehouse-admin membership |
| `KEYCLOAK_APP_GROUP_NAME` | — (per-tenant) | Tenant-configurable app group name |

Consumed by:

- `AdminController` endpoints `POST /v3/user/addUserToWarehouseGroup`, `POST /v3/user/removeUserFromWarehouseGroup`, `GET /v3/user/isWarehouseUser` — ⚠️ all three now have their `@PreAuthorize` commented out (§2.1)
- `KeycloakService` (service-level integration with Keycloak Admin API)
- Token parsing on the mobile UI (`tokenParsed.warehouse` claim exposes the array of facility codes the user can access — see [wms2-end-to-end-request-journey.md](./wms2-end-to-end-request-journey.md) §3)

Group paths determine *which* tenant+facility a user belongs to. Realm roles determine *what* they can do within that tenant+facility. Both must match for a request to succeed.

### 6.1 `SecurityConfiguration` path-level authority rules

The only HTTP-path-level authority enforcement lives in `SecurityConfiguration.java:116-136`. It is coarse — there are **no per-function path matchers**; everything below the actuator tier collapses to `wms_user`:

| Matcher | Authority | Source line |
|---|---|---|
| `/actuator/health/**`, `/actuator/info` | permitAll | :116 |
| `/actuator/**` | `ADMIN` or `wms_admin` | :117 |
| `/`, `/v3`, `/v3/token`, `/error`, `/rest/**`, `/api/**`, `/api-docs/**`, `/swagger-ui/**`, `/swagger-ui.html`, `/api/public/**` | permitAll | :120-124 |
| `/v3/adminAction/**`, `/v3/sysprop/**`, `/v3/systemProperty/**`, `/v3/printer/**`, `/userDetailsById/**`, `/userGroup/**`, `/user/**` | `wms_user` | :130-133 — ⚠️ the last three matchers are **root-relative** and do **not** match `/v3/user/**`; those requests fall through to the `/v3/**` rule below |
| `/v3/**` | `wms_user` | :133 |
| everything else | authenticated | :136 |

This is why the commented-out `@PreAuthorize` guards in §2.1 matter: with the annotation gone, `/v3/user/**` endpoints are reachable by any `wms_user`, not just `sb_admin`.

---

## 7. Service-Account Role — `KEYCLOAK_API_USER`

Defined as a sysprop (see [wms2-sysprop-catalog.md](../data-dictionary/wms2-sysprop-catalog.md) §9). Used by:

- WMS → OMS calls (OMS-side identity)
- WMS → Keycloak Admin API calls (user/role provisioning)

Not a realm role in the sense above — it's a service-account principal. Its authorization is Keycloak-client-configured; changing it requires Keycloak admin, not WMS deploys.

---

## 8. Known Landmines

0. 🔴 **The web UI menu is not filtered by anything** (§3.9) — **[SBDEV-2967](https://app.clickup.com/t/868krr3rq)**. `layouts/default.vue:284-285` returns `menuList["super-admin"]` for every user; the 4 other persona menus in `util/appMenuList.js` are dead code. Do not read §3.2–§3.7's "Web UI page" column as a gate — it is a naming convention. The practical blast radius is the Admin screen: any `wms_user` can open `/admin` → User Management and edit the role model itself. The API behind it is the §2.1 SBDEV-2870 surface — server-side code is written (unmerged), the client half is this ticket.
1. **Mobile UI gating is client-side only** — **[SBDEV-2968](https://app.clickup.com/t/868krr3rw)**. `MOBILE_UI_VIEW_*` roles filter the static menu but the backend does not re-enforce them. API replay / deep link bypasses the gate. Security-sensitive mobile workflows should duplicate the check at the backend service layer. **This is now the only function-based gate that fires anywhere in either UI.**
2. **`WEB_UI_VIEW_TRANSFER_ORDER` in the mobile menu** (§3.8) is a naming oversight — the mobile Transfer Process page uses a `WEB_UI_*` role. Don't rename without a realm-role migration. **Live consequence:** no mobile-only persona (`inventory-worker`, `outbound-worker`, `receiving`) is granted that constant in §4, so the Transfer Process tile is invisible to all of them — only `super-admin` sees it.
3. ~~**Most `WEB_UI_ACTION_*` roles are enforced at service layer, not annotation layer.**~~ 🔴 **Corrected 2026-08-15 — they are enforced nowhere.** Only `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` has any check (5 sites, §3.7). The other 7 destructive-action constants are granted, displayed in the admin UI, and ignored. Adding a `FunctionEnum` constant does **not** create a gate; you must also add the `accessService.doesUserHaveAccess(...)` call.
4. **Personas are DB-backed seed rows hard-coded in `UtilRestController`, not Keycloak composite roles.** They are `UserRole`/`UserGroup`/`UserFunction` rows seeded on first run (`:239-416`). A new persona — or a new function added to an existing persona — requires a code change + deploy, not a Keycloak-only operation.
5. **Group paths vs realm roles are distinct.** A user with all the right roles but no matching group membership will still fail tenant routing — and vice versa.
6. **Orphan roles are defined but unused.** Granting them to a persona is a no-op until a consumer exists. Use the table in §5 before expecting a new permission to take effect.
7. **`@PreAuthorize(Authority.IS_SB_ADMIN)` enforcement is thin, and was recently zero.** It guards **18 active** gates — and from 2025-10-29 to 2026-08-07 it guarded **none of them**, because the expression named a method that did not exist and threw HTTP 500 for every caller (SBDEV-2863). **Nothing in the test suite could catch that**: `BaseControllerUnitTest:50` uses `standaloneSetup`, so no controller test evaluates `@PreAuthorize` at all, and the `@SpringBootTest` lane is down (SBDEV-2217). A durable guard is tracked by **SBDEV-2872**. Separately, **5** endpoints were ungated (**SBDEV-2870** — gated on `wms_admin` on an unmerged branch, 3 of 6 ACs met). Everywhere else enforcement is service-layer — easy to miss when refactoring, and easy to silently disable by commenting an annotation.
8. **`MOBILE_UI_NEVER_TIME_OUT` is not a view role.** Granting it changes session timeout behavior on the mobile UI only. Don't assign casually.

---

### 8.x SBDEV-2732 — a controller outside `/v3` is NOT covered by the `wms_user` rule (PR #139, open)

`SecurityConfiguration` gates `/v3/**` at `wms_user`; **everything else falls through to
`.anyRequest().authenticated()`**. `PutawayConfigController` is mapped at `/putawayConfig`, not
`/v3/putawayConfig`, so on first cut it was reachable by any principal holding a valid tenant-realm JWT
with **zero app authorities** — a principal every other business endpoint in this app rejects. Fixed by
naming it in the matcher: `.requestMatchers("/v3/**", "/putawayConfig/**")`.

**Generalise this before adding a controller:** a new `@RequestMapping` outside `/v3` inherits
*authentication only*, never `wms_user`. Check the matcher, not just the `@PreAuthorize`.

Two more from the same review, worth carrying:

- **`@PreAuthorize` on a Spring Data REST `@RepositoryEventHandler` is unreliable.** SDR registers the
  handler through its own `AnnotatedHandlerBeanPostProcessor` while method security is applied by a
  different one; depending on BPP ordering SDR can capture the **raw target** rather than the security
  proxy, leaving the annotation inert and the guard silently never firing. Put the authority on an
  ordinary `@Service` the handler calls instead — that bean is reliably proxied.
- **Do not call an admin-gated method unconditionally from a create handler.** SBDEV-2732 briefly made
  every HAL `POST /v3/itemdata` and `/v3/client` require `sb_admin`, because the handler called a
  `@PreAuthorize(IS_SB_ADMIN)` method on every create rather than only when a putaway destination was
  actually set.

---

## 9. How to use this doc

| Task | Start at |
|---|---|
| Security audit (who can hit endpoint X?) | **§8 item 0 first** — on the web UI the answer is usually "everyone". Then §3 find the role → §4 find the personas that grant it → the users in that persona's `UserGroup` |
| Adding a new mobile page | §3.8 reserve a `MOBILE_UI_VIEW_*` constant in `WmsConstants.FunctionEnum` → add entry in `store/home.js:setStaticMenus` → seed it to a persona in `UtilRestController` → enforce at service layer (§8 item 1) |
| Adding a new web page | §3.9 — there is no gating hook to add it to. Adding a `WEB_UI_VIEW_*` constant creates provisioning metadata only; if the page must be restricted, you need a real check (`@PreAuthorize`, or `accessService.doesUserHaveAccess`) on the backend |
| Adding a new admin page | §2.1 if truly admin-only, guard with `@PreAuthorize(Authority.IS_SB_ADMIN)` on the controller (and check it isn't commented out — §2.1 gap). §3.9.2 — do **not** rely on the Admin tab being hidden |
| Adding a new persona | §4 edit `UtilRestController` seed block (`:239-416`) → code deploy. Note §4's live-drift warning: prod/UAT rows may already diverge |
| Debugging "user can't see a page" | Web → §3.9, the menu is unfiltered so the cause is *not* roles (check tenant/warehouse group, §6). Mobile → persona (`UserGroup`/`UserRole`) → §4 → §3.8 view-role → menu filter. **A user in no `mywms_group` at all gets an empty mobile menu and is bounced to `/not-authorized` with no explanation** (`pages/index.vue:196-200`) |
| Debugging "user can hit an endpoint they shouldn't" | §8 items 0/1/3 — on current code the check almost certainly does not exist |
| Cleaning up orphans | §5 for the function-level orphans; §3.9.3 for the 8 `WEB_UI_VIEW_*` constants with no page; §4 for the live connector-role and Cypress-fixture debris |
| **Designing anything new** | **§1.1 first** — the target state collapses four namespaces into one, and designing against §2–§9 will produce work that has to be redone |
| Moving a gate off `sb_admin` | §1.1 "What moves" for the target function, then §1.1 "Ordering" — the sequence fails in *both* directions |

---

## 10. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | All constants in `WmsConstants.FunctionEnum:344-422`, `AdminController` `@PreAuthorize` usage, `UtilRestController` composite role init, `wms2-mobile-ui/store/home.js:setStaticMenus`, `Authority.java` SB_ADMIN definition | All 51 realm-role constants accounted for; 3 composite roles + 3 additional personas enumerated | Code read (grep-based across 3 repos) |
| 2026-06-24 | Full re-read of `WmsConstants.FunctionEnum:344-423`, `Authority.java`, `AdminController.java` (every `@PreAuthorize`), `UtilRestController.java:239-416` (persona seed + function bundles), `SecurityConfiguration.java:116-136`, `wms2-mobile-ui/store/home.js:setStaticMenus` | **80 constants** (66 `WEB_UI_*` :344-409, 13 `MOBILE_UI_*` :410-422, 1 `SPECIAL_*` :423) — up from 51. **7 DB-backed personas** (added `receiving`); personas are `UserRole`/`UserGroup` seed rows, **not** Keycloak composites — prior characterization corrected. The 8 admin-panel `WEB_UI_VIEW_*` + all 8 `WEB_UI_ACTION_*` are no longer orphans (seeded to `super-admin`). ⚠️ **Security gap:** 4 `AdminController` `@PreAuthorize` guards commented out (:197,261,282,310) + 1 new unguarded endpoint (:350 `/user/existsInKeycloak`) — only 8 endpoints still guarded. | Code read (executor re-verify) |
| 2026-08-15 | **Web + mobile menu audit.** `wms2-web-ui`: `layouts/default.vue:284-285`, all 5 keys of `util/appMenuList.js`, `store/index.js:92-101`, `pages/index.vue:114`, `pages/admin.vue:51-58`, absence of `middleware/`, repo-wide grep for `WEB_UI_VIEW`/`WEB_UI_ACTION`/`FunctionEnum`, and a page/component grep for each unmapped constant. `wms2-mobile-ui`: `store/home.js:19-118`, all 14 pages checked for route guards. `wms2-api`: `WmsConstants.FunctionEnum` recount, every `doesUserHaveAccess` call site, `UserRepository.getAllRoles:26-34`, `UtilRestController:239-416`. Live `SELECT`s on Hydra UAT + WineCo dev. | **80 constants confirmed** (57 `WEB_UI_VIEW_*` + 1 `WEB_UI_LOG_IN` + 8 `WEB_UI_ACTION_*` + 13 `MOBILE_UI_*` + 1 `SPECIAL_*`) — unchanged since 2026-06-24. **New §3.9: all 30 web menu items are ungated**; the web menu is hardcoded to `super-admin` and 4 of 5 persona menus are dead code. **§3.7 + §8 item 3 corrected** — only 1 of 80 functions is enforced anywhere (`WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`, 5 sites), not 8. Mobile: 12/12 tiles mapped, 1 uses a `WEB_UI_*` constant. **New §3.9.3**: 8 `WEB_UI_VIEW_*` constants have no page. **New §4.1**: live tenants drift from the seed (custom `CS-REP` role, 79% of Hydra UAT users are `super-admin`, orphaned connector rows, `MOBILE_UI_VIEW_CANCELLATION` granted at runtime — §5 row corrected). | Code read + live DB (Nam Park) |
| 2026-08-16 | **Target state agreed and recorded (§1.1).** Business rule from Brent (BA): configuring default putaway locations belongs to `super-admin`, and **no function should be restricted to `sb_admin`**. Verified the two structural carve-outs against code: `SecurityConfiguration.java:117` gates `/actuator/**` on `ADMIN`/`wms_admin` and cannot be function-gated (per-JVM, no `TenantContext`, no tenant DB to read); and `wms2-mobile-ui/pages/index.vue:80` derives the facility list from `tokenParsed.warehouse`, so facility scope cannot become a function (choosing the facility is what selects the function table). | Three Keycloak groups retained — `wms_user` (app access **+ facility scope**), `wms_admin` (`/actuator/**` only), `sb_admin` (**identity only, never enforced**). All 18 `IS_SB_ADMIN` gates re-home onto `FunctionEnum`; the 5 on `PutawayConfigService` need an explicit `accessService` call rather than SBDEV-2968's HTTP-layer interceptor. **Unblocks SBDEV-2870.** Two items left open: break-glass recovery, and whether `importUsersFromCsvText` stays SiteBoss-only. | Nam Park + Brent (BA); carve-outs code-verified |
| 2026-08-17 | **SBDEV-2870 partial implementation + a new finding.** All five previously-ungated `AdminController` endpoints gated on `@PreAuthorize(Authority.IS_WMS_ADMIN)` (branch `bugfix/SBDEV-2870-restrict-csv-user-import-to-wms-admin`, unmerged); `wms_admin` chosen over `sb_admin` per §1.1, which also dissolves the original UI blocker. Reconciled §1 fact 2, §2.1, §3.1, §3.9.2 and §8 items 0/7, which all still described the five as currently ungated. | **3 of 6 ACs met.** ❌ AC-4 — no `wms2-web-ui` change, and the assumption that User Management's users hold `wms_admin` is unverified. ❌ AC-5 — no test proves the 403; bytecode verification only, `standaloneSetup` cannot evaluate `@PreAuthorize` (RC-2) and SBDEV-2217 blocks the `@SpringBootTest` lane, so the manual curl check is outstanding. **NEW:** `StockunitService.setLockDamaged` (`:360`) had no guard at all — the `ADJUST_LOCK_DAMAGED` check at `:232` is inside `transferStock` (`:150`) in a conditional branch — so `/transferToDamaged` and `/bulkTransferToDamaged` were open to any `wms_user`. Now gated at the controller (a service-layer guard would have returned **HTTP 200** with an errors array on the bulk path) with 4 ablation-proven tests. ⚠️ Only `super-admin` holds `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` on WineCo dev, so that gate removes the capability from ~13 live users. | Nam Park; code-verified + ablation-tested |

**Re-verify every 60 days.** Next due: **2026-10-14** — role churn is typically 2-4 constants per quarter; any feature that adds a new protected page invalidates this matrix.

> **Tickets filed from this audit (2026-08-15):**
> - **[SBDEV-2967](https://app.clickup.com/t/868krr3rq)** (high) — web UI has no authorization layer at all; menu hardcoded to `super-admin`, all 30 items ungated, Admin → User Management reachable by any `wms_user`. §3.9, §8 item 0. Coordinate with **SBDEV-2870** (same screen, server side).
> - **[SBDEV-2968](https://app.clickup.com/t/868krr3rw)** (normal) — mobile UI gating is menu-filter-only; no route guard and no `MOBILE_UI_VIEW_*` check anywhere in `wms2-api`. §3.8, §8 items 1–2. Also carries the `WEB_UI_VIEW_TRANSFER_ORDER` tile-visibility defect and the blank-screen-for-groupless-user case.
