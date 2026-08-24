# SBDEV-2968 — Regression / Contract Review (lane: regression-contract-2)

## Status: complete

Lens: what this change breaks for existing callers. Branch `bugfix/SBDEV-2968-mobile-function-gating`
(`0723f8c`, `efe0c6e`) in `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-2968`, plus the
sibling mobile worktree.

---

## Findings

### 1. HIGH — the 403 denial body nests `reason`/`requiredFunction` under `properties`, so the mobile toast never fires

`FunctionGuardInterceptor.java:160-171` (`deny`) · `wms2-mobile-ui .../plugins/axios.js:197`

The interceptor builds a `ProblemDetail` and sets `requiredFunction` / `reason` via
`problem.setProperty(...)`, then serialises it with the **injected `@Primary` `ObjectMapper`**. That mapper is
hand-built in `WebConfigurer.java:73-83` (`new ObjectMapper()` + two modules + `Include.NON_NULL`) — it is
**not** produced by `Jackson2ObjectMapperBuilder`, so Spring's `ProblemDetailJacksonMixin`
(`@JsonAnyGetter` on `getProperties()`) is never registered. Without the mixin, `ProblemDetail` serialises
as an ordinary bean and `properties` comes out as a **nested object** instead of RFC-7807-flattened members.

Measured body, taken from the branch's own `FunctionGuardMockMvcUnitTest` run (`mvn -o test`, 6/6 green):

```
Status = 403
Headers = [Content-Type:"application/problem+json", X-Authz-Denied:"MOBILE_UI_VIEW_TRUCK_LOADING"]
Body = {"type":"about:blank","title":"Forbidden","status":403,"detail":null,"instance":null,
        "properties":{"requiredFunction":"MOBILE_UI_VIEW_TRUCK_LOADING","reason":"MISSING_FUNCTION"}}
```

The client reads it flat:

```js
// plugins/axios.js:196-199
const body = (error && error.response && error.response.data) || {}
if (status === 403 && body.reason) {
  app.$toast.error(authzDenialMessage(body))
}
```

`body.reason` is `undefined` → the guard is false → **no toast at all**.

