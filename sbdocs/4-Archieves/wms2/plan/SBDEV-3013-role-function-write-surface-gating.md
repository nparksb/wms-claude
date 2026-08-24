---
title: "WMSv2: the role↔function write surface is ungated on all three doors — any wms_user can self-grant any function"
ticket: "SBDEV-3013"
ticket_url: "https://app.clickup.com/t/868kua9b6"
type: "bugfix"
priority: "high"
status: "archived — ✅ COMPLETE — BOTH DOORS MERGED, DEPLOYED AND VERIFIED LIVE 2026-08-21. Door ② `808819d` (PR #179); door ① `ae5ec98` (PR #181). THE ESCALATION IS CLOSED: measured on WineCo dev as `sbtest` (plain /wms_user) — step 1 POST /userRole/create 403, step 2 POST /userRole/saveRoleFunctions 403, step 2a POST /userRoleUserFunction 405, step 2b PATCH /userRole/{id}/functions 405, step 3 POST /userGroup/saveGroupRoles 403. Legitimate reads preserved: GET /userRole/{id}/functions 200 (Role admin screen), GET /userRoleUserFunction 200. Blast radius contained: itemdata/location still Allow POST. Ready to archive."
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-21
updated: 2026-08-21
db_verified: false
related:
  - SBDEV-2967-web-ui-function-gating-enforcement.md
  - SBDEV-2968-mobile-ui-function-gating-enforcement.md
  - SBDEV-3005-role-function-composite-key-swap.md
  - SBDEV-3011-delete-role-join-table-cascade.md
  - SBDEV-2870-ungated-user-admin-and-damaged-lock-endpoints.md
tags:
  - plan
  - security
  - authorization
---

# SBDEV-3013 — Close all three doors on the role↔function write surface

