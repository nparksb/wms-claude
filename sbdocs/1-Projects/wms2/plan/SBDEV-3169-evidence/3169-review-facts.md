# SBDEV-3169 plan — adversarial fact-check

Verified against `origin/develop`, 2026-08-29:

| repo | sha |
|---|---|
| `v2/wms2-api` | `793203997d85477eb1818d5d32817313db3517e2` |
| `v2/wms2-web-ui` | `cdaf9b0b66d4398db24360485ecc341145f4e0b6` |
| `v2/wms2-mobile-ui` | `f42ac8d4ab1592b8d8e280a86ab15a22eedadca8` |
| `v2/oms-laravel-api` | `fa030eda621b44dd78f29eaa394d52b91100430b` |
| `v1/wms-api` | `a0e859ab0d74096e60e3d8de798ec6f425543b03` |

Also: `~/.m2/.../spring-data-rest-webmvc-4.5.7{,-sources}.jar`; `dev_wh01_om1` via psql on `localhost:25060`; `target/sdr-surface-inventory.tsv`.

---

## Verdict

**The numbers are sound; the citations are not, and two design-bearing framework claims are wrong.**
Every quantitative claim I could reach reproduces exactly — the 62/347/409 surface split, the
84.6% arithmetic, all six §1.3 row counts, and every single figure in the §1.4 population table
(99 / 44 / 12 / 5 / 38 / 0 / 82 / 61, `sbtest`=35, `panderson`=80, `MOBILE_UI_VIEW_LPN_ASSOCIATION`
held by nobody, `mywms_user_mywms_role`=0). The core defect claim in §2.1 is exactly right at the
line numbers given. But **§2.3's controller table is wrong about `/profile`**, **Fix A's "exactly
six classes" is wrong in both directions**, **Fix C's code sketch does not typecheck** (`FunctionEnum`
is a String-constant holder, not an enum), **§2.6 cites a comment block instead of the endpoint
lines and omits a seventh OMS SDR path**, and **§11's "v1 has no Spring Data REST surface" is flatly
false** (v1 has 61 `@RepositoryRestResource` repositories on the same `/v3` base path). Fix it and
implement from it — the mechanism is right and the risk analysis is unusually good — but do not let
§2.3, §2.6 or §4 Fix C reach code as written.

---

## WRONG — claims that are false