Concrete failure: an operator without `MOBILE_UI_VIEW_TRUCK_LOADING` opens the Truck Loading tile and scans a
BOL. The request 403s, `X-Authz-Denied` correctly suppresses the token-refresh retry (axios.js:51 works — that
path reads a real header), and then nothing is rendered. The screen just fails silently. That is verbatim the
failure mode the plan and `test/plugins/authzDenialRendering.spec.js` both say must not happen ("the gate would
work and the operator would see nothing").

Why the tests do not catch it: the Jest fixture hard-codes the flat shape the server does not emit —
`data: { reason, requiredFunction }` (`authzDenialRendering.spec.js:33`). Both sides pass against a shape
neither produces. On the Java side, `FunctionGuardMockMvcUnitTest` asserts the header and the status, and
`BaseControllerUnitTest` builds its own plain `new ObjectMapper()`, so it reproduces the production nesting
faithfully and simply does not assert the body's member names.

Fix is one of: register `ProblemDetailJacksonMixin` on the primary mapper, serialise a plain `Map`/DTO instead
of `ProblemDetail`, or read `body.properties?.reason ?? body.reason` on the client. Whichever is chosen, the
Jest fixture must be corrected to the measured shape first, or it will keep green-lighting the bug.

Established: **executed** (`mvn -B -o test -Dtest=FunctionGuardMockMvcUnitTest`, body read from the surefire
log) + read-only for the client half.

Tried to disprove: checked whether Spring Boot's auto-configured `Jackson2ObjectMapperBuilder` could still win
— it cannot, `WebConfigurer.objectMapper()` is `@Primary` and the interceptor takes `ObjectMapper` by
constructor. Checked whether `ProblemDetail` carries the `@JsonAnyGetter` itself — the executed body above
settles it: it does not.

---

### 2. MEDIUM — V2.2.18 and the `UtilRestController` seed grant different role sets, so a fresh tenant and an existing tenant end up with different mobile access

`src/main/resources/db/migration/V2.2.18__seed_mobile_workflow_functions.sql:44-62` vs
`src/main/java/net/aim_ai/wms/controller/rest/UtilRestController.java:430-443`

| function | code seed (`grantFunction`) | V2.2.18 | divergence |
|---|---|---|---|
| `MOBILE_UI_VIEW_CANCELLATION` | inventory-manager, outbound-manager, outbound-worker, super-admin | outbound-worker, outbound-manager, super-admin | **inventory-manager missing in migration** |
| `WEB_UI_VIEW_TRANSFER_ORDER` | inventory-manager, outbound-manager, outbound-worker, super-admin | outbound-manager, inventory-manager | **outbound-worker missing in migration** |
| `MOBILE_UI_VIEW_REPLENISH_REQUEST` | inventory-manager, outbound-manager, outbound-worker, super-admin | every role already holding `MOBILE_UI_VIEW_REPLENISHMENT` | consistent enough |

Concrete failure, measured on **wms2-wineco-dev** (a v1→v2 migrated tenant, so representative of live data;
role names match the seed's literals exactly — `inventory-manager`, `outbound-manager`, `outbound-worker`,
`super-admin` all exist, so this is not a rename problem):

- `marthamina` holds exactly one role, `outbound-worker`. After V2.2.18 she still lacks
  `WEB_UI_VIEW_TRANSFER_ORDER`, so the mobile Transfer Order tile 403s for her — while an
  `outbound-worker` on a **freshly initialised** tenant gets it from `grantFunction`. Same persona, two
  different answers, depending only on how the DB was provisioned.

Established: **executed** (SQL against the `wms2-wineco-dev` MCP) + read-only diff of the two grant lists.

---

### 3. MEDIUM — measured access loss for existing users, with no backfill and no runbook step

`FunctionGuardInterceptor.java:75-88` (the 11-controller `GUARDED` set) + the eleven class-level
`@RequiresFunction` annotations.

Before this change every mobile endpoint was reachable by any principal holding the `wms_user` authority
(`SecurityConfiguration.java:152`). After it, reachability is per-function. V2.2.18 backfills only the three
*new* functions; the eight pre-existing `MOBILE_UI_VIEW_*` functions are not granted to anybody who lacks them
today. This is the point of the ticket, but it is a behaviour change for named existing users and the plan's
claim that "the split removes nobody's access on the way in" is true only of the `REPLENISH_REQUEST` split, not
of the change as a whole.

Measured on **wms2-wineco-dev**, non-archived accounts only, listing the functions each will start getting 403s
on (before V2.2.18; the `WEB_UI_VIEW_TRANSFER_ORDER` column is what V2.2.18 partially repairs):

| user | roles | will 403 on |
|---|---|---|
| `sbuser17` | *(none)* | all 11 — reason `NO_FUNCTIONS` |
| `sbtest` | `test role` | all 11 |
| `marthamina` | outbound-worker | CYCLE_COUNT, PUT_AWAY, REPLENISHMENT, TRUCK_LOADING, TRANSFER_ORDER |
| `estellavasquez`, `josiemarks` | outbound-forklift/manager/worker | CYCLE_COUNT, PUT_AWAY, REPLENISHMENT, TRANSFER_ORDER |
| `danielvalentim` | 5 roles | PUT_AWAY, REPLENISHMENT, TRANSFER_ORDER |
| `ursulajimenez`, `daniilandriyenko`, `jovanyaguilera`, `markchilcote` | 6 roles | TRANSFER_ORDER |

After V2.2.18 the residual is `marthamina` (5 workflows), `sbtest` and `sbuser17` (11 each).

On **wms2-hydra-uat** the picture is different but not empty: 15 of 19 users hold all 77 functions, and four
hold zero — `anonymous`, `oms_integration`, plus two human-looking accounts `omallozzi2` and `pesposito`, which
would lose all 11 workflows.

Note the diagnostics angle: every one of those denials for a zero-function user logs at **ERROR**
(`FunctionGuardInterceptor.java:143-147`, `USER_NOT_PROVISIONED` / and `NO_FUNCTIONS` at WARN). A single
mis-provisioned tablet retrying a scan loop will produce ERROR-level log volume.

There is an audit endpoint for exactly this question (`GET /v3/adminAction/accessAudit`, `AccessAuditService`)
and a SQL equivalent at `db/audit-access-invariants.sql`, which is the right tool — but nothing in the change
requires it to be *run* per tenant before the image lands.

Established: **executed** (SQL against `wms2-wineco-dev` and `wms2-hydra-uat` MCPs). `wms2-hydra` (prd)
refused: `permission denied for table mywms_user`, so prod exposure is **unmeasured**.

---

### 4. MEDIUM — `WebConfig` now eagerly pulls the whole authz JPA graph into a `WebMvcConfigurer`, against the precedent set two files over

`src/main/java/net/aim_ai/wms/WebConfig.java:10-14`

`WebConfig implements WebMvcConfigurer` and now takes `FunctionGuardInterceptor` by constructor.
`FunctionGuardInterceptor` takes `AccessService`, which takes seven Spring Data JPA repositories plus three
services. `WebMvcConfigurer` beans are instantiated when `DelegatingWebMvcConfiguration` autowires its
configurer list — early in context refresh, and here *unavoidably* so, because
`FunctionGuardStartupAssertion` (`SmartInitializingSingleton`, `security/FunctionGuardStartupAssertion.java:47`)
forces `RequestMappingHandlerMapping` creation as well. So this change makes the tenant `EntityManagerFactory`
and the routing datasource initialise as a side effect of MVC configuration.

The reason this is worth flagging rather than shrugging at is the file it sits next to. The repository's other
`WebMvcConfigurer`, `WebConfigurer.java:41-45`, deliberately injects
`ObjectProvider<SyspropService>` and carries `// not yet wired (very early startup) → legacy` at
`util/json/ApiTimestampFormatResolver.java:55`. Somebody already hit this in this exact position and worked
around it with an `ObjectProvider`. The new code takes the eager form instead.

The cheap, behaviour-preserving mitigation is `ObjectProvider<FunctionGuardInterceptor>` in `WebConfig` (or
`@Lazy` on the interceptor), matching the established pattern.

Established: **could not verify** at runtime. The only proof would be a context load and that lane is down
(SBDEV-2217 — `OmsNotificationConfigContextLoadTest` extends `BaseRollbackIntegrationTest`/Testcontainers).
`mvn -B -o clean compile` is green (exit 0), which says nothing about bean-graph ordering. I could not
reproduce a failure and I could not rule one out.

Partially disproved one sub-worry: I checked whether the earlier EMF initialisation could front-run Flyway
(`ddl-auto=validate` against an unmigrated schema). It cannot — `StartupFlywayMigrationRunner:70` publishes an
`ApplicationRunner`, which runs after refresh, so the EMF already preceded Flyway before this change.

---

### 5. LOW — every gated request adds an uncached five-table join; nothing is cached, and this app already has a cache manager

`service/AccessService.java:139-157` → `repo/jpa/UserRepository.java:26-34`

`checkAnyAccess` calls `getAllRoles(username)` — a native `SELECT DISTINCT f.name` across `mywms_user` ⨝
`mywms_group_mywms_user` ⨝ `mywms_group_mywms_role` ⨝ `mywms_role_mywms_function` ⨝ `mywms_function` — once
per gated request, with no `@Cacheable`. On a deny it issues a second query (`findByName`).

Measured on `wms2-hydra-uat` the tables are 19 / 29 / 34 / 148 / 80 rows, with btree indexes present on every
join column, so the absolute cost today is negligible. But mobile scanning is the latency-sensitive surface in
this product and the app already runs a Caffeine `CacheManager`, so this is a free win that was left on the
table. Not a defect; recording it because it is the per-request cost the review asked about.

Established: **executed** (row counts and `pg_stat_user_indexes` on the `wms2-hydra-uat` MCP) + read-only.

---

## Answers to the five questions

### Q1 — the `/**` interceptor's blast radius on non-mobile traffic — **VERDICT: safe, and it does NOT hit the DB on every request**

`FunctionGuardInterceptor.preHandle` short-circuits in two places before any I/O:

1. `if (!(handler instanceof HandlerMethod))` → `return true`. This covers **static resources** (both
   `WebConfig`'s `/static/**` and `WebConfigurer`'s `/swagger-ui/**` + `/webjars/**` map to
   `ResourceHttpRequestHandler`) and CORS pre-flight (`AbstractHandlerMapping` substitutes a `PreFlightHandler`).
2. No annotation resolved **and** declaring class not in `GUARDED` → `return true`. This covers everything
   else: actuator (`AbstractWebMvcEndpointHandlerMapping$OperationHandler`), springdoc
   (`OpenApiWebMvcResource` / `SwaggerConfigResource`), the `/error` ERROR dispatch (`BasicErrorController`),
   `/rest/**` OMS integration (`controller/rest/**`, none of which is in `GUARDED`), and all 50-odd
   non-mobile `/v3` controllers.

`accessService` is reached **only** when an annotation resolves, i.e. only on the eleven mobile controllers'
own handlers. So there is no per-request database hit for actuator, swagger, static, error, `/rest/**` or the
web UI's traffic. On the paths that do hit it, see finding 5: one uncached indexed join, plus a second query on
deny.

**Spring Data REST is genuinely out of reach**, and for the reason the code states rather than the reason a
casual reading suggests: SDR is served by `RepositoryRestHandlerMapping`, whose `AbstractHandlerMapping`
`initApplicationContext` detects only `MappedInterceptor` **beans**; the `MappedInterceptor` that
`InterceptorRegistry` wraps around this interceptor is set directly on `RequestMappingHandlerMapping` and never
registered as a bean. Same for the actuator mapping. That is consistent with — and is the whole justification
for — the `exported = false` decision in Q5. (Established: read-only, from Spring's dispatch model; I could
not exercise it because the SDR surface needs a booted context.)

One residual: `AdminController` is a base class for 43 controllers, and resolution keys on
`getMethod().getDeclaringClass()`, so its ~9 inherited handlers resolve to `AdminController` — outside
`GUARDED` — and stay **ungated under the eleven mobile prefixes too**. That is deliberate (it is what stops the
43 aliases from inheriting a mobile function) and it is not a regression, but it means the mobile surface is
not fully gated. That is an authorization observation, so I leave it to the authz lane.

### Q2 — is any newly gated endpoint also called by the WEB UI? — **VERDICT: no, zero production call sites**

Enumerated independently of the plan document. I extracted every axios call site in
`/home/nampark/dev/wms-claude/v2/wms2-web-ui` (on `develop`) and grouped by first path segment: **322 call
sites**, of which exactly two are non-literal (`exampleFiles.vue:115` takes a caller-supplied download URL;
`store/admin/labelPrinting.js:256` takes a `url` param whose only four call sites are
`/labelPrinting/{totes,locations,unitLoads}/…`, lines 273-298). The 322 resolve to 55 distinct first segments;
none of them is any of the eleven gated prefixes.

The near-misses are worth naming, because they are why a prefix grep looks like a hit:

| looks like | actually | gated? |
|---|---|---|
| `/replenishOrder/*`, `/replenishorder/*` (12 sites) | `ReplenishOrderController` | no |
| `/putawayConfig/*` (3 sites) | `PutawayConfigController` | no |
| `/cycleCount/*`, `/cyclecount/*` (10 sites) | `CyclecountController`, not `cycleCountLos` | no |
| `/transfers/*` (15 sites) | `TransferController` | no |
| `transferOrderDetails`, `transferOrderByOrderBatchId` | JS identifiers / `/transfers/` path segments | no |

Two qualifications on the verdict:

- **`TransferOrderController` is gated on `WEB_UI_VIEW_TRANSFER_ORDER`**, a web-named function on a
  mobile-packaged controller. Nothing in the web UI calls `/v3/transferOrder/**`, so no web screen breaks —
  but the naming will read as a web endpoint to the next person, and it is the function most existing users
  lack (finding 3).
- **The web UI's Cypress suite does hit the gated prefixes, heavily.** `cypress/support/helpers/wmsHelpers.js`
  and six spec files call `/v3/{putaway,picking,palletizing,truckLoading,cycleCountLos,replenish,lookup}/…`
  (~200 references). Those are API-level e2e flows, not app code, so no production regression — but whichever
  account the suite authenticates as now needs all seven functions or the suite goes red on a permissions
  error that will read as a workflow bug. Nothing in the change grants them.

Established: **executed** (greps + segment enumeration over the web UI repo at `develop`).

### Q3 — did moving `OrderCancellationController` change its URL or break a reference? — **VERDICT: no**

- **URL unchanged.** `@RequestMapping("/v3/cancellation")` at
  `controller/mobile/OrderCancellationController.java:28`; the diff is `similarity index 93%` and touches only
  the `package` line, two imports and the new annotation. It carries the required `/v3` prefix.
- **Component scan**: `StartApplication.java:46` scans `net.aim_ai.wms`. Unaffected.
- **`@ControllerAdvice` scoping**: the only package-scoped advice is
  `RestEndpointExceptionHandler` at `basePackages = "net.aim_ai.wms.controller.rest"` — neither the old nor
  the new package is under it, so the controller's error mapping is unchanged (it keeps the unscoped
  `RestExceptionHandler`).
