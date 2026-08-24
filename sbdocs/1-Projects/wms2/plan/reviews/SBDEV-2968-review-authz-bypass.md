# SBDEV-2968 — Review: authorization bypass lane

## Status: complete

Lens: can this gate be bypassed, and does it deny what it should not?
Subject: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-2968`, branch `bugfix/SBDEV-2968-mobile-function-gating`, `0723f8c` (2 commits ahead of `origin/develop`), plus the paired mobile-UI worktree at `.claude/worktrees/wms2-mobile-ui/SBDEV-2968` @ `ab20df7`.

Executed: `mvn -B -o test -Dtest='FunctionGuardInterceptorUnitTest,FunctionGuardArchTest,FunctionGuardMockMvcUnitTest,FunctionGuardStartupAssertionUnitTest,AccessServiceUnitTest'` → **86 pass, 0 fail, 0 skip**, `git status` clean afterwards (no `archunit_store` mutation). Live SQL against the Hydra UAT tenant DB for the grant-coverage checks below.

---

## Findings

### 1. High — every `MOBILE_UI_VIEW_*` gate is self-grantable in one unguarded Spring Data REST request

`RestConfiguration.java:32` (`setBasePath("/v3")`), `SecurityConfiguration.java:146`, `model/User.java:33-39`, `model/UserGroup.java:22-28`, `model/UserRole.java:27-33`, `security/FunctionGuardInterceptor.java:61-63`.

The three tables `AccessService.checkAnyAccess` reads through (`UserRepository.getAllRoles`, `UserRepository.java:26-34`) are all writable over Spring Data REST by any caller holding only `wms_user`, and SDR is exactly the dispatch path the interceptor's own javadoc says it cannot reach.

- `User.groups`, `UserGroup.roles` and `UserRole.functions` are `@ManyToMany` on entities whose repositories are `@RepositoryRestResource`-exported (`UserRepository:13`, `UserGroupRepository:12`, `UserRoleRepository:12`), so SDR publishes association resources at `/v3/user/{id}/groups`, `/v3/userGroup/{id}/roles`, `/v3/userRole/{id}/functions`.
- The join entities are separately exported with full CRUD: `UserGroupUserRepository:14` (`/v3/userGroupUser`), `UserGroupUserRoleRepository:14`, `UserRoleUserFunctionRepository:14` — each `extends PagingAndSortingRepository … , CrudRepository`, so POST/PUT/PATCH/DELETE are published, and `RestConfiguration:39` puts all of them in `exposeIdsFor`.
- Authorization for those paths comes only from `.requestMatchers("/v3/**", "/putawayConfig/**").hasAnyAuthority("wms_user")`. Section C's `"/userGroup/**", "/user/**"` entries neither tighten nor apply — the SDR base path is `/v3`, so those un-prefixed patterns match nothing, and they name the same authority regardless. Every principal that can reach a gated mobile endpoint at all holds `wms_user` by construction, since `/v3/**` requires it.

Concrete scenario: an operator whose role grants only `MOBILE_UI_VIEW_PICKING` wants cycle count. `GET /v3/userGroup/search/findByUsername?username=<self>` (exported, `UserGroupRepository:21`) yields their group, `GET /v3/userGroup/{id}/roles` their role id; `GET /v3/userFunction/search/findByName?name=MOBILE_UI_VIEW_CYCLE_COUNT` (`UserFunctionRepository:16`) yields the function id; `POST /v3/userRole/{roleId}/functions` with `Content-Type: text/uri-list` and body `/v3/userFunction/{id}` adds the grant. `RepositoryRestHandlerMapping` does not consult `WebMvcConfigurer#addInterceptors`, so `FunctionGuardInterceptor.preHandle` never runs on that request; `getAllRoles` returns the new function on the next call and `GET /v3/cycleCountLos/**` returns 200. One request, no admin function required. Shorter still: `POST /v3/user/{ownId}/groups` pointing at the `super-admin` group yields every function at once.

How established: read-only. The SDR verb semantics on `/v3/userRole/{id}/functions` (PUT replaces, PATCH/POST add, collection DELETE 405) were measured on a live tenant during SBDEV-3013 and are recorded in the project memory note `wms2-sdr-association-resource-verb-reality`; I did not re-issue those requests here, so the last step is inferred from a prior measurement rather than re-executed.

Tried to disprove it: (a) `RepositoryDetectionStrategies.ANNOTATED` (`RestConfiguration:47`) limits exports to annotated repositories — all six authorization repositories carry the annotation, so it does not help; (b) `saveUserGroups` was gated by SBDEV-2870 (`UserController:88-98`), which closes the *MVC* self-grant path but leaves the SDR path on the same tables untouched — the SBDEV-2870 javadoc's own "every function-based gate is bypassable in ONE request" argument therefore still stands, just against a different dispatcher; (c) `@EnableMethodSecurity` is present and effective (`MethodSecurityConfig.java:9`), but no `@PreAuthorize` exists on SDR-generated handlers and no `RepositoryRestConfigurer` restricts them.

Pre-existing on `develop`, not introduced by this branch. Reported because it is the direct answer to this lane's question: against a non-cooperating client the new gate is advisory. The plan's SDR discussion (§3.1-A9, §14.12.a, R16, SBDEV-3017) is entirely about SDR **reads of business data**; nothing in the 2198-line plan addresses SDR **writes to the authorization tables**, so SBDEV-3017 as scoped does not cover it. Either widen SBDEV-3017 to name these six repositories or say so in the closing note — the note must not claim mobile workflows are function-gated without it.

### 2. Medium — AC-32's "closed by removal" does not remove the capability; the same rows stay readable on the same repository

`repo/jpa/FixLocationAssignmentRepository.java:18,36`.

`@RestResource(exported = false)` is applied to `findByAssignedlocationId` only. The type-level `@RepositoryRestResource(path = "fixLocationAssignment")` is untouched and the interface still `extends PagingAndSortingRepository<FixLocationAssignment, Long>, CrudRepository<…>`, so the collection resource and the item resource remain exported, and `FixLocationAssignment` is in `RestConfiguration:36`'s `exposeIdsFor` list.

Concrete scenario: an operator denied `MOBILE_UI_VIEW_REPLENISHMENT` is correctly 403'd on `/v3/replenish/**` and now 404s on `/v3/fixLocationAssignment/search/findByAssignedlocationId`. They then issue `GET /v3/fixLocationAssignment?size=2000`, still served by `RepositoryRestHandlerMapping` under `wms_user` alone, and read the identical `assignedlocation` → `upperbound` pairs the un-exported search returned — plus every other fixed-location assignment in the warehouse. `findByAssignedunitloadId` and the seven other siblings are also still exported and reach the same rows by the other FK. With write verbs on the same repository they can also change `upperbound`.

So AC-32's live proof ("`GET …/findByAssignedlocationId` now 404s") is true and is also not evidence that the capability is gone. The framing in `FixLocationAssignmentRepository.java:26-29` and plan §14.12.b — "closed by **removal**", "removes the capability instead of guarding it" — overstates what one `exported = false` achieves on a repository whose collection resource is still published.

How established: read-only, from the annotation placement and the interface's supertypes. Tried to disprove it: checked for a type-level `exported = false`, for a detection strategy that would hide the repository, and for a `@PreAuthorize`/`RepositoryRestConfigurer` restriction on the collection resource — none is present.

Not a PR blocker: the residual is warehouse configuration rather than an operation, and it is a subset of R12, which the owner has accepted. But AC-32's wording should become "the search is un-exported; the collection and item resources remain open, tracked under SBDEV-3017", so nobody later reads AC-32 as proof the data is unreachable.

### 3. Medium — Fix C2's seed grants are unreachable dead code, and they disagree with V2.2.18 on who gets the new functions

`controller/rest/UtilRestController.java:23-24, 127-128, 430-442, 1036-1044`.

The 41 new lines add `grantFunction(...)` calls inside `initDB()`. `UtilRestController` is annotated **`@Service`** (line 23) with no type-level `@Controller`/`@RequestMapping`, so `RequestMappingHandlerMapping.isHandler` rejects it and none of its 9 `@RequestMapping` methods route; `grep -rn "initDB" src/main` returns only a javadoc mention in `UnitloadRepository.java:121` — there is no programmatic caller. So `initDB()` cannot execute by any path.

That makes two claims in the new comment false as written: "This covers freshly-initialised DBs ONLY" (it covers nothing) and "Both are required; neither is sufficient" (only one of the two exists). Anyone auditing grant coverage who credits C2 for the fresh-tenant case will be crediting inert code.

Compounding it, the two halves disagree on the role lists — so if `initDB` is ever revived the seeded and migrated grants diverge:

| Function | `UtilRestController` `grantFunction` | `V2.2.18` |
|---|---|---|
| `MOBILE_UI_VIEW_CANCELLATION` | inventory-manager, outbound-manager, outbound-worker, super-admin | outbound-worker, outbound-manager, super-admin — **no inventory-manager** |
| `WEB_UI_VIEW_TRANSFER_ORDER` | inventory-manager, outbound-manager, outbound-worker, super-admin | outbound-manager, inventory-manager — **no outbound-worker, no super-admin** |
| `MOBILE_UI_VIEW_REPLENISH_REQUEST` | those same four roles | derived from existing `MOBILE_UI_VIEW_REPLENISHMENT` holders — a different axis entirely |

How established: **executed**, both halves. Static: the `@Service` annotation and the absent caller, above. Live: on Hydra UAT the current grants are `WEB_UI_VIEW_TRANSFER_ORDER` → `super-admin` only; `MOBILE_UI_VIEW_CANCELLATION` → `outbound-manager, outbound-worker, super-admin`; `MOBILE_UI_VIEW_REPLENISHMENT` → `receiving, super-admin`; `MOBILE_UI_VIEW_REPLENISH_REQUEST` absent. Applying V2.2.18 to that state only widens access — nobody on that tenant loses a workflow — so the divergence has no live effect **today** and this is a correctness/claim defect rather than an access regression.

Tried to disprove it: I looked for a type-level `@RequestMapping`, a `@Controller` meta-annotation, an `ApplicationRunner`/`@PostConstruct`/event-listener caller, and a test-only invocation that might imply a provisioning path — none exists. This is the same trap recorded in the memory note `wms2-utilrestcontroller-is-service-not-restcontroller`, which is why the file's name and package make a grep-based reachability check lie.

Fix is small: either delete the `grantFunction` block and let V2.2.18 be the single mechanism (and correct the C3 comment), or reconcile the two role lists and note that the seed half is currently unreachable. Do not leave a comment asserting two-layer coverage when one layer is inert.

### 4. Low — a handler inherited from a non-guarded base class into a guarded controller is silently ungated, and no test, assertion or fail-closed branch can see it

`security/FunctionGuardInterceptor.java:110-125`, `security/FunctionGuardStartupAssertion.java:90-101`, `test/.../FunctionGuardArchTest.java:247,279,289-297`.

Both the interceptor and the boot assertion key on `handler.getMethod().getDeclaringClass()` and then `continue`/`return true` when that class is not in `GUARDED`. Ten of the eleven guarded controllers `extend AdminController`, whose 9 mapped methods register under every subclass prefix (`AdminController.java:29`), so `POST /v3/picking/user/deleteUserByUsername` is a live URL that resolves `declaring = AdminController` → no annotation → not guarded → **allowed by the interceptor**. The fail-closed branch at `:120-124` cannot fire for these because it is itself inside the `GUARDED.contains(declaring)` test, and the golden-map and coverage tests enumerate `getDeclaredMethods()` only, so the inherited surface is outside all three checks.

Not exploitable today: all 9 `AdminController` mapped methods carry `@PreAuthorize(Authority.IS_SB_ADMIN)` (`AdminController.java:79, 107, 120, 133, 142, 154, 175, 214, 224`) and `@EnableMethodSecurity` is active, so they are staff-gated. The defect is that this is the *only* thing holding the alias surface closed and nothing pins it — no test asserts that every mapped method on `AdminController` carries an authorization annotation. `FunctionGuardArchTest#adminControllerCarriesNoRequiresFunction` (`:291`) additionally forbids the obvious future fix, so a new un-annotated mapped method on `AdminController` — or a future non-`AdminController` base class carrying real mobile handlers — becomes reachable under all 43 prefixes with no gate and a green suite.

Concrete scenario for the latent form: someone adds a shared `MobileScanBaseController` with `scanLabel()` and has three guarded controllers extend it. `declaring = MobileScanBaseController` ∉ `GUARDED`, so the interceptor allows `POST /v3/picking/scanLabel` for an operator holding no function at all; the boot assertion passes, the ArchUnit golden map passes because `scanLabel` is not a declared method of any guarded class, and the interceptor's ERROR log never fires.

How established: read-only, by tracing the identical `declaring`-keyed short-circuit in both classes and confirming the test reflection is `getDeclaredMethods()`-scoped. Tried to disprove it: I checked whether `AnnotationUtils.findAnnotation(declaring, …)` at `:113` could recover a subclass annotation — it cannot, it walks *up* from `declaring`, never down to the bean type; and I checked `getBeanType()` is genuinely unused, which the class javadoc confirms is deliberate.

The cheap mitigation is one assertion, not a redesign: pin that every mapped method reachable through a `GUARDED` bean type resolves to either `@RequiresFunction` or `@PreAuthorize`. That is expressible over `RequestMappingHandlerMapping.getHandlerMethods()` in the existing static-function style of `findUnannotatedGuardedHandlers`, keyed on `getBeanType()` for membership while keeping `getDeclaringClass()` for annotation resolution — which preserves the alias-URL behaviour the javadoc argues for while making the inherited surface visible.

---

## Answers to the five questions

**1. Dispatch coverage — no exploitable gap.** ASYNC: `grep` for `Callable|DeferredResult|CompletableFuture|StreamingResponseBody|SseEmitter|@Async` across `controller/mobile/` and `AdminController` returns nothing, so no guarded handler starts concurrent handling; and had one existed, `DispatcherServlet.doDispatch` re-runs `applyPreHandle` on the ASYNC re-dispatch, so the guard would re-evaluate (at the cost of a second `getAllRoles` query). `forward:`/`include:`: `grep` for `"forward:`, `"include:`, `RequestDispatcher` across `src/main` returns nothing; both dispatch types re-enter handler mapping anyway. ERROR: no custom `ErrorController` exists; the only handler is Boot's `BasicErrorController`, whose declaring class is outside `GUARDED`, and the guard has already denied before any error dispatch can occur. `@ExceptionHandler`: `RestExceptionHandler`/`RestEndpointExceptionHandler` unwind only after `preHandle` returned `true`, i.e. after authorization. I also checked `IdempotencyFilter`, whose cache key is `SHA-256(method|path|body)` with no principal component — a replay would short-circuit before the interceptor — but `shouldNotFilter` (`IdempotencyFilter.java:95-109`) restricts it to non-GET `/rest/**`, and all eleven guarded controllers are under `/v3`, so no guarded response is ever cached or replayed. **Verdict: covered.**

**2. SecurityContext population — fails closed, and on guarded paths cannot be null.** The interceptor reads the context only *after* an annotation is resolved (`FunctionGuardInterceptor.java:127`), so on the permitAll paths (`/`, `/v3`, `/v3/token`, `/error`, `/rest/**`, `/api/**`, `/actuator/health/**`) it returns `true` at `:118` without touching `SecurityContextHolder` or the database. On the guarded paths it cannot be unauthenticated: all eleven controllers are `@RequestMapping("/v3/…")` and `.requestMatchers("/v3/**").hasAnyAuthority("wms_user")` denies in `AuthorizationFilter`, before `DispatcherServlet`. Were `authentication` null anyway, `currentUsername()` returns `null`, `getAllRoles(null)` binds `u.name = null` and matches no row, `findByName(null)` is empty, and `checkAnyAccess` returns `USER_NOT_PROVISIONED` → 403 (`AccessService.java:142-158`). Null tenant context is also closed: `TenantDynamicRoutingDataSource.determineTargetDataSource:51-54` routes a null profile to the **landlord** datasource, where the query either finds no `mywms_user` row (403) or fails (500) — never allows. **Verdict: fails closed in every branch.**

**3. Routes that skip the interceptor — yes, Spring Data REST, and it matters more than the plan accounts for.** Confirmed no second `HandlerMapping` bean is declared in the app, so the interceptor covers the whole MVC surface. The `AdminController` alias URLs do skip the function gate by design but are `@PreAuthorize(IS_SB_ADMIN)`-gated (see finding 4). SDR is the real gap, and it is not only the read gap the plan documents: `Stockunit`, `Unitload`, `Pickingorder`, `Cyclecount`, `Billoflading`, `Location` and `Replenishorder` are all exported at `/v3/{path}` with write verbs under `wms_user` alone, so every gated workflow's underlying rows are directly mutable off-dispatch — and, per finding 1, so are the authorization tables the gate itself reads.

**4. Annotation resolution — sound for today's code; one structural blind spot.** Bridge/synthetic methods are not a live risk: `AdminController` is non-generic, no guarded controller implements a generic interface or overrides an inherited handler, so `getMethod()` is never a bridge and `AnnotatedElementUtils.findMergedAnnotation` behind `getMethodAnnotation` sees the real method. Method-level wins over class-level and *replaces* rather than adds, matching the documented contract, and `FunctionGuardArchTest#replenishController_shouldOverrideRequestSideEndpointsOnly` pins exactly which two methods deviate. `AnnotationUtils.findAnnotation(declaring, …)` walks superclasses, which is the correct direction for a class default. The `getDeclaringClass()`-over-`getBeanType()` choice is right for the alias-URL problem it names, but it is also what makes finding 4 invisible — the two properties are the same line and the trade-off is not stated in the javadoc.

**5. Guarded set completeness — complete for the MVC mobile surface, not for the capabilities, and the plan says so.** All eleven controllers carry class-level annotations (verified by reading each declaration) and `FunctionGuardArchTest` (21 tests, all passing) pins the set against the A5 golden map. The sharpest residual is real and already documented: the Move Stock **write** is `POST /v3/stockUnit/transferStock` on the ungated `StockUnitController` (`StockUnitController.java:28,68`), called from `store/moveStock.js:189`, so a user denied `MOBILE_UI_VIEW_STOCK_TRANSFER` is 403'd on `/v3/moveStock/**` yet can still execute the transfer. Plan §0.B line 106 and its "Consequence, stated plainly" paragraph name that exact endpoint, its web-UI co-caller, and this exact consequence, and R12 carries it to SBDEV-3017 — so it is a stated boundary, not a miss. I independently swept the web UI for callers into the eleven prefixes and found **zero**, confirming P3's direction-1 result, and swept the mobile UI's non-gated call roots (`user`, `stockUnit`, `stockunit`, `dashboard`, `system`, `section`, `tenant`): every one is either in §0.B's table or a read outside a gated workflow. No *undocumented* same-operation endpoint outside the set. My one disagreement is grading: R12 is "Low", but for `transferStock` the residual is the entire gated write, not a peripheral read.

---

## Denies-what-it-should-not: checks run, nothing found

- **Cross-workflow API calls.** The only mobile screen that calls another workflow's prefix is Replenish → `GET /v3/lookup/locationByLocationName` (`store/replenish.js:171`), and that method carries the ANY-of `{INFO, REPLENISHMENT}` override (`LookupController.java:91-92`). Verified there is no second caller: `grep -rn locationByLocationName` returns exactly `store/lookup.js:180` and `store/replenish.js:171`. `components/palletizing/_id.vue:31` looked like a Palletizing→Putaway call but is a Vuex namespace and a `$router.push`, not an axios path — disproved.
- **Web UI.** Zero callers into the eleven prefixes, so no web screen 403s.
- **Route-guard coverage.** `pages/` is flat — 12 workflow pages, 4 terminal/home pages — and `requiredFunctionFor` covers all 12 plus `UNGATED_ROUTES` for the other 4, so there is no sub-route that the exact-path map would miss. My initial concern about deep sub-routes (`/picking/order/123`) does not apply.
- **Users who would newly be denied.** On Hydra UAT, 15 of 19 `mywms_user` rows hold all 11 gated functions; the other 4 (`anonymous`, `omallozzi2`, `oms_integration`, `pesposito`) hold **zero** functions. Those four gain 403s where they previously got 200s — but the pre-change tile filter (`origin/develop:store/home.js:109`, `state.menus.filter(menu => results.includes(menu.role))`) already showed them no tiles, so no UI path regresses. `oms_integration` calls `/rest/**`, which is outside the gated set. Executed via SQL on the tenant DB.
- **Grant coverage after V2.2.18.** Applying the migration to the measured Hydra UAT state only widens access (see finding 3's table). Nobody loses a workflow on that tenant. This was **not** checked on the other four tenants — plan items P1/P2 remain owed and this lane does not close them.
- **`rest.security.enabled=false`.** Only `src/test/resources/application-integration.properties:49` sets it, and that lane is down (SBDEV-2217). With no `SecurityFilterChain` bean the Boot default chain authenticates a generated principal that has no `mywms_user` row, so every guarded endpoint would 403 — noted so nobody enables that profile expecting the gate to no-op.

---

## Not examined

Timing/TOCTOU between the `getAllRoles` read and the handler's own work; the Micrometer tag cardinality on `wms2.authz.denied`; the mobile UI's 403 rendering and no-retry behaviour beyond confirming the middleware and catalog agree; the four tenants other than Hydra UAT; `AccessAuditService` correctness.