> **ARCHIVED 2026-08-21.** Both doors merged, deployed and verified live on WineCo dev — door ② `808819d`
> ([#179](https://github.com/SiteBossInc/wms2-api/pull/179)), door ① `ae5ec98`
> ([#181](https://github.com/SiteBossInc/wms2-api/pull/181)). The full escalation chain was re-run as a plain
> `wms_user` and fails at every step (403/403/405/405/403) while both legitimate GETs still return 200.
> Acceptance script retired to `sbdocs/4-Archieves/scripts/verify-SBDEV-3013-role-function-write-surface-gating.sh`.
> Implementation worktrees removed 2026-08-21: `wms2-api/SBDEV-3013`, `wms2-api/SBDEV-3013-door1`.
> One residual hygiene item (the two redundant grant rows) was widened into
> [SBDEV-3062](https://app.clickup.com/t/868kv11ed) rather than left recorded only here.

**Ticket:** [SBDEV-3013](https://app.clickup.com/t/868kua9b6)
**Repo:** `v2/wms2-api`
**Tier:** T2 for doors ② and ③ · T3 for door ① (published-API change)
**Blocked on:** nothing. ⚠ **Should follow [slice A](SBDEV-2967-A-axios-403-denial-not-logout.md)** — see §2. Needs **no grant migration and no business sign-off**.

> **Widened 2026-08-21.** This ticket previously owned only the two Spring Data REST doors, and its own text
> said *"Steps 1 and 3 are the controller-side half, which belongs with SBDEV-2967."* In 2967 that half sat
> in a trailing paragraph titled "Scope addition requested 2026-08-19", **behind Brent's master-data grant
> sign-off — a business decision it has no dependency on.** Splitting one escalation across two owners means
> it gets closed in two passes and is exploitable in between. One escalation, one owner, one PR.
>
> **This is the highest-severity item in the SBDEV-2967 family**: while it is open, every gate that
> SBDEV-2968 shipped and every gate SBDEV-2967 will ship is bypassable in three requests.

---

> ## ✅ CLOSED — full-chain proof on WineCo dev, 2026-08-21
>
> Both doors merged and deployed (door ② `808819d`, door ① `ae5ec98`). Re-ran the complete escalation as
> **`sbtest`, a plain `/wms_user`** — the same probe that returned **200** on every step earlier today:
>
> | Step | Request | Before | After |
> |---|---|---|---|
> | 1 | `POST /v3/userRole/create` | 200 | **403** (door ②) |
> | 2 | `POST /v3/userRole/saveRoleFunctions` | 200 | **403** (door ②) |
> | 2a | `POST /v3/userRoleUserFunction` | 200 | **405** (door ①) |
> | 2b | `PATCH /v3/userRole/{id}/functions` | 200 | **405** (door ①) |
> | 3 | `POST /v3/userGroup/saveGroupRoles` | 200 | **403** (door ②) |
>
> **Every door on every step. No path remains.**
>
> Nothing legitimate was lost, which was the whole reason `exported = false` was rejected:
>
> | Preserved | Result |
> |---|---|
> | `GET /v3/userRole/{id}/functions` — the Role admin screen | **200** |
> | `GET /v3/userRoleUserFunction` — reverse lookups | **200** |
> | `itemdata` / `location` `Allow:` header | **`HEAD,POST,GET,OPTIONS`** — writes intact, so the change did NOT make the HAL API read-only |
>
> This also **discharges the PR #181 caveat** that the unit test proved the configuration but not its
> effectiveness: SDR really does return 405, measured against the running system rather than inferred.

## 0. The escalation, end to end

Available to **any authenticated `wms_user`** on `develop` today. `SecurityConfiguration.java:151` gates
`/v3/**` with only `hasAnyAuthority("wms_user")`.

| Step | Request | Door | Gated? |
|---|---|---|---|
| 1 | `POST /v3/userRole/create` | ② controller | ❌ |
| 2 | grant it `WEB_UI_VIEW_USER_MANAGEMENT` — `POST /v3/userRole/saveRoleFunctions` | ② controller | ❌ |
| 2′ | …or the same write via `POST /v3/userRoleUserFunction` | ① SDR repository | ❌ |
| 2″ | …or via `PATCH`/`POST /v3/userRole/{id}/functions` | ① SDR association | ❌ |
| 3 | attach the role to a group they belong to — `POST /v3/userGroup/saveGroupRoles` | ② controller | ❌ |
| 4 | they now satisfy `denyUnlessUserManagementAllowed()` and reach everything SBDEV-2870 gated | — | — |

`mywms_role_mywms_function` is a link in the chain `UserRepository.getAllRoles` (`:27-34`) walks for **every**
access decision. Writing it grants functions.

> ✅ **ESCALATION PRE-STATE CONFIRMED LIVE, 2026-08-21** — as `sbtest`, a plain `/wms_user` with **no**
> `sb_admin`/`wms_admin` group and **no** `WEB_UI_VIEW_USER_MANAGEMENT`:
>
> | Probe | Today |
> |---|---|
> | `GET /v3/userRole/userRoleDetailsById/{id}` | **200** — door ②, closed by PR #179 |
> | `GET /v3/userGroup/userGroupDetailsById/{id}` | **200** — door ②, closed by PR #179 |
> | `GET /v3/userRoleUserFunction` | **200** — door ①, **NOT** closed by #179 |
> | `GET /v3/userRole/{id}/functions` | **200** — door ①, **NOT** closed by #179 |
>
> An unprivileged user can read the entire access model today. Write endpoints were deliberately **not**
> invoked — proving the escalation by performing it would mutate a shared dev database. The reads are
> sufficient to establish reachability, and they give a clean before/after for #179: the first two must
> become **403**, the last two will **stay 200** until door ① ships.

### 0.1 🔴 Door ② is six endpoints, not two — corrected 2026-08-21

SBDEV-2967's scope addition named `saveRoleFunctions` and `saveGroupRoles`. **Enumerated per-method on
`origin/develop` `5506117`: both controller classes carry zero `@RequiresFunction` and zero `@PreAuthorize`
— every endpoint on both is ungated.** Gating two of six would leave the escalation intact via step 1.

| # | Endpoint | Method | Kind | Role in the escalation |
|---|---|---|---|---|
| ②.1 | `POST /v3/userRole/create` | `createRole` (`:63`) | write | **step 1** |
| ②.2 | `GET /v3/userRole/delete/{roleId}` | `deletRole` (`:85`) | write | destructive; see SBDEV-3011 |
| ②.3 | `POST /v3/userRole/saveRoleFunctions` | `saveRoleFunctions` (`:99`) | write | **step 2** |
| ②.4 | `GET /v3/userRole/userRoleDetailsById/{id}` | (`:165`) | read | discovery |
| ②.5 | `POST /v3/userGroup/create` | `create` (`:59`) | write | — |
| ②.6 | `GET /v3/userGroup/delete/{groupId}` | `delete` (`:80`) | write | destructive |
| ②.7 | `POST /v3/userGroup/saveGroupRoles` | `saveGroupRoles` (`:99`) | write | **step 3** |
| ②.8 | `GET /v3/userGroup/userGroupDetailsById/{id}` | (`:119`) | read | discovery |

⚠ **Two destructive endpoints are `GET`** (②.2, ②.6). Independent of authorization that is wrong — GETs are
prefetchable, link-previewable, and land in browser history and access logs. **Not this ticket's job to
change the verb**, but a gate on a GET is weaker than a gate on a POST and it should be recorded.

### 0.2 Door ① — the two SDR surfaces

Unchanged from the original ticket text:

1. **`POST`/`DELETE /v3/userRoleUserFunction`** — `UserRoleUserFunctionRepository` is
   `@RepositoryRestResource(path = "userRoleUserFunction")`, and `RestConfiguration.java:40` includes
   `UserRoleUserFunction.class` in `exposeIdsFor`. Writes `mywms_role_mywms_function` directly.
2. **`/v3/userRole/{id}/functions`** — the association endpoint generated from `UserRole.functions`, a
   `@ManyToMany @JoinTable` over the same table (`UserRole.java:27-33`).

> ⚠️ **Correction to the ticket text — the verbs are not what it says.** Measured behaviour on the
> association resource: **`PUT` replaces (destructive)**, **`PATCH` and `POST` only add (non-destructive)**,
> and **collection `DELETE` is 405**; only `DELETE /{id}` removes one member. The ticket lists
> `PUT/PATCH/DELETE` as though all three were destructive. This matters for the fix: **`PATCH`/`POST` are
> the escalation verbs** — an attacker adds a grant, they do not need to replace the set — so a design that
> only suppresses the destructive verbs closes nothing.

`RepositoryRestHandlerMapping` **does not honour `WebMvcConfigurer.addInterceptors`** (SBDEV-2968 §3.1-A9),
so `FunctionGuardInterceptor` structurally cannot reach door ①. That is what makes it a separate mechanism
rather than three more annotations.

---

## 1. Fix design

### 1.1 Doors ② — `@RequiresFunction` on both controllers

The mechanism landed with SBDEV-2968 (`5506117`) and is verified present:
`security/RequiresFunction.java`, `security/FunctionGuardInterceptor.java`,
`security/FunctionGuardStartupAssertion.java`, plus the `FunctionGuardArchTest` golden map.

**Function: `WEB_UI_VIEW_USER_MANAGEMENT`** — matching `UserController`'s existing SBDEV-2870 guard and the
Admin → User Management tab these screens live under.

**Why this needs no grant migration and no sign-off:** `WEB_UI_VIEW_USER_MANAGEMENT` is **already held by
exactly the accounts that should have it**, so nobody loses a capability they legitimately exercise. This is
the entire reason the work does not belong behind P2.

> ⚠️ **Measured 2026-08-21 on two live tenants — and the live data is NOT the specification.**
>
> **Intended state (Nam, 2026-08-21): the super user is the only one who gets User Management.**
>
> Observed on **two distinct databases** (`dev_wh01_om1`, 96 users / 140 roles; `wh01_hydra_v2`,
> 19 users / 14 roles), `WEB_UI_VIEW_USER_MANAGEMENT` is held by **three** roles on each:
>
> | Role | Functions on the role | Reaches | Also in `super-admin`? |
> |---|---|---|---|
> | `super-admin` | many | 38 users (dev) · 15 (uat) | — |
> | `ROLE000008` | **exactly 1** — this function | `admin`, via `GROUP000008` | ✅ **yes** |
> | `ROLE000010` | **exactly 1** — this function | `sbuser1` (dev); no user on uat | ✅ **yes** |
>
> **The two extra grants are redundant.** `admin` and `sbuser1` are *already* in the `super-admin`
> group holding the `super-admin` role on both tenants, so those single-function roles confer
> nothing they do not already have — **removing them costs no access whatsoever**, and the
> intended super-user-only state is reachable with zero capability loss.
>
> 🔴 **Do not derive the gate's audience from this query, now or later.** Testers add roles for
> test purposes, and **until this ticket lands any `wms_user` can grant themselves this very
> function** — which is the defect being fixed. A holder query is therefore a snapshot of
> mutable drift, not a specification. Gate on the function; do not enumerate holders.
>
> **Optional follow-on — ✅ DISPOSED at archival 2026-08-21: moved to
> [SBDEV-3062](https://app.clickup.com/t/868kv11ed).** A data cleanup dropping the two redundant
> `(ROLE00000{8,10}, WEB_UI_VIEW_USER_MANAGEMENT)` rows so the holder set matches the intent. Zero access
> impact per the table above; not required for this gate to be correct. Widened into 3062 (the role/user
> hygiene bucket) rather than filed as a sibling ticket — it must not remain recorded only inside an
> archived plan.


#### ✅ RESOLVED at the TDD gate, 2026-08-21 — class-level, and the two reads ARE gated

**Decision: one class-level `@RequiresFunction` per controller, plus `GUARDED` membership — not six
method-level annotations.** Evidence gathered at the gate:

- **All 8 declared handlers are reached only from the Admin → User Management screen.** A web-UI grep finds
  callers only in `store/admin/role.js` and `store/admin/group.js`. That settles the two reads (②.4, ②.8):
  they are User Management data on a User Management screen — **gate them**.
- **The one non-admin caller is not affected.** `store/index.js` calls
  `/userGroup/search/findByUsername` on every login, but that is a **Spring Data REST search on the
  repository**, a different handler mapping the interceptor never sees. Gating the controller cannot break
  login.
- **Class-level fails closed for handlers added later**; six enumerated annotations do not.

⚠ **`GUARDED` membership is not optional and is a separate edit.** The interceptor only fail-closes an
unannotated handler when its declaring class is in `FunctionGuardInterceptor.GUARDED`. The class-level
annotation alone leaves a future handler falling through **open**. Both are required; the gate test
`bothControllersAreGuarded` pins it.

⚠ **Both controllers extend `AdminController`, and that surface is NOT covered here — correctly.** Its
handlers register under these classes' prefixes as aliases (e.g. `/v3/userRole/user/findUsers`), but the
interceptor keys on `getDeclaringClass()`, so they resolve to `AdminController`. They need no cover: **all
nine carry `@PreAuthorize(IS_SB_ADMIN)` from SBDEV-2870.** **Do not "close" them by annotating
`AdminController`** — it is the base class of 43 controllers, so a class-level gate there would apply to all
of them, and `FunctionGuardArchTest` AC-5 forbids it. Pinned by `adminControllerIsNotAnnotated`.

**Add the two classes to the `FunctionGuardArchTest` golden map** and to `FunctionGuardWiringUnitTest`'s
`EXPECTED_GUARDED`, or the startup assertion will not know they are supposed to be annotated and a later
refactor can drop a gate silently. Both edits are already in the gate branch.

### 1.2 Door ① — needs a decision, and it is the T3 half

Three candidate mechanisms, unchanged from the original ticket, with the association-verb correction applied:

| Option | Closes | Cost |
|---|---|---|
| `@RestResource(exported = false)` on the repository and on the `UserRole.functions` field | both SDR surfaces | **published-API change** — must confirm no client depends on them |
| `@PreAuthorize` on the repository query/write methods | both, per-method | must cover the generated association handlers, which have no method to annotate |
| A `RepositoryRestConfigurer`-registered interceptor | both, and every future SDR surface | new infrastructure — there is **no** `RepositoryRestConfigurer` in `src/main` today |

✅ **DECIDED 2026-08-21 (Nam): the third — a `RepositoryRestConfigurer`-registered interceptor.** It is the only option that closes the whole class rather than two endpoints, and **SBDEV-3017 needs that lane anyway** (~14 of the ~32 API roots behind the web menu are SDR-only). Building it once for door ① gives 3017 its mechanism for free.

Rationale, unchanged: SBDEV-3017 already records that ~14 of the
~32 API roots behind the web menu are SDR-only and equally unreachable by the interceptor. A
`RepositoryRestConfigurer` lane is the mechanism that ticket will need anyway.

**But do not couple the two halves in one PR.** Doors ② ship in a day and close steps 1 and 3 of a live
escalation; door ① is a published-API decision. Ship ② first, then ①.

Precedent for `exported = false`: `MessageRepository.java:32,42` already does exactly this.

---


#### 🔄 Door ① re-surveyed 2026-08-21 against `develop` `dc56849` — two corrections

`develop` moved twice after door ② merged: **#173 (SBDEV-3011)** and **#180 (SBDEV-2984)**, both touching
these files. Re-measured:

**Correction 1 — the "new infrastructure" claim is WRONG.** This plan and the ticket both say *"There is
currently no `RepositoryRestConfigurer` in `src/main`, so this would be new infrastructure."*
**`RestConfiguration.java:22` already implements `RepositoryRestConfigurer`** (it is where `exposeIdsFor`
lives). The recommended mechanism is therefore **extending an existing config class, not building new
infrastructure** — materially cheaper than the estimate that informed the decision.

**Correction 2 — SBDEV-3011 partially hardened one surface, and neither door is closed.**

| Surface | State on `dc56849` |
|---|---|
| `POST`/`DELETE /v3/userRoleUserFunction` | **fully exposed.** Still `@RepositoryRestResource(path="userRoleUserFunction")` over `PagingAndSortingRepository` + `CrudRepository`. The `@RestResource(exported=false)` at `:70` covers only 3011's new `deleteByRoleId` helper — **not** the CRUD surface. |
| `/v3/userRole/{id}/functions` | **still exposed.** `UserRoleRepository` now extends `NoDeletePagingAndSortingRepository` (3011 Fix D, at `repo/cinterface/`), which suppresses repository-level deletes — but that class's **own javadoc (`:28`) states `@RestResource(exported=false)` on repository methods does not reach the association endpoint.** |

Confirmed live earlier the same day: as a plain `wms_user`, both `GET /v3/userRoleUserFunction` and
`GET /v3/userRole/{id}/functions` returned **200**.

**A useful precedent now exists:** `NoDeletePagingAndSortingRepository` shows this codebase's established
way of suppressing SDR verbs via a `@NoRepositoryBean` base interface. Door ① can follow either that
pattern or the `RepositoryRestConfigurer` already present — **re-cost the decision against both before
implementing**, since the original comparison assumed one of them did not exist.

## 2. Sequencing

| Order | Work | Why |
|---|---|---|
| **0** | 🔴 **[SBDEV-2967-A](SBDEV-2967-A-axios-403-denial-not-logout.md) — the axios 403 fix** | **Added 2026-08-21 at the TDD gate.** See the box below. |
| 1 | Doors ② — class-level gates + `GUARDED` + golden-map entries + tests | closes steps 1 and 3 |
| 2 | Door ① — mechanism decision, then implementation | published-API change, needs its own review |

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

> 🔴 **Slice A should ship first, or in the same release. Found at the TDD gate 2026-08-21.**
>
> This ticket's gates produce **403s on the web UI**, and `wms2-web-ui/plugins/axios.js` still treats a 403
> like a 401 — three retries, then `$kc.logout()` on an authenticated session. Concretely, today:
>
> 1. SBDEV-2967-B has not shipped, so the **Admin menu renders for every user**.
> 2. Opening Admin → User Management calls only Spring Data REST endpoints — ungated, fine.
> 3. **Clicking a role calls `userRoleDetailsById`, which this ticket gates → 403 → the operator is logged
>    out** rather than told they lack permission.
>
> Gating the two reads (§1.1) is correct for security and widens this UX blast radius; slice A is the right
> fix, not weakening the gate. Slice A is one file with no dependencies and no sign-off.
>
> **If ② ships first anyway, accept the window explicitly** — the symptom is a silent logout, which reads as
> a session bug and will be reported as one.

⚠ **SBDEV-3012 edits `saveRoleFunctions` and `saveGroupRoles` too** (non-atomic delete-then-insert wipes
assignments on partial failure). Different defect, different acceptance criteria, so the tickets stay
separate — but **whoever goes second rebases onto files the first just changed.** Coordinate before
starting; the annotation is a one-line addition above the method, so this ticket is the cheaper one to go
second.

~~⚠ **SBDEV-3011** (`deletRole` cascade, PR #173) touches ②.2.~~ **RESOLVED 2026-08-21 — PR #173 merged
as `7d0fd13`, so ②.2 is already on `develop`; door ② (PR #179, `808819d`) also merged. No collision left
on either. **SBDEV-3005** (`on qa`) still touches the `saveRoleFunctions` body — check it before branching
door ①.

---

## 3. Acceptance criteria

| # | Criterion | Test |
|---|---|---|
| 3-1 | Each of the six write endpoints returns **403** without `WEB_UI_VIEW_USER_MANAGEMENT` | one deny/allow pair per endpoint — **per endpoint, not per controller** |
| 3-2 | Each returns 2xx **with** the function | same pairs |
| 3-3 | Both controllers appear in the `FunctionGuardArchTest` golden map | ArchUnit |
| 3-4 | The startup assertion fails if an annotation is removed | mutation check — delete one and confirm bean init fails |
| 3-5 | A decision is recorded for the two read endpoints (②.4, ②.8), gated or explicitly not | plan §1.1 + a verify row |
| 3-6 | `POST /v3/userRoleUserFunction` is not writable by a plain `wms_user` | door ① |
| 3-7 | **`PATCH` and `POST`** on `/v3/userRole/{id}/functions` are not writable by a plain `wms_user` | door ① — the **additive** verbs, per §0.2 |
| 3-8 | The full four-step escalation fails at step 1 | an end-to-end deny test, the only AC that proves the *escalation* rather than an endpoint |

---

## 4. Test notes

- **No `@SpringBootTest`** — the v2 IT harness cannot boot (SBDEV-2217). Unit tests + `mvn clean compile`.
- **`standaloneSetup` cannot see a class-level `@RequestMapping` prefix**, so an endpoint test can be green
  while the real mapping 404s. Both controllers carry `/v3/...` prefixes — assert them.
- **Assert `BusinessException.getKey()`, never `getMessage()`** — the 1-arg constructor silently sets
  `key="placeholder"`.
- 🔴 **A reflection test that for-eaches `getDeclaredMethods()` is vacuous when the list is empty.** For
  3-3, key on **name + arity** and mutation-check it: gutting the annotation set must go red.
- **Mutation-check every new assertion** (the floor). For 3-1, remove one annotation and confirm exactly
  that endpoint's pair goes red — not a neighbour's.

**Known baseline: `wms2-api` `develop` has 2 pre-existing failing tests.** `mvn test` **mutates the tracked
`archunit_store`** — revert it. `-Dtest='Outer#method'` silently no-ops for `@Nested` tests.

---

## 5. Risks

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| 3-R1 | Gating two of six endpoints and declaring the escalation closed | **High** | §0.1 is the checklist; AC 3-8 tests the escalation, not the endpoints |
| 3-R2 | Door ① left open while door ② ships, and the ticket is marked done | **High** | Two-phase sequencing is explicit in §2; do not close the ticket after phase 1 |
| 3-R3 | Suppressing only the destructive SDR verbs, leaving `PATCH`/`POST` additive | **High** | §0.2 correction; AC 3-7 names the additive verbs specifically |
| 3-R4 | `exported = false` breaks an unknown client | Medium | grep both UIs **and** any external integration before applying; option 3 avoids it entirely |
| 3-R5 | Rebase collision with SBDEV-3012 / 3005 / 3011 | Medium | §2; go second, the change is one line per method |
| 3-R6 | A future controller is added without a gate | Medium | golden map + `FunctionGuardStartupAssertion` (AC 3-3, 3-4) |

---

## 6. Provenance

Door ① from the SBDEV-3005 review (production lane), recorded in
`SBDEV-3005-role-function-composite-key-swap.md` §12.3 and §14. Door ② moved here 2026-08-21 from
SBDEV-2967's "Scope addition requested 2026-08-19" section during the 2967 split, and **re-enumerated on
`origin/develop` `5506117` — the move corrected the endpoint count from 2 to 6** (§0.1) and corrected the
association-resource verb claim (§0.2).