- **springdoc grouping**: `OpenApiConfig.java:35-58` groups by **path**, not package —
  `webApi` = `/v3/**`, `mobileApi` = `/v3/mobile/**`, `restApi` = `/rest/**`. `/v3/cancellation` was in `webApi`
  before and still is. The move does not migrate it into the mobile group (arguably it should, but that is not
  a regression).
- **Security path config**: `SecurityConfiguration.java:152` matches `/v3/**`. Unchanged.
- **Convention test not disarmed**: `ControllerRequestMappingConventionUnitTest` walks
  `src/main/java/net/aim_ai/wms/controller` with `Files.walk` (recursive) and has an explicit premise guard
  (`hasSizeGreaterThan(40)`), so `controller/mobile/` is still inspected and the guard would catch a move that
  escaped the root.
- **Only other references** are the branch's own: the interceptor's `GUARDED` import
  (`FunctionGuardInterceptor.java:12,88`) and two tests that pin the new location by FQCN
  (`FunctionGuardArchTest:333-335`, `FunctionGuardMockMvcUnitTest:79`).

Verified by reading the annotations and the config classes, not by trusting the tests. Established:
**read-only** (plus a green `mvn clean compile`).

### Q4 — CORS exposed-header change — **VERDICT: additive, duplicate-safe, cycle-count entry preserved; the `reset()` hazard does not apply**

