---
title: "SDR read gating — a repository-keyed rule source for the 409 ungated Spring Data REST read paths"
ticket: "SBDEV-3169"
ticket_url: "https://app.clickup.com/t/868kyb3rj"
type: "bugfix"
priority: "high"
status: "reviewed (2 lanes, all findings applied) — NOT implementation-ready: the 62-row rule table is not review-complete"
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-08-29"
updated: "2026-08-29"
db_verified: true
db_verification_note: >
  Verified 2026-08-29 against dev_wh01_om1 (tenant wineco / facility wsl) via the wms2-wineco-dev
  MCP. Every row count derived over HTTP in §1.3 reconciled exactly against the tables. The
  verification also CORRECTED §1.4: the HTTP derivation could only see the 55 users who hold a
  group, so it reported "users holding zero functions: 0". The table shows 99 users, of whom 44
  hold no group and therefore zero functions. The denied population for a typical gate is 61, not
  17 — see §1.4.
related:
  - "SBDEV-3157"
  - "SBDEV-3017"
  - "SBDEV-3142"
  - "SBDEV-3155"
  - "SBDEV-3156"
tags:
  - plan
  - authorization
  - spring-data-rest
---

# SDR read gating — a repository-keyed rule source

**Ticket:** [SBDEV-3169](https://app.clickup.com/t/868kyb3rj)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix (authorization gap)
**Priority:** high
**Status:** reviewed — 2 lanes, 18 design findings + 11 factual corrections, all applied. **Not implementation-ready**: the rule table (`SBDEV-3169-evidence/3169-lane-functions.md`, 31 of 62 rows PROPOSED not derived) has not been reviewed
**Date:** 2026-08-29
**Tier:** T3 (authorization · new mechanism · 62 domain types · irreversible if over-gated in the wrong direction)

---

## 0. Affected sites (enumeration before drafting)

The enumeration unit here is not a call site but an **exposed path**. Derived at runtime from
`ResourceMappings` by `SdrSurfaceInventoryContextTest` (shipped in SBDEV-3157), dumped to
`target/sdr-surface-inventory.tsv` — 418 lines, **417 data rows**. Grep and runtime disagree on this codebase, which is
why runtime derivation was made mandatory.

⚠️ **But the runtime inventory is not a complete oracle either — it errs in BOTH directions, and each
was measured on this ticket:**

- **It UNDER-reports**: association paths (`/{repo}/{id}/{property}`) are not enumerated at all —
  §0 row 4, and the authorization-graph traversal lives there.
- **It OVER-reports**: `exported = true` means *SDR would serve this*, not *this path is reachable*.
  An MVC mapping can shadow the SDR route. Measured: the inventory lists
  `User /user COLLECTION exported=true`, but `GET /v3/user` is served by a `UserController` handler
  returning the caller's own JWT — SDR never sees it.

So "exported" is a **candidate list**, not a reachability claim. Every inference of the form
*exported ⇒ reachable* in this plan carries that caveat, and a live probe is what settles it.

| # | Surface | Count | Gated today | In scope |
|---|---|---|---|---|
| 1 | Exported COLLECTION read paths (`GET /v3/{repo}`) | 62 | 0 | **yes** |
| 2 | Exported SEARCH read paths (`GET /v3/{repo}/search/{name}`) | 347 | 0 | **yes** |
| 3 | Item reads (`GET /v3/{repo}/{id}`) | 1 per exported repo | 0 | **yes** — same rule source |
| 4 | Property/association reads (`GET /v3/{repo}/{id}/{property}`) | not in the TSV | 0 | **yes** — see §2.4, the TSV does not enumerate these and it is a real gap |
| 5 | Write verbs on the 11 kept-writable resources | 11 resources | 0 | **yes** |
| 6 | Write verbs on the 47 withdrawn resources | 47 resources | n/a — verbs removed | no — closed by SBDEV-3157 |
| 7 | The SDR root index (`GET /v3`) and profile (`GET /v3/profile`) | 2 | 0 | **yes** — §2.5 |
| 8 | Repositories already fully un-exported | 8 | n/a | no — already closed |

**Row 4 is the one this plan adds to the ticket's own framing.** The ticket says 409 read paths.
That is the count of *collection and search* paths. `RepositoryPropertyReferenceController` serves
`/{repository}/{id}/{property}` and `/{repository}/{id}/{property}/{propertyId}`, which the
inventory test does not enumerate, and which the UI demonstrably uses — `store/admin/group.js:189`
calls `GET /userGroup/{id}/roles` and `store/admin/group.js:203` calls `GET /userRole/{id}/functions`.
**Any rule source that keys only on collection and search paths leaves association reads open**, and
those two are precisely the authorization-graph traversal. A fix that misses them fixes nothing that
matters. See §8-AC-1b.

### 0.1 The 62 exported domain types — bucketed (enumeration lane, landed)

Source: `3169-lane-callers.md`, derived from `origin/develop` of `wms2-web-ui`, `wms2-mobile-ui` and
`oms-laravel-api`.

| bucket | domain types | read paths |
|---|---|---|
| UI-ADMIN | 6 | 27 |
| UI-OPERATIONAL | 19 | 177 |
| MIXED (UI + OMS) | 6 | 40 |
| OMS alone | 0 | 0 |
| **UNCALLED** | **31** | **165** |
| total | 62 | 409 |

**🔴 The headline is at the PATH level, not the type level, and it changes the remedy mix:**

| | search (347) | collection (62) | total (409) |
|---|---|---|---|
| live app caller | 32 | 19 | **51 (12.5%)** |
| cypress-only | 4 | 6 | 10 |
| OMS-doc-only | 2 | 0 | 2 |
| **no reference anywhere** | **309** | **37** | **346 (84.6%)** |

Even inside *called* domain types, almost every individual search is unreferenced: `Replenishorder`
exports **42** read paths and has **one** live caller; `Stockunit` 21 and 2; `Customerorder` 23 and
2; `Unitload` 18 and 1.

**This inverts the plan's centre of gravity.** The mechanism was scoped as if 409 paths needed a rule.
**51 do.** Un-exporting per search (§5 Slice 2) is now the dominant remedy and the rule source covers
a minority of the surface. Slices are re-ordered accordingly.

⚠️ **The exact counts are not independently reproducible.** A second, stricter literal sweep by the
fact-check lane got **34 of 347** searches referenced (this table: 38) and **17 of 62** collections
(this table: 25), the gap being template-literal and no-leading-slash forms it did not match. The
**order of magnitude is corroborated — the overwhelming majority of paths have no caller — but treat
51 as approximate.** No un-export should rest on this table alone; AC-9 requires a second method
per path.

⚠️ **Three further limits on the UNCALLED verdict, all from the lane itself, none removable by more
grepping:**

1. **Only three repos were searched.** Not `omsv2-UI`, not the two v1 UIs, not `v1/oms`, not Postman
   collections, ops scripts, BI/reporting jobs or third-party integrations. "UNCALLED" means
   *uncalled by those three*.
2. **HAL `_links` following reaches paths that appear in no source literal.**
   `oms/app/Services/WmsApiService.php:3363` explicitly falls back to the `_links.self` href SDR
   returns. One instance found; **no static sweep can rule out others.**
3. **Cypress-only paths (10)** may or may not run against a gated environment.

This is why AC-9 requires a second, different confirmation method per un-export, and why Slice 2 is
staged rather than shipped as one sweep.

| Bucket | Remedy | Why |
|---|---|---|
| UNCALLED | `exported = false` **per search** | Cheapest. No mechanism, no runtime cost; the 8 already-un-exported repositories are the precedent |
| UI-ADMIN | gate on the screen's function | Cheapest gate — but see §1.5, one of them is a login-path read |
| UI-OPERATIONAL | gate on an **ANY-of** set, staged | Highest over-gating risk; §4 Fix C, §9-R1 |
| MIXED | gate + explicit OMS carve-out | §2.6 |

---

## 1. Problem Statement

### 1.1 The complaint

From SBDEV-3017, inherited through SBDEV-3157, still unfixed: *"a user denied the SKU Data menu
item still gets the data from `curl /v3/itemdata`."* The menu item is gated. The data is not.

### 1.2 Reproduced live on dev, 2026-08-29

As `sbtest` — a plain `wms_user`, proven non-admin by a `403` on `/v3/user/getDetails` in the same
run, so the account choice is not doing the work:

```
GET /v3/itemdata?size=5000              200   1000 rows   (page cap, not the row count)
GET /v3/client?size=5000                200    156 rows
GET /v3/stockunit?size=5000             200   1000 rows
```

Reproduce with `sbdocs/9-System/scripts/smoke-wms2-user-authz-dev.sh`. Its discriminator, which
every row below depends on: **403 = gated · 405 = verb withdrawn · 404 = reached the repository.**

### 1.3 The finding that reframes the severity — the authorization graph is world-readable

The same `sbtest` token, against the same deployment, on the same day:

```
GET /v3/userFunction?size=5000          200    82 rows    every function that exists
GET /v3/userRole?size=5000              200   145 rows    every role
GET /v3/userGroup?size=5000             200   153 rows    every group
GET /v3/userGroupUser?size=5000         200   127 rows    which user is in which group
GET /v3/userGroupUserRole?size=5000     200   164 rows    which group grants which role
GET /v3/userRoleUserFunction?size=5000  200   335 rows    which role grants which function
```

Plus, found during review and confirmed live — **the item read on `User` itself**:

```
GET /v3/user/1        200   {id, name, locale, clientId, created, modified, entityLock}
GET /v3/user/52610    200   same shape, a different person
GET /v3/user/999999999 404  -> confirms it reaches the repository
```

⚠️ **Arbitrary user records by id, to a plain `wms_user`** — the SBDEV-3071 shape, which un-exported
a *search* and left the item read. `password` is **absent**, so SBDEV-3079's `WRITE_ONLY` is holding
and doing real work here. The **collection** `GET /v3/user` is not SDR at all — a `UserController`
handler shadows it and returns the caller's own JWT (§0). So `User` needs the item read gated and
must be in Slice 1; the first draft omitted it because its collection looked harmless.

**626 join rows plus 380 entity rows: the complete access-control model, readable by any
authenticated user.** `sbtest` is explicitly denied `WEB_UI_VIEW_USER_MANAGEMENT`,
`WEB_UI_VIEW_ROLE`, `WEB_UI_VIEW_GROUP` and `WEB_UI_VIEW_FUNCTION` — every screen that renders this
data is closed to it — and the data underneath is served anyway.

This is not "SKU data leaks." It is *the map of who can do what*, which is the reconnaissance step
for every privilege-escalation path this programme has been closing since SBDEV-3005. It should
change how this ticket is prioritised relative to its siblings.

**It also happens to be the single cheapest thing to fix**, because every caller of those six paths
is an admin screen — see §1.5.

### 1.4 The user population — measured in the DB, because role names lie and HTTP undercounted

Verified against `dev_wh01_om1` on 2026-08-29 (MCP `wms2-wineco-dev`). The graph is
`mywms_group_mywms_user` → `mywms_group_mywms_role` → `mywms_role_mywms_function`.

⚠️ **§5.1-P1's query does NOT produce this table** — it returns per-function holder counts (the 38)
and nothing else. The banding below needs a second query, and it must start
`FROM mywms_user LEFT JOIN …`, because starting from the join table is what dropped the 44 the first
time:

```sql
WITH uf AS (SELECT gu.userlist_id uid, rf.functionlist_id fid
            FROM mywms_group_mywms_user gu
            JOIN mywms_group_mywms_role gr ON gr.grouplist_id = gu.grouplist_id
            JOIN mywms_role_mywms_function rf ON rf.rolelist_id = gr.rolelist_id GROUP BY 1,2)
SELECT CASE WHEN n=0 THEN '0' WHEN n<40 THEN '1-39' WHEN n<78 THEN '40-77' ELSE '78-82' END band,
       count(*)
FROM (SELECT u.id, count(uf.fid) n FROM mywms_user u LEFT JOIN uf ON uf.uid=u.id GROUP BY u.id) t
GROUP BY 1 ORDER BY 1;
```

⚠️ **This section was corrected by the DB check.** The first pass derived the graph over HTTP, which
can only see users who appear in a join row — i.e. the 55 who hold a group — and so reported
"users holding zero functions: 0". That is true of the 55 and badly wrong of the estate. **The
denominator is 99.**

| | |
|---|---|
| Users total (`mywms_user`) | **99** |
| Users holding **zero** functions (no group at all) | **44** |
| Users holding 1–39 functions | 12 |
| Users holding 40–77 | 5 |
| Users holding 78–82 — **de-facto admins** | **38** |
| Users holding all 82 | **0** |
| Functions defined | 82 |
| Functions held by nobody | 1 (`MOBILE_UI_VIEW_LPN_ASSOCIATION`) |
| Population of a typical screen function (`WEB_UI_VIEW_FUNCTION`, `_GROUP`, `_CLIENT`, …) | **38** |
| ⇒ **Population a typical gate DENIES** | **61 of 99** |

Row counts reconciled exactly between HTTP and SQL — 82 functions, 145 roles, 153 groups, and
127 / 164 / 335 join rows — so the §1.3 measurement stands; only its denominator was wrong.

**One** independent corroboration: `smoke-wms2-user-authz-dev.sh`'s header says *"`sbtest` holds 35
functions … `panderson` holds all 80"*, and the query returns **35** and **80**.

⚠️ The first draft claimed *two*, offering SBDEV-3063's "61 of 99" as a second. **It is not
independent** — that plan records *"61 of 99 users on `wms2-wineco-dev` hold no user-management
function"*, i.e. the same DB, same function, same join, measured earlier. It is a consistency check
that the number has not drifted, which is worth something, but it is the same measurement and the
first draft also misquoted it as being about login failure.

`mywms_user_mywms_role` (direct user→role) holds **0 rows**, confirming that only the
group→role→function chain confers anything in v2.

**Three consequences, and they shape the whole plan:**

1. **A typical gate denies 61 of 99 users — and 44 of them hold zero functions today.** Those 44 are
   the sharpest statement of the exposure available: users with *no* granted capability whatsoever
   can currently read the entire authorization graph and all business data over SDR. It also means
   the blast radius of gating is far larger than the first pass suggested, so §9-R1 is a higher risk
   than it looked and Slice 4 is not a formality. **Note the two populations are different groups and
   must not be conflated**: 61 users are *denied* by a typical gate, but only the **17 partial
   holders** (12 with 1–39 functions + 5 with 40–77) are at risk of *over*-gating — the 44
   zero-function users cannot open a gated screen today either way.
2. **"Nothing broke" is nearly worthless as evidence here.** 38 of 99 users bypass every function
   gate by holding essentially all of them. A smoke test as an admin — or as any of those 38 — is
   vacuous by construction. This is the trap `smoke-wms2-user-authz-dev.sh` exists to prevent, one
   level up.
3. **Over-gating surfaces as an empty screen, not an error.** No test in the suite fails. §9-R2.

This is the third time on this programme that counting by role name would have given the wrong
answer; the unit is users. A single role constant reached 38 users on SBDEV-3017 and two of three
role-name verdicts were wrong, in opposite directions. **This time counting by the wrong
*denominator* was also wrong, by a factor of three and a half.**

### 1.5 Why the authorization-graph half is nearly free

Every caller of the six paths in §1.3 lives in `store/admin/*` on `wms2-web-ui@origin/develop`:

| Path | Caller |
|---|---|
| `GET /userFunction` | `store/admin/function.js:27`, `store/admin/management.js:141` |
| `GET /userFunction/search/findByKeyword` | `store/admin/management.js:158` |
| `GET /userRole/search/findByConnectorFalse` | `store/admin/role.js:51`, `:62` |
| `GET /userRole/{id}/functions` | `store/admin/group.js:203` |
| `GET /userGroup/search/findByConnectorFalse` | `store/admin/group.js:110` |
| `GET /userGroup/{id}/roles` | `store/admin/group.js:189` |
| `GET /userGroupUser/search/findByGrouplistId` | `store/admin/group.js:190` |

Those seven are reached from admin screens, which are already function-gated in the UI. Two of them
are `/{id}/{property}` association reads — §0 row 4 again.

⚠️ **This table is not the complete caller set, and the first draft asserted it was** ("every caller
… behaviour-preserving for every legitimate caller"), which §1.5.1 contradicts three lines later.
Also missing and harmless, both admin: `store/admin/role.js:77` (`GET /userRole` + query string) and
`store/admin/group.js:122` (`GET /userGroup` + query string). Treat the table as the *evidence found*,
not an enumeration.

### 🔴 1.5.1 — but ONE `UserGroup` search is on the login path, and gating it breaks every non-admin login

**This correction came from an independent enumeration lane and invalidates the first draft of Slice
1, which listed `UserGroup` for gating with no carve-out.** Verified directly at `origin/develop`:

- `wms2-web-ui/pages/index.vue:148` — `redirectPage` awaits
  `this.$store.dispatch('getAffiliatedGroupsByUsername', username)` immediately after
  `ensureFunctionsLoaded`. **This runs on every login, for every user.**
- `wms2-web-ui/store/index.js:249` — that action issues
  `GET /userGroup/search/findByUsername?username=…` — **an SDR search**.
- `store/index.js:259` — the catch (opening `:257`) calls `this.$toast.error('Error: Request failed due to a network
  or server issue. Please retry.')`.

So a gate on `UserGroup` would 403 this read for all 61 denied users, and the failure is **not**
silent: it is a visible error toast on **every login**, plus an empty `affiliatedGroups`. Login would
not hard-fail — `pages/index.vue:146-149` also try/catches — but the product would tell 61 of 99 users
that something is broken, every time they sign in.

This is precisely the shape `@PublicHandler` exists for on `UserController.isWmsUser` /
`getAllRoles` (SBDEV-3063): **a bootstrap read a user holding zero functions must still be able to
make.** SDR has no `@PublicHandler` equivalent, so the rule source must grow one — §4 Fix F. Slice 1
does not ship without it.



---

## 2. Root Cause Analysis

### 2.1 The enforcement point exists and fires; the rule source does not exist

⚠️ **"SDR is structurally ungatable" is FALSE** and was corrected in six `src/main` javadocs during
SBDEV-3017. Do not re-derive it. `FunctionGuardInterceptor` is registered as a
`@Bean MappedInterceptor` (PR #187, `5b704e54`), and every `AbstractHandlerMapping` created in the
context collects those via `detectMappedInterceptors` — **including SDR's**. Only
`WebMvcConfigurer#addInterceptors` fails to reach SDR, and that is what the guard *used* to use.

`FunctionGuardInterceptor.java:166`:

```java
Class<?> declaring = handlerMethod.getMethod().getDeclaringClass();
```

For any SDR request that resolves to `RepositoryEntityController`, `RepositorySearchController` or
`RepositoryPropertyReferenceController` — framework classes, no `@RequiresFunction`, and absent from
`GUARDED` (`:213`) — the request falls through **allowed** (`:213–219`).

**So the defect is not "the guard cannot see SDR." It is that the guard asks the wrong question.**
It asks *"what does the declaring class require?"*, and for SDR the declaring class is a framework
type shared by all 62 resources. The question it must ask instead is *"what does the exported
repository behind this path require?"*

### 2.2 Why withdrawal — the SBDEV-3157 remedy — cannot be reused here

SBDEV-3157 withdrew write verbs from 47 of 58 resources and needed no rule source at all, because
**nothing wrote to them**. That property does not transfer. Reads have callers by definition: 62
domain types exist because something reads them. There is no large "nothing reads this" set to
withdraw, so the mechanism SBDEV-3157 proved unnecessary for 47 of 58 write surfaces is now
unavoidable for reads.

The UNCALLED bucket (§0.1) is the residue where un-exporting still works. Its size is the single
most useful number the enumeration lane produces, because it is subtracted from the surface that
needs the mechanism.

### 2.3 The path → domain type resolution is available and unambiguous

SDR's own controllers declare a `{repository}` URI template variable — verified against
`spring-data-rest-webmvc-4.5.7.jar`:

| Controller | Mappings |
|---|---|
| `RepositoryEntityController` | `/{repository}`, `/{repository}/{id}` |
| `RepositorySearchController` | `/{repository}/search`, `/{repository}/search/{search}` |
| `RepositoryPropertyReferenceController` | `/{repository}/{id}/{property}`, `/{repository}/{id}/{property}/{propertyId}` |
| `RepositoryController` | `/` and `""` — the root index. **The ONLY variable-less route** |
| `RepositorySchemaController` | **`/profile/{repository}`** — carries the variable |
| `ProfileController` | `/profile` — the bare profile root |
| `alps.AlpsController` | `/profile/{repository}` — **a SUB-package**, `org.springframework.data.rest.webmvc.alps` |

⚠️ **Corrected after review.** The first draft said `/profile` carried no variable. It does:
`RepositorySchemaController` maps `/profile/{repository}`, so `GET /v3/profile/{repository}` resolves
a domain type and lands in the **rule-evaluation** branch, not the deny-by-no-domain-type branch. The
bare `/profile` belongs to `ProfileController`, which the first draft omitted, and `alps.AlpsController`
serves the same shape from a **sub-package**. **Only `GET /v3` is genuinely variable-less.** Fix D row
3 is corrected accordingly, and the profile/ALPS routes need their own decision (§10-Q2) — they
describe the schema of a resource, so leaking them leaks the shape of data the gate is refusing.

So `preHandle` can read `HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE`, take `repository`, and
resolve it to `ResourceMetadata` (hence a domain type) via the `ResourceMappings` bean. **No path
parsing, no string splitting, no base-URI assumptions** — the value comes from the same mapping that
dispatched the request. This matters because a hand-rolled path parser is exactly the kind of
second, divergent source of truth that produced this bug in the first place.

### 2.4 Association reads are a separate route and the inventory does not list them

`RepositoryPropertyReferenceController` is a distinct declaring class from
`RepositoryEntityController`, and `SdrSurfaceInventoryContextTest` enumerates `COLLECTION` and
`SEARCH` kinds only. **A rule table built from the TSV alone will silently leave
`/{repository}/{id}/{property}` open.** Two of the seven authorization-graph reads in §1.5 use
exactly that shape. The remedy is not to extend the TSV first — it is to key the rule on the
**domain type**, which all three controllers resolve to identically, so association reads are
covered by construction rather than by remembering to enumerate them.

### 2.5 The root index advertises the entire surface

`GET /v3` (`RepositoryController`) returns a `_links` document naming every exported repository, and
`GET /v3/profile` describes them. Neither carries a `{repository}` variable, so neither can be
resolved to a domain type. **They must be decided explicitly, not left to fall out of the
implementation** — a "no domain type resolved ⇒ allow" default silently keeps the index open, which
hands an attacker the map even after every resource is gated. §5 Slice 0 fails closed instead.

### 2.6 OMS reads over SDR and must not be broken

`oms-laravel-api@origin/develop`, `config/wms.php` — **`:103`–`:118` and `:156`**. ⚠️ The first draft
cited `:85-100`, which is a **comment block**: the exact error class this section spends a paragraph
warning about, committed inside the warning.

**Seven paths, not six**, and per §10-Q1 the remedy is to **grant `oms_integration` the covering
functions**, not to exempt these paths. The seventh is the one that matters most:

| path | config | caller |
|---|---|---|
| `v3/client/search/findByClNr` | `:103` | `WmsApiService.php:3334` — **a SEARCH**, resolving the WMS client id before every `PATCH v3/client/{id}` |
| `v3/client` · `v3/itemdata` · `v3/shipperid` · `v3/boxtype` | `:112`–`:115` | |
| `v3/itemdata/search/findByClientId` | `:118` | |
| `v3/printer/search/findByType` | `:156` | optional; defaults to the **non-SDR** `rest/printer/findByType` |

🔴 **`Client.findByClNr` is a search — exactly the unit Slice 2 proposes to un-export.** Un-exporting
or gating it silently breaks OMS client sync. It must be named in the OMS carve-out and excluded from
Slice 2 by name, not by bucket.

⚠️ **Derive this from `origin/develop`, never a local checkout.** On SBDEV-3017 I rejected a correct
review finding using a checkout that was **838 commits behind**; every row of my rejection table was
true of the stale tree and false of reality. The tell was a line-number offset. OMS also *writes*
one SDR path — `PATCH v3/client/{id}`, `WmsApiService.php:3281` — which is why `Client` is among the
11 kept writable.

**How OMS authenticates decides the whole carve-out design, and it is an open question — §10-Q1.**
If OMS presents a JWT for a WMS user, it can hold functions and needs no carve-out. If it uses a
service principal outside the function model, the gate must exempt it explicitly, and *that exemption
becomes the new bypass* unless it is scoped to those six paths.

---

### 2.7 🔴 Gating SDR while the MVC twin stays open closes nothing — and that is the majority case

From `3169-lane-functions.md`. Controllers that serve an SDR-exported entity and carry **zero**
`@RequiresFunction` on any handler:

| controller | handlers | gates |
|---|---|---|
| `TransfersController` (serves `Customerorder`) | 17 | 0 |
| `ClubLineController` (serves `CustomerorderBatch`) | 14 | 0 |
| `ItemDataController` | 8 | 0 |
| `MessageController` | 4 | 0 |
| `StockRecordController` | 3 | 0 |
| `UnitloadRecordController` | 2 | 0 |
| `PickingOrderPositionController` | 2 | 0 |
| `CustomerOrderPositionController` | 2 | 0 |
| `SystemController` | 3 | 0 |
| `ReportController` | 15 | **1** — only `reprintLabels:314`; all 14 `export*` / `*View` handlers ungated |

**`ReportController` is the sharpest case**: `StockView`, `LockOverview*`,
`ViewWarehouseLocationReport`, `InventoryRecord`, `FlowbinMonitorView`, `OrderDetailMonitorView`,
`Stockrecord` would all be gated over SDR while `POST /v3/report/export*` returns the same rows to
any `wms_user`.

**And the founding complaint's own controller is ungated.** `ItemDataController.java:98-100` records
that removing a `@RequiresFunction` there "fell through ALLOWED and survived all 5673 tests" because
the class is not in `GUARDED`. So **gating SDR `itemdata` does not close §1.1** while
`/v3/itemData/detailView` serves the same rows unguarded.

⚠️ **This is the "a guard fences the mechanism you aimed at" failure, and this plan is at risk of
committing it.** SDR is *one* producer of these rows; MVC is another. Enumerate every producer
before claiming a resource is closed. The MVC read axis is **SBDEV-3142** — this ticket cannot claim
to close the founding complaint on its own, and §8 is amended accordingly (AC-10).

**Consequence for sequencing, not a reason to stop.** Slice 1 (the authorization graph) is
unaffected: those six resources have no *ungated* MVC twin — `UserController`, `UserGroupController` and
`UserRoleController` are all in `GUARDED`. (The first draft said the join tables have "no controller
at all"; that is wrong — `saveGroupRoles`, `saveRoleFunctions` and the two `*DetailsById` endpoints
exist and are called from `store/admin/*`. They are gated, so the operative claim survives.) The exposure Slice 1 closes is real and complete. It is
Slice 3, the operational tranches, whose value is contingent on SBDEV-3142 landing alongside.

---

## 3. Architecture Overview

```
   HTTP  GET /v3/userRoleUserFunction?size=5000
     │
     ▼
   SecurityFilterChain            ← @ConditionalOnProperty(rest.security.enabled)
     │                              INVISIBLE to every Spring-context test (profile sets it false).
     │                              Source-level assertion is the only instrument. §9-R5
     ▼
   RepositoryRestHandlerMapping
     │  detectMappedInterceptors() collects FunctionGuardInterceptor  ← SBDEV-3017 slice A
     ▼
   FunctionGuardInterceptor.preHandle          :159
     │
     ├── @PublicHandler?                       :168   resolves FIRST
     ├── declaring = getMethod().getDeclaringClass()   :166
     │      → RepositorySearchController  (framework class)
     ├── @RequiresFunction on method? → none
     ├── @RequiresFunction on class?  → none
     └── GUARDED.contains(declaring)? → NO     :213
            │
            └──────────────►  ALLOWED  ◄── THE DEFECT
                             ▼
                       RepositorySearchController
                             ▼
                       335 join rows to an unprivileged caller


   AFTER (this plan):

   ├── declaring in org.springframework.data.rest.webmvc?   ← by PACKAGE, not a class list
   │      YES → resolve {repository} URI variable → ResourceMappings → domain type
   │              │
   │              ├── domain type resolved  → SdrFunctionRules.requiredFunctions(type)
   │              │        ├── rule found      → accessService.checkAnyAccess(user, functions)
   │              │        └── no rule         → DENY   (fail closed; §5 Slice 0)
   │              └── not resolved (root index, profile) → DENY   (§2.5)
   └── NO → existing behaviour, unchanged
```

### Key files

| File | Lines | Role |
|---|---|---|
| `security/FunctionGuardInterceptor.java` | 294 total; `:159` `preHandle`, `:166` declaring-class resolution, `:213` the fall-through | The enforcement point. One new branch |
| `RestConfiguration.java` | `:324` `SDR_WRITE_WITHDRAWN`, `:376` `configureUnwrittenResourceWriteExposure` | Where `exported=false` / exposure decisions live; where the UNCALLED bucket is closed |
| `security/SdrFunctionRules.java` | **new** | The rule source, keyed on domain type |
| `security/SdrFunctionRulesStartupAssertion.java` | **new** | Fail-fast: every rule resolves to a live `ResourceMetadata` |
| `security/FunctionGuardStartupAssertion.java` | existing | Precedent for the startup-assertion shape |
| `WmsConstants.FunctionEnum` | — | The 82 function constants |
| `service/AccessService` | `:19` class, `:134` method | `public AccessDecision checkAnyAccess(String username, String... functions)` — used at `FunctionGuardInterceptor:224`. ⚠️ It is in `net.aim_ai.wms.**service**`, not `security` |
| `test/.../SdrSurfaceInventoryContextTest.java` | shipped SBDEV-3157 | Runtime surface derivation; extend for association paths (§0 row 4) |
| `sbdocs/9-System/scripts/smoke-wms2-user-authz-dev.sh` | — | The live probe; AC-8 |

---

## 4. Fix Design

### Fix A — detect SDR by PACKAGE, not by a class list

```java
private static final String SDR_CONTROLLER_PACKAGE = "org.springframework.data.rest.webmvc";

private static boolean isSpringDataRestHandler(Class<?> declaring) {
    Package pkg = declaring.getPackage();
    return pkg != null && pkg.getName().startsWith(SDR_CONTROLLER_PACKAGE);
}
```

**Why not an explicit class list.** ⚠️ **The first draft justified this by asserting "there are
exactly six `Repository*Controller` classes" — which was itself a closed-set claim, in the very fix
whose stated rationale is "do not assert closed sets", and it was wrong in both directions.** Review
found **seven** types carrying `@RepositoryRestController` / `@BasePathAwareController` — the four
mapped above plus `RepositorySchemaController`, `ProfileController` and **`alps.AlpsController`,
which lives in a SUB-package** — while one of the six things matching `Repository*Controller.class`
in the jar (`RepositoryRestController`) is an **annotation, not a controller**.

The package check is the right call, and the corrected reasoning is stronger than the original: a
`startsWith` on the package **catches the `.alps` sub-package and any type a future Spring version
adds**, which no hand-maintained list can. A list's failure mode is *open* — the worst direction.

⚠️ **A custom `@RepositoryRestController` in our own code lives in OUR package, not SDR's**, so it is
untouched by this branch and keeps whatever gate it already has. Verify none exist that would expect
otherwise — §10-Q3.

### Fix B — resolve the domain type from the dispatch, not from the path string

```java
@SuppressWarnings("unchecked")
Map<String, String> vars = (Map<String, String>) request.getAttribute(
        HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE);
String repositoryPath = vars == null ? null : vars.get("repository");
```

then `repositoryPath` → `ResourceMetadata` → `getDomainType()`. Never split the URI.

⚠️ **The attribute IS populated by the time `preHandle` runs, but by a non-obvious route — document
it, because Fix D's fail-closed default turns a null lookup into deny-everything if it ever changes.**
`BasePathAwareHandlerMapping.lookupHandlerMethod` (`:71`, `:93`) passes a
`CustomAcceptHeaderHttpServletRequest` **wrapper** (`:188`) into `super.lookupHandlerMethod`, so
`RequestMappingInfoHandlerMapping.handleMatch` sets the attribute on the *wrapper*;
`HttpServletRequestWrapper.setAttribute` delegates to the wrapped request, which is why the
interceptor's request object sees it. Pin this with a test rather than trusting it. The mapping
that dispatched the request already decoded the variable, including URL-encoding and the configured
base URI `/v3`, and a second parser is a second source of truth.

### Fix C — the rule source, keyed on domain type

```java
@Component
public class SdrFunctionRules {
    // domain type -> any-of. String, NOT an enum type: WmsConstants.FunctionEnum is a
    // `public static final class` holding 82 String constants with a private ctor — it is a
    // namespace, not a Java enum. @RequiresFunction.value() is String[] and
    // AccessService.checkAnyAccess(String username, String... functions) takes String....
    private final Map<Class<?>, Set<String>> rules;
    public Optional<Set<String>> requiredFunctions(Class<?> domainType) { ... }
}
```

⚠️ The first draft wrote `Set<FunctionEnum>`, which **does not compile**.

Keyed on `Class<?>`, not on a path string, so **a repository rename or a `path=` change is a compile
error or a startup failure rather than a silent un-gating.** A path-keyed map loses exactly that
property, and losing it is how a gate rots into a label.

Semantics: **any-of**, matching `accessService.checkAnyAccess` at `:224`. A read is allowed if the
caller holds *any* function in the set — a resource reachable from two screens is readable by users
of either.

**Per-search OVERRIDES, keyed `(Class<?>, exportedSearchPath)`.** The type-keyed map is the default;
an override narrows one search. Without them, a broad any-of union is near-vacuous in the permissive
direction for the widest-read types — `Client` has 13 read paths and 22 caller files spanning Cycle
Count, Shippers, Reports, Receiving and mobile Picking, so a single union makes *all 13* readable by
anyone holding *any* member. **A type rule without overrides is a ceiling, not a fit**, and §8 says so
rather than letting the ACs imply the whole surface is covered.

🔴 **An any-of SET, never a single function — and the codebase already proves it.** The enumeration
lane found **14 of the 62** types read by screens with *different* gates: `Client` (22 caller files),
`Location` (23), `Printer` (17), `Itemdata` (16), `Unitload` (8), `Section` (7), `Customerorder` (6),
`Boxtype` (3), plus `Advice`, `Stockunit`, `CyclecountPosition`, `ReceivingDtoView`,
`CustomerorderPosition`, `Shipperid`. The in-repo precedent is explicit:
`UnitLoadController.java:64-67` gates `reprintLabel` on an any-of **four** — with a 7-line comment
at `:57-63` —
`{STOCK_UNIT, CONTAINER, CLUB_LINE, TRANSFER_ORDER}` — with a four-line comment explaining that
narrowing it 403s half the screen. **A `domainType → one function` map will 403 working screens.**

### Fix D — the mode ladder, and the decision table that is a function of it

⚠️ **Corrected after review.** The first draft declared *"no rule ⇒ deny is the whole design"* and
separately gave Slice 0 an empty rule map behind a single boolean. Those cannot both be true: with
fail-closed semantics and 7 rules present, flipping one boolean **403s the other 55 domain types —
the entire UI.** That was the one defect in this plan capable of producing an outage rather than a
regression, and it sat in the sentence an implementer would treat as authoritative.

There are two independent questions — *do we enforce where we have a rule?* and *what do we do where
we have none?* — so there is one **four-valued mode**, not a boolean:

| mode | ships in | SDR handler, rule present | SDR handler, no rule |
|---|---|---|---|
| `OFF` | Slice 0 | allow | allow |
| `SHADOW` | before each tranche | evaluate, emit `would_deny`, **allow** | allow |
| `ENFORCE_RULED` | Slices 1–3 | evaluate | **allow** |
| `FAIL_CLOSED` | Slice 4 | evaluate | **deny** |

Full decision table, in evaluation order. **The order is load-bearing** — see the invariant below:

| # | Case | Decision |
|---|---|---|
| 1 | handler is not a `HandlerMethod` (static resource, CORS preflight, actuator) | **allow — unchanged**, `preHandle:159` already early-returns |
| 2 | declaring class outside `org.springframework.data.rest.webmvc` | unchanged — existing behaviour |
| 3 | SDR handler, **root index `GET /v3`** — the only variable-less route (§2.3) | **deny**, independent of mode (§2.5) |
| 3b | SDR handler, `/v3/profile/{repository}` or its ALPS form — these DO resolve a domain type | falls to rows 4/5. A schema description leaks the shape of data the gate refuses; decide in §10-Q2 |
| 4 | SDR handler, domain type resolved, rule present | per mode |
| 5 | SDR handler, domain type resolved, no rule | per mode |
| 6 | SDR handler, `{repository}` present but unresolvable to a `ResourceMetadata` | **deny** |

⚠️ **INVARIANT: the URI-template attribute is read only AFTER the declaring-class package check
passes (row 2).** `RequestMappingInfoHandlerMapping.handleMatch` sets
`URI_TEMPLATE_VARIABLES_ATTRIBUTE` before any interceptor runs, and **request attributes survive
ERROR and ASYNC re-dispatch**. An implementation that reads the attribute first — which row 3
invites, since `/v3` has no `{repository}` — will deny a CORS preflight, an error dispatch of a
failed SDR request, and anything inheriting a stale attribute. It is a fail-*closed* bug, so **no
denial test would catch it**; it surfaces as the UI not loading from a second origin, or a 403 body
replacing a 500.

Note `BasePathAwareHandlerMapping.hasCorsConfigurationSource()` returns `true` unconditionally, so
*every* SDR request goes down the preflight branch. Preflights are safe only because
`AbstractHandlerMapping` swaps in a `PreFlightHttpRequestHandler` at interceptor index 0, which
short-circuits before the guard — i.e. safe by row 1, not by anything this plan does. Pin it anyway.

### Fix E — startup assertion

A `SmartInitializingSingleton` that fails the boot when a rule's domain type is not exported by
`ResourceMappings`, and — the direction that actually protects — when an **exported** domain type has
**no rule** while the guard is enabled. The first catches a stale rule; the second catches a new
repository added without one, which is the same class of drift as the ArchUnit gate-inventory pins
and has bitten this programme before.

**It must validate the override and exemption keys too, not just the rule keys.** Those are keyed on a
raw search-path string, which is exactly the property Fix C avoids for rules — a renamed search
silently stops matching, and the failure is *open*. The assertion resolves every override and every
exemption against a live `SearchResourceMappings` entry and fails the boot if one does not exist.

Follow `FunctionGuardStartupAssertion`'s existing shape.

### Fix F′ — a self-scoped `@PublicHandler` endpoint, NOT an SDR carve-out

⚠️ **This replaces the first draft's `BOOTSTRAP_READS` carve-out, which was unsafe.** That design
exempted `GET /userGroup/search/findByUsername` for any authenticated caller **with no binding
between the `username` parameter and the principal**. The login bootstrap needs *"my groups"*; the
carve-out would have granted *"anyone's groups, one username at a time"* — the exact
arbitrary-username shape SBDEV-3071 exists to close. It copied SBDEV-3063's *exposure* rather than
its *remedy*: `getAllRoles` is `@PublicHandler` and **derives** its answer for the caller, whereas
SDR has no way to bind a query parameter to the principal.

Instead:

1. Add `getAffiliatedGroups()` to `UserController` — **no username parameter at all** — resolving the
   caller via `SecurityContextUtils.getUserName()`, the pattern already used at `UserController:160`
   and `:253`, with the same `ANONYMOUS` guard (`SecurityContextUtils.ANONYMOUS`, principal string
   `"anonymousUser"`). Mark it `@PublicHandler`; it becomes the third, alongside `isWmsUser` and
   `getAllRoles`. `UserController` is in `GUARDED`, so the marker is the deliberate, tripwired way to
   open it.
2. Point `wms2-web-ui/store/index.js:249` at it.
3. Gate SDR `UserGroup` with **no exemption**.

**`BOOTSTRAP_READS` therefore starts — and should stay — empty.** An empty exemption set is a far
stronger invariant than "pinned and non-growing", because pinning the *contents* of a carve-out list
says nothing about whether an entry is *safe*, and the entry this replaces was not.

Deploy order is API-first and the change is additive: the new endpoint ships before the UI points at
it, so no window exists where the UI calls something absent.

⚠️ Do **not** use `@AuthenticationPrincipal` — it is null in this deployment. `SecurityContextUtils.getUserName()` is the working accessor.

### Alternatives ruled out

| Alternative | Why not |
|---|---|
| `@RestResource(exported = false)` on everything | Breaks every UI screen that reads over SDR. SBDEV-3017 §9.1 already rejected this and shipped write-withdrawal instead, for this reason |
| A `SecurityFilterChain` matcher per path | `SecurityConfiguration` is `@ConditionalOnProperty` and invisible to every context test here (§9-R5). Untestable in CI |
| Path-keyed rule map | Loses "a rename is a compile error" (Fix C) |
| Annotate our repositories with `@RequiresFunction` | The interceptor resolves on the *declaring class* of the handler, which is a framework type. A repository annotation is never consulted — this is precisely the bug |
| Gate in a `RepositoryRestConfigurer` | Configures exposure, not per-caller authorization. It cannot see the principal |

---

## 5. Implementation Steps

Five slices. **Each is separately shippable and separately revertible**, and they are ordered by
descending value-to-risk — deliberately, because the highest-value slice is also the safest and
should not wait behind the riskiest.

### 5.1 Prerequisites

| # | Prerequisite | Detail |
|---|---|---|
| **P1** | **Re-run the population analysis per tenant** | The 99/44/38/61 split in §1.4 is *dev only*. Re-run per tenant on UAT and prod before Slice 4. Verified query (table and column names confirmed against `information_schema` on `dev_wh01_om1`, 2026-08-29): <br>`WITH uf AS (SELECT gu.userlist_id AS uid, rf.functionlist_id AS fid FROM mywms_group_mywms_user gu JOIN mywms_group_mywms_role gr ON gr.grouplist_id = gu.grouplist_id JOIN mywms_role_mywms_function rf ON rf.rolelist_id = gr.rolelist_id GROUP BY 1,2) SELECT f.function, count(DISTINCT uf.uid) AS users_holding FROM mywms_function f LEFT JOIN uf ON uf.fid = f.id GROUP BY f.function ORDER BY users_holding;` <br>⚠️ **`LEFT JOIN` from `mywms_user`, not from the join table** — counting off `mywms_group_mywms_user` silently drops the 44 users who hold no group, which is exactly the error the HTTP pass made. |
| **P2** | **DB access** | dev (`localhost:25060` → `dev_wh01_om1`) verified working 2026-08-29 and used for §1.4. UAT (`25062`) and prd (`25061`) still to be run for P1 |
| **P3** | **Settle the OMS principal** | §10-Q1. Blocks Slice 3 only; Slices 0–2 do not touch an OMS-read resource |
| **P4** | **Extend the surface inventory to association paths** | §0 row 4 / §2.4. Needed before any completeness claim, and before AC-1b can be evaluated |
| **P5** | Flyway | **None.** No schema change in any slice |
| **P6** | Sysprop / feature flag | **Exactly one**, the four-valued mode of Fix D — introduced in Slice 0, advanced per slice, **removed** in Slice 4. Not a boolean, and not one per type |
| **P7** | Deploy order | API-only through Slice 3. Slice 4 needs the per-tenant check from P1 first |
| **P8** | Monitoring | `wms2.authz.denied` already exists (`FunctionGuardInterceptor:100`). Slice 0 must tag it by domain type, or a rollout regression is invisible — §9-R2 |

### Slice 0 — the mechanism, wired but inert, plus the detector

`SdrFunctionRules` with an **empty** rule map and the guard branch at mode `OFF` (Fix D). Fixes A, B,
C, D, E land; nothing changes behaviour. Ships three things the later slices need *before* they need
them:

- the startup assertion (Fix E),
- `wms2.authz.denied` tagged by domain type (P8),
- **`SHADOW` mode and its `wms2.authz.sdr.would_deny{domainType, function}` counter** — one extra
  branch, and the only over-gating detector that works (§9-R1).

### Slice 1 — the authorization graph (highest value, lowest risk)

Rules for `UserFunction`, `UserRole`, `UserGroup`, `UserGroupUser`, `UserGroupUserRole`,
`UserRoleUserFunction`, `UserUserRole` and **`User`** (its item read — §1.3) — gated on `WEB_UI_VIEW_USER_MANAGEMENT`,
`WEB_UI_VIEW_ROLE`, `WEB_UI_VIEW_GROUP`, `WEB_UI_VIEW_FUNCTION` as the enumeration lane assigns
them. Flag on for these types only.

Mode `ENFORCE_RULED`, preceded by a `SHADOW` deploy cycle.

Behaviour-preserving by §1.5 — every *other* caller is an already-gated admin screen — **but only
once Fix F′'s self-scoped `getAffiliatedGroups()` endpoint ships and the UI points at it.** Without
that, gating `UserGroup` puts a visible error toast on every non-admin login (§1.5.1). It is a hard
prerequisite of this slice, not a follow-up, and it makes Slice 1 a two-repo change: **API first**
(the endpoint is additive), then web-ui, then the rule.

**This is the slice that closes §1.3, and it should not wait for the other 55 domain types.** Its
value is also not contingent on SBDEV-3142: these six resources have no ungated MVC twin (§2.7).

Includes association reads — `/userGroup/{id}/roles`, `/userRole/{id}/functions` — which is where
Fix B's domain-type keying earns its place (§2.4).

### Slice 2 — the UNCALLED bucket (**the largest single reduction in surface**)

31 domain types, 165 read paths with no caller in the three repos searched — and at path level,
**346 of 409 read paths (84.6%) are unreferenced anywhere** (§0.1). This slice removes more exposure
than every gate in this plan combined, at lower risk, because an un-exported path cannot be
over-gated — it either has no caller or the un-export is reverted.

Do this **before** Slice 3, not after: every path removed here is a path Slice 3 does not need a
rule, a test or a probe row for.

`exported = false` **per search**, never per repository, for everything the enumeration lane
confirms has no caller. No mechanism, no runtime cost. Each un-export cites the lane's evidence row.

**DONE — and it was ten paths, not one.** ⚠️ The lane found `losSequencenumber`; writing the fix as a
**general invariant** rather than a path pin found **ten exported searches carrying
`@Lock(PESSIMISTIC_WRITE)`, across nine repositories** — on the hottest entities in the product:

```
/v3/customerorder/search/findByIdForUpdate          /v3/pickingorder/search/findByIdForUpdate
/v3/customerorderBatch/search/findByIdForUpdate     /v3/pickingorder/search/findAllByIdForUpdate
/v3/unitload/search/findByIdForUpdate               /v3/replenishorder/search/findByIdForUpdate
/v3/unitload/search/findByLabelidForUpdate          /v3/stockunit/search/findByIdForUpdate
/v3/adviceposition/search/findByIdForUpdate         /v3/losSequencenumber/search/findByClassnameForUpdate
```

**This is the §2.7 lesson applied in advance and paying off immediately**: enumerate every producer of
the outcome, do not fence the one instance you were handed. A path pin on `losSequencenumber` would
have shipped, looked complete, and left nine.

**Severity — availability, stated precisely rather than dramatically.** An SDR `GET` runs in a
transaction that commits at request end, so the lock is held for the request, not indefinitely, and
v2 carries a global lock timeout (`PickingorderRepository.findByIdForUpdate` sets an explicit
`jakarta.persistence.lock.timeout=1000`). So this is not an indefinite-hold outage. It is a clean
**denial-of-service lever**: any authenticated `wms_user` can repeatedly take `PESSIMISTIC_WRITE` on
hot rows and make legitimate warehouse write paths fail with lock timeouts. No confidentiality
impact beyond the plain reads those entities already expose.

**Safe to un-export, verified**: zero HTTP callers in `wms2-web-ui`, `wms2-mobile-ui` or
`oms-laravel-api` at `origin/develop` (the 60 `oms` hits are Laravel's own `lockForUpdate()` against
OMS's MySQL — unrelated). The internal Java callers go through the repository directly, which
`exported = false` does not touch: it removes the HTTP route only.

Pinned by `SdrLockingSearchNotExportedContextTest`, which asserts the **invariant** — no exported SDR
search resolves to a `@Lock` method — so the next locking finder cannot be exported silently. It
states its own blind spots: `@Lock` only (a native `SELECT … FOR UPDATE` in `@Query` is invisible),
searches only, and it says nothing about authorization.

⚠️ **Two mechanisms hide inside "un-export"⚠️ **Two mechanisms hide inside "un-export", with different blast radii — do not conflate them.**
`@RestResource(exported = false)` on a **method** removes one search; on the **class**, or via
`ExposureConfiguration`, it removes the whole resource including item and association reads. The 28
no-reference-anywhere types can take the whole-type form. The Tier-B types (`Advice`, `Cyclecount`)
still have **live SDR writes** — `store/receiving/inboundNotices.js:187,380`,
`store/internalOps/cycleCount.js:250` — so a whole-type withdrawal there breaks a working button.
Those are per-search only.

⚠️ **The `Section` near-miss is the standing warning**: SBDEV-3157's sweep regex looked for
`$delete(` and the real call was `$axios.delete(...)`. One resource was one regex away from a broken
delete button with no failing test anywhere. **Confirm every "uncalled" verdict by a second method
before acting on it** — different pattern, or a live probe, not the same grep run twice.

### Slice 3 — operational domain types, staged

The remaining types, in tranches grouped by screen. Each tranche: the rule, its live probe row, and
its own revert. OMS-read resources are last and need P3.

### Slice 4 — mode `FAIL_CLOSED`

Advance the mode to `FAIL_CLOSED` and then delete the mode property entirely; `no rule ⇒ deny`
becomes unconditional; the startup assertion's "exported type with no rule" direction becomes fatal. **Only after P1 has been re-run per tenant**, because this is the
step whose blast radius is the 61 users a typical gate denies, of whom the 17 partial holders
(§1.4) are the ones an over-gate could silently break.

---

## 6. File Change Summary

| File | Change | Slice |
|---|---|---|
| `security/SdrFunctionRules.java` | **new** — rule source keyed on domain type | 0 |
| `security/SdrFunctionRulesStartupAssertion.java` | **new** — fail-fast both directions | 0 |
| `security/FunctionGuardInterceptor.java` | one branch in `preHandle`; metric tagged by domain type | 0 |
| `RestConfiguration.java` | `exported=false` per search for the UNCALLED bucket | 2 |
| repositories in the UNCALLED bucket | `@RestResource(exported = false)` per method | 2 |
| `test/.../SdrSurfaceInventoryContextTest.java` | enumerate association paths (P4) | 0 |
| `test/.../SdrFunctionRulesContextTest.java` | **new** — rule coverage + fail-closed | 0 |
| `test/.../SdrGateDenialContextTest.java` | **new** — AC-2: denied caller gets 403 on `/search/…`. ⚠️ **NOT named `*IT`** — this module has 28 `*IT` classes that run in neither lane (failsafe's `<includes>` overrides the default), so an `*IT` name means the test never runs | 1 |
| `sbdocs/9-System/scripts/smoke-wms2-user-authz-dev.sh` | rows per slice, expectations updated in the same commit | 1–4 |

---

## 7. Testing Plan

### Unit
- `SdrFunctionRulesTest` — any-of semantics; unknown type → `Optional.empty()`; rule set is immutable.
- `FunctionGuardInterceptorSdrBranchTest` — package detection: an SDR declaring class enters the
  branch, one of ours does not, and **a synthetic class in a hypothetical new SDR sub-package also
  enters it** (this is the assertion that makes Fix A's package check meaningful rather than
  decorative).
- Missing `{repository}` variable → deny (§2.5).
- **The Fix D fail-closed rows, which no denial test would catch:**
  (a) `OPTIONS` + `Origin` + `Access-Control-Request-Method` on `/v3/itemdata` resolves to a
  non-`HandlerMethod`; `preHandle` returns `true`.
  (b) a `ResourceHttpRequestHandler` path returns `true`.
  (c) **`preHandle` with a NON-SDR `HandlerMethod` and a pre-set `URI_TEMPLATE_VARIABLES` attribute
  containing `repository` returns `true`** — the direct mutant for the attribute-ordering bug, since
  request attributes survive ERROR and ASYNC re-dispatch.
- Caller-coverage superset test (§9-R1) — an over-narrow any-of set fails the build.

### Integration (Testcontainers PostgreSQL)
- `SdrGateDenialContextTest` — **AC-2**: caller denied the function gets **403** on `/v3/{repo}/search/{name}`. ⚠️ **Do not name either new test `*IT`**: 28 `*IT` classes in this module run in neither lane, so the name alone would make the test vacuous.
- **AC-3**: caller holding it gets 200 — the don't-over-gate rail, on collection, item, search **and
  association** paths.
- Startup assertion: a rule for a non-exported type fails the boot; an exported type with no rule
  fails the boot once Slice 4 lands.

⚠️ **The integration profile sets `rest.security.enabled=false`, so `SecurityConfiguration` is never
built.** Any claim about the filter chain needs a *source-level* assertion —
`Sbdev3017OmsCarveOutSourceContractTest` is the working pattern. Do not assert filter-chain
behaviour from a context test; it will pass vacuously.

⚠️ **Do not read a green suite as evidence SDR is gated.** `FunctionGuardInterceptor`'s own javadoc
says: *"it is reachable, and still open."* That was true while the suite was green.

### Mutation (AC-6)
PIT, scoped to the changed class — never a wide run:
```bash
export SDKMAN_DIR="$HOME/.sdkman"; source "$SDKMAN_DIR/bin/sdkman-init.sh"
mvn -o test-compile -q
mvn -o org.pitest:pitest-maven:mutationCoverage \
  -DtargetClasses=net.aim_ai.wms.security.SdrFunctionRules \
  -DtargetTests='net.aim_ai.wms.unit.security.SdrFunctionRulesTest'
```
Use PIT, not a hand-rolled harness: patch-and-recompile harnesses produced measured false results at
least five times across three sessions on this codebase. Read survivors per
`sbdocs/9-System/mutation-testing-recipe.md`.

### Regression
Full suite against a **freshly measured** baseline. Do not hardcode a count — it moves with every
merge (5704 at SBDEV-3157's merge). Compare failures, not totals.

### Manual test plan

| Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Authz graph closed to a plain user | dev | `sbtest` token → `GET /v3/userRoleUserFunction?size=5000` | **403** (was 200 / 335 rows) | |
| Admin screens still work | dev | `panderson` → open Roles, Groups, Functions, User Management; edit a role's functions | All render and save | |
| **Non-admin operational screens still work** | dev | a **partial holder** (1–77 functions — 17 such users on dev, §1.4), NOT an admin and NOT a zero-function user → walk every screen they can open | No empty tables, no silent blanks | |
| Association reads gated | dev | `sbtest` → `GET /v3/userGroup/{id}/roles` | **403** | |
| Root index | dev | `sbtest` → `GET /v3` | **403** (§2.5) | |
| OMS catalog sync | dev | trigger an OMS→WMS sync | Unaffected (§2.6) | |
| Over-gating canary | dev | pick 2 of the 17 partial holders, ideally one at each end of the range (≈35 functions like `sbtest`, and one near 77); diff their reachable screens before/after | No screen lost | |
| Kept-writable now gated | dev | `sbtest` → `DELETE /v3/client/999999999` | **403** (was 404) — AC-4 | |

---

## 8. Acceptance Criteria

Ticket AC-1…AC-8 apply verbatim. This plan adds:

- **AC-1b** The classification covers **association paths** (`/{repository}/{id}/{property}`), not
  only collection and search. §0 row 4 / §2.4.
- **AC-2b** The 403 is proven on a **collection**, an **item**, a **search** and an **association**
  path — one shape passing does not imply the others; they are three different declaring classes.
- **AC-3b** The don't-over-gate rail is exercised as a **non-admin who holds the function** — not as
  an admin. §1.4-2: 69% of dev users hold everything, so an admin run proves nothing.
- **AC-4b** `GET /v3` and `GET /v3/profile` are decided explicitly and pinned. §2.5.
- **AC-5b** The startup assertion fails in **both** directions: rule without an exported type, and
  exported type without a rule.
- **AC-9** Every "uncalled" verdict acted on in Slice 2 is confirmed by a **second, different**
  method before the un-export lands — different pattern, or a live probe; not the same grep twice.
  The `Section` near-miss (§5 Slice 2) and the HAL-`_links` limit (§0.1) are why.
- **AC-10** For every resource this ticket claims to close, its **MVC twin** is either already gated
  or named as open with the ticket that covers it. §2.7. **This ticket may not claim to close §1.1
  on its own** — `ItemDataController` is ungated and serves the same rows.
- **AC-11** `BOOTSTRAP_READS` is asserted **EMPTY** (Fix F′). Not "pinned and non-growing" — pinning
  a carve-out's contents says nothing about whether an entry is *safe*, and the entry Fix F′ replaces
  was not.
- **AC-12** The smoke script's discriminator is restated after Slice 2. Once a path is un-exported,
  `GET` returns **404 (no such route)**, indistinguishable from **404 (row not found)** — the
  discriminator that made every SBDEV-3157 row meaningful degrades exactly where this plan does most
  of its work. Confirm an un-export by the path's **absence from the runtime inventory**, not by a
  status code.
- **AC-13** Rules for the 5 widest-read types (`Client`, `Location`, `Itemdata`, `Printer`,
  `Unitload`) either carry per-search overrides or are **explicitly declared ceilings**. This ticket
  does not claim to have fitted them.
- **AC-14** `HEAD` and `OPTIONS` on a gated resource are decided and pinned — neither lane analysed
  them, and an ungated `HEAD` leaks existence and row counts that the gated `GET` refuses.

---

## 9. Risks & Mitigations

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | Over-gating breaks a screen for one of the **17 partial holders** (1–77 functions) — the only group that can lose something, since the 44 zero-function users hold nothing to lose and the 38 admins hold everything | **High** — silent: an empty table, not an error. No test fails | **Two automated detectors, not a manual hope.** (a) **`SHADOW` mode per tranche** — evaluate, emit `wms2.authz.sdr.would_deny{domainType,function}`, allow. A non-zero counter *is* the over-gate, found before anyone loses a screen; the only detector that works when 38% of users are immune. (b) **Caller-coverage test** — encode `3169-lane-callers.md` as a fixture, assert each any-of set is a **superset** of the functions of every screen the lane found reading that type, so an over-narrow rule fails at build time. Slice ordering, per-tranche revert and the manual canary are backstops, not the mitigation |
| R2 | "Nothing broke" is measured on someone holding every function | **High** — vacuous green, the exact trap the smoke script exists to prevent | AC-3b: the rail runs as a non-admin holding the function. Never accept an admin run as evidence |
| R3 | A resource is added later with no rule | Medium — silently open, or after Slice 4 a failed boot | AC-5b's second direction. Fail the boot, not the request |
| R4 | Association paths missed | **High** — the authorization-graph traversal is two association reads. A fix that misses them fixes nothing that matters | Fix B keys on domain type, so all three controllers are covered by construction; AC-1b/AC-2b |
| R5 | A claim about `SecurityConfiguration` asserted from a context test | Medium — passes vacuously; the bean is never built under the integration profile | Source-level assertion only; `Sbdev3017OmsCarveOutSourceContractTest` is the pattern |
| ~~R6~~ | ~~The OMS carve-out becomes the new bypass~~ | **RETIRED** by §10-Q1 | There is no carve-out: OMS gets a **function grant** on `oms_integration` instead, so it is governed by the same model as every other principal. Replaced by R6′ |
| R6′ | `oms_integration` is granted more functions than its seven paths need | Medium — over-granting a service principal is quieter than a carve-out but has the same effect | Grant exactly the any-of sets covering its seven paths; assert the grant in the per-tenant P1 query |
| R7 | The Slice-0 flag becomes permanent | Medium — a gate configurable into uselessness | Slice 4 removes it. Do not ship Slice 3 without Slice 4 scheduled |
| R8 | The mechanism set assumed closed | Medium — the "three mechanisms" claim was itself wrong twice on SBDEV-3017 | State which mechanisms each pin covers; never assert completeness |
| R10 | An "UNCALLED" path has a caller outside the three repos searched — `omsv2-UI`, v1 UIs, Postman, ops scripts, BI jobs, third parties | **High** — a broken integration with no failing test | AC-9's second method; stage Slice 2; keep each un-export individually revertible |
| R11 | A caller reaches an SDR path by following a HAL `_links` href, so it appears in no source literal — confirmed once at `WmsApiService.php:3365-3367` (`:3363` is its comment) | **High** — invisible to every static sweep, by construction | Do not treat grep as proof of absence. Probe live before un-exporting a MIXED/OMS-adjacent type |
| R12 | An exemption list grows until the gate is decorative | Medium | Fix F′ removes the need for one at all; AC-11 asserts it **empty**. An entry is a design change, not a config tweak |
| R13 | Every gated SDR read adds an uncached `checkAnyAccess` join on the hottest read surface | Medium | Measure before Slice 3; decide whether the existing Caffeine layer covers it. §11 row 3b |
| R14 | 403-vs-404 on `/v3/{repo}` still enumerates which repositories exist, after `GET /v3` is denied | Low | Accept and document, or return a uniform status. Decide, do not leave implicit |
| R15 | Unbounded page size (`?size=5000`) — measured, and owned by no ticket | Low | Out of scope here; **file or name the owner** rather than leaving it in a parenthesis |
| R16 | 10 cypress-only read paths — gating them may red the e2e suite, or the suite may run as `sb_admin` and prove nothing | Low | Determine which before Slice 2; the lane could not |
| R9 | Per-tenant population differs sharply from dev | Medium — dev's shape (44 zero / 17 partial / 38 admin of 99) may not hold on prod, and the partial-holder band is the one that matters | P1 per tenant before Slice 4. **Carry the method, not the number** — the first pass got this wrong by using the join table as the denominator |

---

## 10. Open Questions / Resolved Decisions

### Open

- **Q1 — ANSWERED. The remedy changes, for the better.** OMS authenticates to `/v3/*` with a
  **Keycloak service account** (`WmsApiService.php:2836+`, `getServiceAccountToken`), not a forwarded
  user JWT — `:3182-3189` states plainly that *"WMS gates `/v3/**` on the `wms_user` authority, which
  an OMS user's JWT does not carry — forwarding it returns 403"*.

  Measured on `dev_wh01_om1` 2026-08-29:

  | | |
  |---|---|
  | `mywms_user` rows named `service-account-*` | **0** |
  | `oms_integration` row | **1** |
  | functions held by `oms_integration` | **0** |

  ⇒ **A function gate on SDR reads denies OMS today**, under either reading of which principal the
  token resolves to: `oms_integration` holds nothing, and no `service-account-*` row exists at all
  (which would make `AccessService` return `USER_NOT_PROVISIONED` — also a denial).

  **So do NOT build a path-scoped exemption. Grant `oms_integration` the functions covering its seven
  paths instead.** That uses the authorization model rather than bypassing it, is auditable in the
  same tables as every other grant, and **deletes §9-R6 entirely** — there is no carve-out left to
  become the new bypass. It also fails safe: if the grant is wrong, OMS 403s loudly rather than
  reading through a hole nobody is watching.

  ⚠️ **Not fully settled**: I did not observe the token OMS actually presents, so which of the two
  readings holds is unconfirmed. The decisive test is one live call with OMS's real credential —
  cheap, and it belongs in Slice 3's prerequisites. The *conclusion* (grant, don't exempt) holds
  either way.

- **Q2 — Is `GET /v3` (root index) denied outright, or gated on any-function-held?** §2.5. Deny is
  the safer default and is what §4 Fix D assumes; confirm before Slice 0.
- ~~**Q3**~~ — **CLOSED by review**: zero. `git grep "@RepositoryRestController|@BasePathAwareController"`
  over `origin/develop -- src/main` in `wms2-api` returns nothing, so Fix A's package check skips
  nothing of ours.
- **Q4 — Does Slice 1 ship on its own?** It closes §1.3, is behaviour-preserving, and is a small
  fraction of the work. Recommendation: **yes**, ship it as its own PR.

### Resolved

- **D1** — Withdrawal cannot substitute for a gate on reads. §2.2.
- **D2** — Rules key on **domain type**, not path. §4 Fix C.
- **D3** — SDR detected by **package**, not a six-class list. §4 Fix A.
- **D4** — **Fail closed**: no rule ⇒ deny. §4 Fix D.
- **D5** — The user population, not role names, is the unit for every reach claim. §1.4.
- **D6** — Split from SBDEV-3157 rather than widening it: that ticket is `on dev` and this scope is
  T3. Both ticket-policy gates say file.

---

## 11. Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ **`db_verified: true`** — `execute_sql` against `dev_wh01_om1` 2026-08-29, recorded in §1.4. Reconciled every §1.3 row count exactly, and **corrected** the population denominator from 55 to 99 (44 users hold zero functions; a typical gate denies 61, not 17). UAT and prd still need P1 before Slice 4 |
| 1 | All callsites enumerated | ✓ §0, from the runtime TSV — **with the association-path gap called out as §0 row 4, not silently omitted** |
| 2 | Adjacent bugs | ✓ §2.4 association reads; §2.5 root index; SBDEV-3142 is the same shape on the MVC read axis and likely wants this rule source |
| 3 | Backward compatibility | ✓ §1.5 (admin callers unaffected), §2.6 (OMS), §9-R1 |
| 3b | **Performance** | **no — gap.** Every gated SDR read adds a `checkAnyAccess` walk of user→group→role→function. Uncached that is a join per request on the hottest read surface. Measure before Slice 3 |
| 4 | Concurrency | no — a read-authorization check with no shared mutable state; no lock, no ordering, no idempotency concern |
| 5 | Multi-tenant | ✓ §5.1-P1 per tenant; rules are static per domain type, evaluated against the caller's tenant-scoped functions via the existing `AccessService` |
| 6 | Error handling | ✓ §4 Fix D decision table; reuses `deny()` / `AccessDecision` at `FunctionGuardInterceptor:247` |
| 7 | Observability | ✓ §5.1-P8 — `wms2.authz.denied` tagged by domain type in Slice 0, before the slices that need it |
| 8 | Rollback / migration | ✓ No Flyway (P5). Per-slice revert; one temporary flag (P6) removed in Slice 4 |
| 9 | Test coverage | ✓ §7 — unit, IT, PIT, manual; named classes |
| 10 | Cross-version (v1↔v2) | ✓ **deferred, and the premise matters.** ⚠️ The first draft said "v1 has no Spring Data REST surface" — **false**: `v1/wms-api` has `spring-boot-starter-data-rest` (`pom.xml:57`), the identical `config.setBasePath("/v3")` (`MyRepositoryRestConfigurer.java:30`) and **61** `@RepositoryRestResource` repositories, only 4 files using `exported = false`. **The same exposure exists in v1.** The conclusion (do not fix it here) survives on *v1 is reference-only*, not on absence. State the finding; do not file a v1 ticket |

---

## 12. Evidence and review

All supporting artefacts live in **`SBDEV-3169-evidence/`** beside this file — moved out of session
scratch so they survive.

| file | what it is |
|---|---|
| `3169-lane-functions.md` | **the rule table source** — 62 rows, domain type → equivalent MVC route → gate today → proposed function. **30 DERIVED / 31 PROPOSED / 1 UNKNOWN.** Not inlined here on purpose: it is data an implementer works from, and it is not review-complete |
| `3169-lane-callers.md` | caller buckets and the per-path 84.6% analysis (§0.1) |
| `3169-review-design.md` | design review — 3 High, 8 Medium, 7 Low, verdict REWORK. All applied |
| `3169-review-facts.md` | adversarial fact-check — 11 false claims. All corrected |

**Everything quantitative in §0–§1 was measured on 2026-08-29** — HTTP against `wms-api.dev.sbo.li`
as `sbtest`; population by `execute_sql` against `dev_wh01_om1`; the surface from
`ResourceMappings` at runtime; controller mappings from `spring-data-rest-webmvc-4.5.7`; UI call
sites via `git show origin/develop:`. The fact-check reproduced every quantitative claim exactly.

### What the first draft got wrong

Recorded because the pattern matters more than the individual errors — **every one was in a claim I
asserted more confidently than the evidence supported**, and two were the exact error the surrounding
paragraph warns against:

1. **Slice 1 would have broken every non-admin login** — `UserGroup` gated with no carve-out.
2. **The carve-out that replaced it granted "anyone's groups"** — the SBDEV-3071 shape. Fix F′ is a
   self-scoped endpoint instead, and the exemption set is now asserted **empty**.
3. **One boolean flag over a fail-closed rule map** — flipping it would have 403'd the other 55
   domain types. Now a four-valued mode.
4. **"Exactly six SDR controller classes"** — a closed-set assertion inside the fix whose stated
   rationale is *do not assert closed sets*. Seven, one in a sub-package, and one of my six was an
   annotation.
5. **OMS cited at `config/wms.php:85-100`** — a comment block. The exact error the paragraph three
   lines above spends a warning on. It also hid a **seventh** OMS path, `client/search/findByClNr`,
   which Slice 2 would have un-exported and broken.
6. **`Set<FunctionEnum>`** — does not compile; `FunctionEnum` is a String-constant holder.
7. **"v1 has no SDR surface"** — v1 has 61 exported repositories on the same base path.
8. **"Two independent corroborations"** — one was the same measurement recorded earlier.
9. **Population denominator 55, not 99** — corrected by the DB check; understated the exposure.
10. **`User` omitted from Slice 1** — its collection is shadowed by an MVC handler returning the
    caller's JWT, so it looked harmless; the **item read `GET /v3/user/{id}` is live SDR** and
    returns arbitrary user records. Found by review, confirmed live.
11. **Six line citations off by 1–3**, including one pointing at a comment rather than the code.
12. **Q3 was not open** (zero custom `@RepositoryRestController`), and **Q1 was mostly answerable**
    from `origin/develop` — both were parked as unknowns without checking.

**The pattern, which is the useful part:** the quantitative work held up — the fact-check reproduced
every number exactly. Everything that broke was a **claim of completeness or a citation**: "every
caller", "exactly six", "the six paths", "no controller at all", "two independent corroborations",
"v1 has none". Where this plan says *all*, *only*, *every* or *no*, distrust it and re-derive.