| § | claim as written | what is actually true | evidence file:line |
|---|---|---|---|
| 2.3 | table row: `RepositorySchemaController` \| `/profile` — **no `{repository}` variable** | `RepositorySchemaController.schema()` maps `ProfileController.RESOURCE_PROFILE_MAPPING` = **`/profile/{repository}`** — it *does* carry the variable. The controller that maps bare `/profile` with no variable is **`ProfileController`**, which the table omits entirely | sources jar: `ProfileController.java:48-49` (`PROFILE_ROOT_MAPPING="/profile"`, `RESOURCE_PROFILE_MAPPING=PROFILE_ROOT_MAPPING+"/{repository}"`), `:80`,`:94`; `RepositorySchemaController.java:61` |
| 2.3 / 2.5 / 4-D | the two variable-less routes are "the root index and `/profile`", so Fix D's *no-domain-type ⇒ DENY* branch covers them | Only `GET /v3` is variable-less (`RepositoryController.java:71/86/96`, `value={"/",""}`). `GET /v3/profile/{repository}` resolves a `{repository}` variable and will therefore fall into the **rule-evaluation** branch, not the deny-by-no-domain-type branch — served by *two* controllers the plan never names (`RepositorySchemaController`, `alps.AlpsController`) | as above + `alps/AlpsController.java:70`,`:88` |
| 4 Fix A | "There are exactly **six** `Repository*Controller` classes in `spring-data-rest-webmvc-4.5.7`" | Wrong in both directions. **Seven** classes carry `@RepositoryRestController`/`@BasePathAwareController`: the four named + `RepositorySchemaController` + `ProfileController` + **`alps.AlpsController` (a SUB-package)**. And the sixth thing matching `Repository*Controller.class` in the jar is `RepositoryRestController` — **an annotation, not a controller**. The package check is still the right call (it does catch the `.alps` sub-package), but the stated reason is fiction | `unzip -l` on the jar; `grep -rl "@RepositoryRestController\|@BasePathAwareController"` over the sources jar |
| 2.6 | "`oms-laravel-api@origin/develop`, `config/wms.php:85-100`" | Lines 85-100 are a **comment block**. The endpoints are at `:103` (`client_find_by_number`), `:112`, `:113`, `:114`, `:115`, `:118`, and `printer_search_by_type` at `:156`. This is the exact error class §2.6 spends a paragraph warning about | `config/wms.php:85-100` vs `:103-118`,`:156` |
| 2.6 / 9-R6 | the OMS SDR read set is those **six** paths; "scope any exemption to the six named paths" | It is at least **seven**. `v3/client/search/findByClNr` (`config/wms.php:103`) is omitted — OMS calls it to resolve the WMS client id before every `PATCH v3/client/{id}`, and it is a **search**, i.e. exactly the unit Slice 2 proposes to un-export. A `Client.findByClNr` un-export or gate silently breaks OMS client sync | `config/wms.php:103`; `WmsApiService.php:3334` (`GET /v3/client/search/findByClNr?clNr=<code>`) |
| 11 row 10 | "**N/A** — v1 has no Spring Data REST surface" | v1/wms-api has `spring-boot-starter-data-rest` (`pom.xml:57`), the identical `config.setBasePath(MY_BASE_URI_URI)` (`MyRepositoryRestConfigurer.java:30`), and **61** repository interfaces carrying `@RepositoryRestResource` with only 4 files using `exported = false`. The same read exposure exists in v1. The *conclusion* (don't fix v1) survives on "v1 is reference-only"; the stated premise does not | `v1/wms-api@origin/develop` pom.xml:57, MyRepositoryRestConfigurer.java:30, `git grep -l @RepositoryRestResource -- src/main \| wc -l` = 61 |
| 3 Key files | `security/AccessService` | It is `net.aim_ai.wms.**service**.AccessService` — `src/main/java/net/aim_ai/wms/service/AccessService.java:19`, method at `:134`, signature `public AccessDecision checkAnyAccess(String username, String... functions)` | `FunctionGuardInterceptor.java:23` imports `net.aim_ai.wms.service.AccessService` |
| 4 Fix C | `Map<Class<?>, Set<FunctionEnum>>` / `Optional<Set<FunctionEnum>> requiredFunctions(...)` | **Does not typecheck.** `WmsConstants.FunctionEnum` is `public static final class FunctionEnum` with a private ctor and **82 `public static final String`** constants — not a Java enum. `@RequiresFunction.value()` is `String[]` and `checkAnyAccess` takes `String...`. The map must be `Map<Class<?>, Set<String>>` | `service/WmsConstants.java:347-349` + 82 `public static final String`; `security/RequiresFunction.java:68` `String[] value();`; `service/AccessService.java:134` |
| 1.4 / 5.1-P1 | "the exact query is §5.1-P1" (for the 99 / 44 / 12 / 5 / 38 / 61 table) | P1's query returns **per-function holder counts** only — it produces the 38, and nothing else in that table. No query in the plan produces the denominator 99 or the bands. Worse, P1 is written `FROM mywms_group_mywms_user gu JOIN …` — **off the join table**, which is precisely what P1's own ⚠ says not to do. (It happens to be correct *for that query*; the warning is attached to the wrong query.) All the numbers are right — see CORRECT below — the citation is not | plan §5.1-P1 vs my reproduction (banding needs `mywms_user LEFT JOIN …`) |
| 1.4 | "**61** is the same figure SBDEV-3063 recorded as *'without these two open, 61 of 99 users cannot log in'*" — offered as one of "two **independent** corroborations" | Misquote, and not independent. SBDEV-3063 actually says *"**61 of 99 users on `wms2-wineco-dev` hold no user-management function** — gating on `WEB_UI_VIEW_USER_MANAGEMENT` locks out 62% of the user base at login."* Same DB, same function, same join — it is the earlier recording of the same measurement, not a second method | `sbdocs/4-Archieves/wms2/plan/SBDEV-3063-public-handler-marker-for-guarded-membership.md:264-265` |
| 1.5 | "**Every** caller of the six paths in §1.3 lives in `store/admin/*`" → "gating them is behaviour-preserving for **every** legitimate caller" | False, and §1.5.1 three lines later says so: `store/index.js:249` is not in `store/admin/`. The §1.5 table is also not the complete caller set — `store/admin/role.js:77` (`GET /userRole` + qs) and `store/admin/group.js:122` (`GET /userGroup` + qs) are collection reads it omits (harmless — both admin — but the table is asserted as exhaustive) | `store/index.js:249`; `store/admin/role.js:77`; `store/admin/group.js:122` |

---

## STALE — right idea, wrong citation

| § | claim | correct citation |
|---|---|---|
| 1.5.1 | "`store/index.js:256` — the catch calls `this.$toast.error(...)`" | **`store/index.js:259`** (`:256` is a `console.log`). Catch opens at `:257`. Toast string matches the plan **verbatim** |
| 1.5.1 | "`pages/index.vue:147` also try/catches" | `try` at **:146**, `catch` at **:149**; `:147` is `ensureFunctionsLoaded`. Substance (login does not hard-fail) is correct |
| 2.7 | "`ItemDataController.java:99-101` records that removing a `@RequiresFunction` … fell through ALLOWED" | **`:98-100`** (`:101` is blank). Text matches verbatim, including "survived all 5673 tests" |
| 2.6 / 0.1 / 9-R11 | "`WmsApiService.php:3363` explicitly falls back to the `_links.self` href" | `:3363` is the comment; the code is **`:3365-3367`**. (`:3281` for `PATCH v3/client/{id}` is **exact** ✓) |
| 4 Fix C | "`UnitLoadController.java:60-67` … with a **four-line** comment" | Annotation at **`:64-67`**; comment at **`:57-63`** (7 lines), the "dropping STOCK_UNIT 403s half that screen" clause at `:61-63`. The any-of-four function set is exact ✓ |
| 0 | "418 rows" in the TSV | 418 **lines**, **417 data rows** (one header). The 62/347 split is exact |

---

## UNSUPPORTED — asserted without evidence, may still be true

| § | claim | what would settle it |
|---|---|---|
| 0.1 | the whole bucket table (51 live / 10 cypress / 2 OMS-doc / **346** unreferenced) and the per-bucket type counts | Sourced to `3169-lane-callers.md`, which exists only in a **session scratchpad**, not in `sbdocs/` — unreviewable by anyone else. My independent literal sweep over the three `origin/develop` trees: **34 of 347** searches referenced (plan: 38) and **17 of 62** collections on a strict `'path'`/`"path"`/`path?` match (plan: 25 — I under-count OMS, which writes `v3/itemdata` with no leading slash). Order of magnitude corroborated; exact counts not reproducible. Land the lane file in `sbdocs/` before AC-9 can mean anything |
| 1.2 / 1.3 | the live HTTP results (`200`, 1000 / 156 / 1000 rows; the six 200s) | No token available in this lane. The **row counts reconcile exactly against the DB** (82/145/153/127/164/335), which is strong indirect support, but the status codes themselves are unverified here |
| 10-Q1 | "How does OMS authenticate to WMS … **Blocks Slice 3**" | More answerable than "open" implies, from `origin/develop`: `WmsApiService.php:3182-3189` states *"WMS gates `/v3/**` on the `wms_user` authority, which an OMS user's JWT does not carry — forwarding it returns 403"* and calls `preferServiceAuthentication()`; `applyAuthentication` (`:2786-2830`) applies a per-facility credential from `WmsUrlLut` (basic / bearer / keycloak service account). So it is a **service principal**, i.e. the carve-out branch. Remaining unknown: whether that principal has a `mywms_user` row with functions — one DB query per tenant |
| 10-Q3 | "Do we have custom `@RepositoryRestController` classes in our own package" | **Answered: zero.** `git grep "@RepositoryRestController\|@BasePathAwareController" origin/develop -- src/main` in wms2-api returns nothing. Q3 can be closed |
| 5 Slice 1 / 1.3 | Slice 1's seven types "close §1.3" / "the complete access-control model" | **`User` (`GET /v3/user`) is an exported, read-only SDR collection** (TSV row `User /user COLLECTION true`) and appears in neither §1.3's six measured paths nor Slice 1's seven types — despite SBDEV-3079 (SDR serialized `User.password`) and SBDEV-3071 (arbitrary-username user reads) both being about exactly that resource. Add `User` to Slice 1 or state why not |
| 2.7 | "the join tables have no controller at all" | `UserGroupController` and `UserRoleController` do serve the same bindings — `/userGroup/saveGroupRoles`, `/userRole/saveRoleFunctions`, `/userRole/userRoleDetailsById/{id}`, `/userGroup/userGroupDetailsById/{id}`, all called from `store/admin/*`. Both are in `GUARDED`, so the **operative** claim ("no *ungated* MVC twin") holds; "no controller at all" does not |
| 2.7 | table framing "Controllers that serve an SDR-exported entity" for `TransfersController` / `ClubLineController` | There is no `Transfer` or `Clubline` domain type in the 70. They serve `Customerorder` and `CustomerorderBatch` respectively (verified from their imports/ctors), both exported — so the rows survive, but via a different entity than the controller name implies |
| 4 Fix B | `request.getAttribute(URI_TEMPLATE_VARIABLES_ATTRIBUTE)` is populated by the time `preHandle` runs | **I checked this and it holds, but by a non-obvious route worth documenting in the plan:** `BasePathAwareHandlerMapping.lookupHandlerMethod` (`:71`,`:93`) passes a `CustomAcceptHeaderHttpServletRequest` **wrapper** (`:188`) to `super.lookupHandlerMethod`, so `RequestMappingInfoHandlerMapping.handleMatch` sets the attribute on the *wrapper*; `HttpServletRequestWrapper.setAttribute` delegates to the wrapped request, so the interceptor's request object does see it. If that ever changes, Fix D's fail-closed default turns a null lookup into **deny-everything** |
| 7 | "5704 at SBDEV-3157's merge" / "5673 tests" | Not measured in this lane (no `mvn` run, per instructions) |

---

## CORRECT — spot-checked and confirmed

**The enforcement-point analysis (§2.1, §3, §5.1-P8) — every line number exact.**
`FunctionGuardInterceptor.java` is **294** lines. `:159` `preHandle`. `:166`
`Class<?> declaring = handlerMethod.getMethod().getDeclaringClass();` — verbatim. `:168` the
`@PublicHandler` comment ("resolves FIRST"). `:213` `if (!GUARDED.contains(declaring))` →
`:214 return true` — an unannotated handler on a non-GUARDED class **does** fall through ALLOWED.
`:224` `checkAnyAccess`. `:247` `deny(...)`. `:100` `METRIC_DENIED = "wms2.authz.denied"`.
`GUARDED` holds **14** classes and contains **none** of §2.7's ten; it does contain `UserController`,
`UserGroupController`, `UserRoleController`. The `MappedInterceptor` bean is real
(`WebConfig.java:27-59`, `RestConfiguration.java:43-45`), and `5b704e54` **is** the merge of PR #187.

**§0 surface counts — reproduced exactly from the TSV.** Exported COLLECTION = **62**; SEARCH = **347**
(all exported); 62+347 = **409**; un-exported repositories = **8** (CustomerorderCancellationLog,
OutboxMessage, PutawayConfigAudit, RestIdempotency, Tenant, TenantAuthConfiguration,
TenantDbConfiguration, TenantDiscovery); kept-writable exported = **11** (Advice, Boxtype, Client,
Customerorder, Cyclecount, Location, LocationType, Section, Sysprop, UserGroup, UserRole);
`SDR_WRITE_WITHDRAWN` holds **47** model classes, all of them exported → §2.2's "47 of 58" ✓.
`RestConfiguration.java:324` `SDR_WRITE_WITHDRAWN` ✓, `:376` `configureUnwrittenResourceWriteExposure` ✓.
Per-type counts in §0.1: `Replenishorder` **42**, `Stockunit` **21**, `Customerorder` **23**,
`Unitload` **18** — all four exact. Arithmetic: 6+19+6+0+31=62 ✓, 27+177+40+165=409 ✓,
51+10+2+346=409 ✓, 346/409 = 84.6% ✓, 51/409 = 12.5% ✓.

**§2.4 — `SdrSurfaceInventoryContextTest` really does enumerate only `COLLECTION` and `SEARCH`**
(`:47`, `:71`, `:86`, `:101`); nothing enumerates `/{repository}/{id}/{property}`.
`RepositoryPropertyReferenceController` is a distinct declaring class with
`BASE_MAPPING = "/{repository}/{id}/{property}"` and a `/{propertyId}` variant ✓.

**§2.3's other four rows** — `RepositoryEntityController` `BASE_MAPPING="/{repository}"` + `/{id}` ✓;
`RepositorySearchController` `"/{repository}/search"` + `/{search}` ✓;
`RepositoryController` `value={"/",""}` (no `{repository}`) ✓. Jar version **4.5.7** is the one in
`~/.m2` alongside Boot 3.5.9's managed version ✓.

**§1.5 — all nine web-UI call sites are line-exact** at `origin/develop`:
`store/admin/function.js:27`, `management.js:141`, `management.js:158`, `role.js:51`, `role.js:62`,
`group.js:110`, `group.js:189`, `group.js:190`, `group.js:203`. **`wms2-mobile-ui` calls none of the
seven paths** — verified by grep over `origin/develop`.

**§1.5.1's substance — confirmed and if anything understated.** `pages/index.vue:148` dispatches
`getAffiliatedGroupsByUsername` immediately after `ensureFunctionsLoaded`; `redirectPage` is reached
from `handleAuthentication` (`:105`) which fires from `mounted` on every authenticated landing — so
yes, **every login, every user**. `store/index.js:249` is
`GET '/userGroup/search/findByUsername?username=' + username` — verbatim. `findByUsername` is a real
exported search in the TSV. The toast text matches character-for-character.

**§1.3 / §1.4 — every DB number reproduces exactly** on `dev_wh01_om1`:
users **99** · functions **82** · roles **145** · groups **153** · `mywms_group_mywms_user` **127** ·
`mywms_group_mywms_role` **164** · `mywms_role_mywms_function` **335** · `mywms_user_mywms_role` **0**.
Bands: zero-function **44**, 1–39 **12**, 40–77 **5**, 78–81 **38**, all-82 **0**.
`WEB_UI_VIEW_FUNCTION` / `_GROUP` / `_ROLE` / `_CLIENT` / `_USER_MANAGEMENT` = **38** holders each ⇒
**61 denied of 99** ✓. Exactly one function held by nobody, and it is
**`MOBILE_UI_VIEW_LPN_ASSOCIATION`** ✓. `sbtest` = **35** functions and holds **none** of the four
admin functions ✓; `panderson` = **80** ✓. `smoke-wms2-user-authz-dev.sh:13-14` says
*"`sbtest` holds 35 functions … `panderson` holds all 80"* verbatim, and its 403/405/404
discriminator is real (`:85-87`). §1.3's "626 join rows plus 380 entity rows" adds up
(127+164+335=626; 82+145+153=380).

**§2.7 — the gate table is right, including the two rows I was asked to attack.**
`ItemDataController`: 8 handlers, **0** real `@RequiresFunction` (the only textual match is inside
the `:98-100` comment) ✓. `ReportController`: 15 handlers, **1** gate at exactly `:314`
(`@RequiresFunction(WEB_UI_VIEW_PARCEL_PICKING)` on `reprintLabels`), leaving 11 `export*` + 3 `*View`
= 14 ungated ✓. `TransfersController` 17/0, `ClubLineController` 14/0, `MessageController` 4/0,
`StockRecordController` 3/0, `UnitloadRecordController` 2/0, `PickingOrderPositionController` 2/0,
`CustomerOrderPositionController` 2/0, `SystemController` 3/0 ✓. **Counting all mechanisms**: zero
`@PreAuthorize` / `@PostAuthorize` / `@Secured` / `@RolesAllowed` / `@DenyAll` anywhere in the ten;
none is in `GUARDED`; all ten extend `AdminController` and the interceptor resolves on the declaring
class, so no inherited gate reaches them. The only thing that applies is `SecurityConfiguration:178`
`requestMatchers("/v3/**","/putawayConfig/**").hasAnyAuthority(WMS_USER_ROLE)` — a coarse
any-`wms_user` gate, exactly as the plan characterises it. All seven report entities named in §2.7
(`StockView`, `LockOverviewDtoView`/`LockOverviewAllDtoView`, `ViewWarehouseLocationReport`,
`InventoryRecord`, `FlowbinMonitorView`, `OrderDetailMonitorView`, `Stockrecord`) are in the 70.

**Other**: `SecurityConfiguration.java:43` is `@ConditionalOnProperty(prefix="rest.security",
value="enabled", havingValue="true")` and `src/test/resources/application-integration.properties:49`
sets `rest.security.enabled=false` — §7's and §9-R5's warning is exactly right.
`FunctionGuardStartupAssertion.java` and `Sbdev3017OmsCarveOutSourceContractTest.java` both exist ✓.
`PublicHandler` is `@Target(METHOD)` ✓. `losSequencenumber/search/findByClassnameForUpdate` is a real
exported search ✓. `WmsConstants.FunctionEnum` holds exactly **82** constants ✓. `WmsApiService.php:3281`
is the `PATCH` ✓. `printer_search_by_type` really does default to `rest/printer/findByType` with the
v3 SDR path as an env override ✓ (§2.6's "optionally" is precise). No `"structurally cannot"` claim
about SDR survives anywhere in `src/main` ✓.

---

## Things I could NOT verify

1. **The live HTTP evidence in §1.2 and §1.3** — no token in this lane. The row counts reconcile
   against the DB exactly, so I am confident in the *numbers*; the *status codes* (200 vs 403) rest
   on the plan's own run.
2. **`3169-lane-callers.md` / `3169-lane-functions.md`** — they exist only in a session scratchpad,
   not under `sbdocs/`. I could not re-derive their bucket assignments; my independent sweep agrees
   in magnitude, not in count (see UNSUPPORTED).
3. **The 30 DERIVED / 31 PROPOSED / 1 UNKNOWN rule table** — not in the plan document at all, so
   nothing to check. §12 is right that this is the gating unfinished work.
4. **Any test-count or suite claim** — I ran no `mvn`, per instructions.
5. **UAT/prd population (P1)** — only dev was queried.
6. **Whether the OMS service principal has a `mywms_user` row with functions** — needs a per-tenant
   query with the principal's username, which the plan does not name.