`SecurityConfiguration.java:184-195`. It re-reads `configuration.getExposedHeaders()` after the cycle-count
block and adds `X-Authz-Denied` only when absent, so:

- **Additive**: nothing is removed or replaced; `allowedOriginPatterns`/`allowedHeaders`/`allowedMethods` are
  untouched.
- **Duplicate-safe**: the `contains()` guard handles the case where the environment already supplies the header
  via `rest.security.cors.exposed-headers` (`addExposedHeader` does not de-duplicate).
- **Cycle-count entry preserved**: `application.properties:106` supplies
  `X-Export-Skipped-Cycle-Counts`, so the first block's `contains()` guard skips its re-add and the entry
  survives; the (correctly tightened) assertion at `SecurityConfigurationTest:87` now expects both headers
  via `containsExactlyInAnyOrder`, which still catches a silent drop.
- No `*` wildcard is in play — the property lists one concrete header — so there is no `["*", "X-…"]`
  interaction to worry about.

**On the `response.reset()` hazard**: it does not apply here and I checked rather than assumed.
`FunctionGuardInterceptor.deny()` (lines 160-175) never calls `reset()` or `resetBuffer()` — it runs in
`preHandle`, before any handler has written, so there is nothing to discard. It sets status, content type and
the header and then writes, in that order, which is correct. And the CORS response headers are added by the
`CorsFilter` in the security chain, i.e. *before* `DispatcherServlet` ever dispatches, so they are already on
the response when the denial is written and nothing in the deny path can strip them.

Established: **read-only** for the config, **executed** for the header actually being emitted on the wire
(`X-Authz-Denied:"MOBILE_UI_VIEW_TRUCK_LOADING"` in the surefire log). Per the repo's own note, neither a
MockMvc test nor curl can verify *exposure* — that still needs the browser check the plan calls M23.

### Q5 — `@RestResource(exported = false)` — **VERDICT: no caller broken, replacement is semantically equivalent, siblings untouched**

- **Callers of the HAL path**: exactly one across both UI repos —
  `wms2-mobile-ui/components/replenish/shared/OrderHeaderBlock.vue:92` on `develop`, migrated in the same
  change set to `GET /replenish/fixedLocationUpperBound/{locationId}` (line 101 in the worktree). The web UI
  has **zero** references to `fixLocationAssignment`, `findByAssignedlocationId`, or the new endpoint. (The
  web UI's 8 `fixedAssignment` axios calls are a different path served by a controller, not this repository.)
- **Shape and semantics**: old = SDR, four possible envelopes (bare object / array / paged `.content` /
  HAL `._embedded`), 404 on an empty `Optional` → the client's `catch` set the bound to `null`.
  New = `ResponseEntity.ok(BigDecimal | null)`, i.e. a bare JSON number, or 200 with an empty body when there
  is no assignment. The client's replacement parse (`resp === null || resp === '' ? null : Number(resp)`,
  then `Number.isFinite`) maps every one of those to the same `destinationUpperBound` value the old code
  produced, including the not-found case. Equivalent.
- **The eight siblings stay exported**: `findByAssignedunitloadId`, `findByItemdataId`,
  `findDistinctByState`, `getRefillFixedLocations`, `getFixedLocationAndItemDataIds`, `getDetailView` all keep
  their `@RestResource` with no `exported` attribute; the two un-annotated methods
  (`findByItemdataIdIn`, `findItemdataIdsByIdIn`, `getRefillFixedLocationIds`,
  `getFixedLocationAndItemDataIdsPage`) were never HAL-exported by name and are unchanged. Only the one line
  changed.
- **One coupling worth noting, not a defect**: `OrderHeaderBlock.vue` is imported only by
  `components/replenish/process/{selectSource,selectDestination,selectUnitLoad}.vue` — never by
  `components/replenish/request/*` — so putting the new endpoint under the class-level
  `MOBILE_UI_VIEW_REPLENISHMENT` default (rather than the `REPLENISH_REQUEST` half) matches the actual callers.
  I checked the C1 split the same way: the request subtree dispatches exactly `replenish/scanLocation` →
  `/replenish/requestLocation/{v}` and `replenish/requestAmount` → `/replenish/requestAmount`, which is
  precisely the pair carrying the method-level `REPLENISH_REQUEST` override. The split is caller-accurate.
  Likewise `/lookup/locationByLocationName`'s ANY-of `{INFO, REPLENISHMENT}` covers both its callers —
  `store/lookup.js:180` (Info screen only, reached solely from `components/lookup/*` and `pages/lookup.vue`)
  and `store/replenish.js:171` inside `updateOrderSourceLocation`, dispatched only from
  `process/selectSource.vue`.

Established: **executed** (greps across both UI repos and the mobile worktree) + read-only for the shape
comparison.

### Also asked — does the `BaseControllerUnitTest` change alter behaviour for the ~40 existing subclasses? — **VERDICT: no**

`common/base/BaseControllerUnitTest.java:77-104` adds one new method, `setupMockMvcWithGuard(Object,
HandlerInterceptor)`. `setupMockMvc(Object)` and `setupMockMvc(Object, Object...)` are byte-for-byte unchanged;
the only other edit in the file is one import. No field, constructor, or shared-state change, and no
overload-resolution ambiguity (the new method has a distinct name). Note in passing that the new method does
not call `setControllerAdvice(...)`, so a test using it gets no advice mapping — that affects only the one new
test that uses it.

Established: **read-only** on the diff; suite run pending (below).

---

## Coverage / what I did not cover

Executed: `mvn -B -o clean compile` (exit 0); `mvn -B -o test -Dtest=FunctionGuardMockMvcUnitTest` (6/6 green,
used for the finding-1 body capture); SQL against the `wms2-hydra-uat` and `wms2-wineco-dev` MCPs; axios
enumeration over `wms2-web-ui@develop` and both mobile UI trees.

Not covered / could not verify: the bean-graph ordering in finding 4 (no working context-load lane,
SBDEV-2217); prd exposure for finding 3 (`wms2-hydra` MCP returns `permission denied for table mywms_user`);
CORS header *exposure* in a real browser; the SDR non-reach claim by execution rather than by reading Spring's
dispatch model. Out of scope by assignment: authorization-model questions (the `AdminController` alias
surface), the migration lane's Flyway-versioning concerns, and test-adequacy beyond the two contract defects
above. Per repo policy no code, staging, or commits were made anywhere; this file is the only artifact.

Full unit suite: `mvn -B -o test -Dtest='net.aim_ai.wms.unit.**'` → **5239 run, 2 failures, 0 errors, 61
skipped**. Both failures are the two known clean-`develop` baselines
(`OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses`,
`MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`) and neither is attributable to
this branch. No other test regressed, which also settles the `BaseControllerUnitTest` question empirically.
The run mutated `src/test/resources/archunit_store/5fb3fee0-…` as expected; I reverted it with
`git checkout --`, so the worktree is back to two-commits-clean.
