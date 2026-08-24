---
title: SBDEV-2968 review — test adequacy (mutation-tested)
ticket: SBDEV-2968
lane: test-adequacy
date: 2026-08-20
verdict: findings — 15 surviving mutants, 22 killed
---

# SBDEV-2968 — test adequacy review (mutation-tested)

**Lens:** do the new tests assert anything, and would they catch the defects they claim to prevent?
Every verdict below is a measured mutation, not a reading.

## Direct answer to the lead's question

**No. The interceptor's fail-CLOSED path is asserted by nothing.**

`FunctionGuardInterceptor.java:116-125` is the branch that denies an unannotated handler on a
guarded controller. I replaced its body with `return true;` — i.e. flipped deny to allow, the exact
mutation asked about — and the suite reported **42 tests, 0 failures**. Nothing went red.

It is not merely untested, it is **structurally unreachable from a test as written**: `GUARDED` is a
private static constant, and all eleven guarded controllers carry a class-level annotation, so no
handler can enter the branch. Contrast `FunctionGuardStartupAssertion`, which takes the guarded set
as a *parameter* precisely so its violation branch is reachable — and says so in its own javadoc
(`:47-52`). Applying that same treatment to the interceptor (constructor-inject the set) would close
findings 3 and 4 together.

## Harness validation (the mtime trap)

The trap was handled, and I have positive controls proving it.

- Both harnesses `touch` after restore. The bash harness does `cp bak file; touch file`; the python
  harness does `shutil.copy(bak, p); os.utime(p, None)`.
- **Every** mutant ran a RECOVERY pass after restore and confirmed green before the next mutant.
- **Null mutants (2, both survived correctly):** a comment-only line added to
  `FunctionGuardInterceptor.java` → 42 tests, 0 failures; a comment-only line added to
  `middleware/require-function.js` → 170 passed. Neither cosmetic change was "caught", so the
  harness is not spuriously red.
  - Disclosure: my *first* attempt at the JS null mutant passed a literal `\n` through `argv`, which
    collapsed the replacement onto one line and commented out the function signature. It killed 4
    tests. That was a harness bug, not a finding; `N1b` is the corrected run and it survived.
- **Positive controls for the two Java files that had no killed mutant** (so a survivor there could
  not otherwise be distinguished from a file that never recompiled):
  - `C1` — `FunctionGuardStartupAssertion.java`: inverted `if (!guarded.contains(declaring))` →
    **2 failures**. The file recompiles and is observed. So M9/M10 surviving is real.
  - `C2` — `WebConfig.java`: injected a type error → **COMPILATION ERROR**. The file is on the
    compile path. So M3/M25 surviving is real.
  - `C3` — `Authority.java`: injected a type error → **COMPILATION ERROR**. So M22 surviving is real.
- **Decisive controls on the mobile side** (stronger than mutation): I appended a hard **syntax
  error** to `store/home.js` and, separately, to `nuxt.config.js`. In both cases Jest reported
  **15 suites passed, 170 tests passed**. Neither file is loaded by any spec at all. Findings 2 and
  7 do not rest on mutant subtlety — those modules are simply outside the test suite.
- `C4` — the migration's *filename* assertion does work (renaming `V2.2.18__` → `V2.2.19__` turns
  `FunctionGuardArchTest:503` red), which isolates finding 11 to the file's *content*.

Compared `Tests:` counts, not `Test Suites:`, throughout. Baselines: Java **151 tests / 0 failures**
on the targeted set; Jest **170 passed / 170 total**. The two known-bad `develop` tests
(`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`) were excluded and are not reported.

## Worktree state

Both worktrees are byte-identical to how I found them. Verified after the last mutation:

- `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-2968` — `git status --porcelain`
  empty, `git diff` empty, HEAD `0723f8c`. Final re-run: 151 tests, 0 failures.
- `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-mobile-ui/SBDEV-2968` — `git status
  --porcelain` empty, `git diff` empty, HEAD `ab20df7`. Final re-run: 170 passed, 170 total.

Nothing is left mutated. `src/test/resources/archunit_store` was `git checkout --`'d after every
Maven invocation; it is clean. This report file is the only artifact created.

---

## Findings

### 1. High — `v2/wms2-api/src/main/java/net/aim_ai/wms/WebConfig.java:35`
Nothing anywhere asserts the interceptor is actually registered with Spring MVC, so the entire gate
can be un-wired with a green suite — `FunctionGuardMockMvcUnitTest` installs the interceptor by hand
via `setupMockMvcWithGuard`, proving it works *when reached*, never that production reaches it.

- Mutant A: deleted `registry.addInterceptor(functionGuardInterceptor).addPathPatterns("/**");`
  entirely → **100 tests, 0 failures** (survived).
- Mutant B: `addPathPatterns("/**")` → `addPathPatterns("/mutant-never-matches/**")` →
  **95 tests, 0 failures** (survived).
- Control `C2` proves the file compiles, so these are genuine.

### 2. High — `v2/wms2-mobile-ui/nuxt.config.js:12`
The client-side twin of finding 1: `router.middleware: ['require-function']` is the only thing that
makes the route guard run on navigation, and no spec reads `nuxt.config.js` —
`requireFunction.spec.js` invokes the middleware function directly.

- Mutant: commented out the `middleware:` entry → **170 passed, 170 total** (survived).
- Control `C6`: a hard syntax error in `nuxt.config.js` also leaves 170 passed — the file is
  provably never loaded by the suite.

### 3. High — `FunctionGuardInterceptor.java:116-125`
The fail-closed branch — "an unannotated handler on a guarded controller is denied", the mechanism's
central safety claim — has no test, and cannot be reached by one (`GUARDED` is a private constant and
every guarded controller is annotated).

- Mutant: `deny(...); return false;` → `return true;` → **42 tests, 0 failures** (survived).
- Same file yielded 6 killed mutants (M4, M5, M6, M7, M12, M17), which proves edits here do
  recompile and are observed. The branch itself is what is unwatched.

### 4. High — `FunctionGuardInterceptor.java:77-88`
`GUARDED` is unasserted. Its only readers are the fail-closed branch (finding 3) and
`FunctionGuardStartupAssertion`'s 1-arg overload (finding 5) — both untested — so the set can be
wrong, or empty, with no signal anywhere.

- Mutant: `Set.of(<11 controllers>)` → `Set.of()` → **95 tests, 0 failures** (survived).

### 5. High — `FunctionGuardStartupAssertion.java:64` and `:53`
Both production entry points are untested; only the 2-arg pure function is exercised, and only with
fixture classes. `FunctionGuardStartupAssertionUnitTest:98-105`
(`theRealGuardedSurfaceIsFullyAnnotated`) is the sole test using the production set and it passes a
**single** handler (`PutawayController#calculatePutawayList`), so it cannot see either mutant.

- Mutant A (`:64`): `findUnannotatedGuardedHandlers(handlers, FunctionGuardInterceptor.GUARDED)` →
  `..., java.util.Set.of())`, i.e. the boot check grades nothing → **91 tests, 0 failures**
  (survived).
- Mutant B (`:53`): `if (!violations.isEmpty()) {` → `if (false) {`, i.e. the boot never fails →
  **100 tests, 0 failures** (survived).
- Control `C1` proves this file recompiles and is observed.

### 6. High — `AccessService.java:137-140`
`checkAnyAccess` with empty varargs — precisely the input the fail-closed path produces — is
untested. `AccessServiceUnitTest:806` covers empty varargs only for the *other* method,
`doesUserHaveAnyAccess`.

- Mutant: the `MISSING_FUNCTION` return → `AccessDecision.allow()` → **91 tests, 0 failures**
  (survived). Note this is fail-OPEN on a `@RequiresFunction({})` misconfiguration, which the
  annotation's own javadoc (`RequiresFunction.java:53`) promises denies.
- The same file yielded a killed mutant (M11), so recompilation is proven.

### 7. Medium — `v2/wms2-mobile-ui/store/home.js:135-168`
`ensureRolesLoaded` — the whole mobile roles fetch, the module-level `rolesPromise` memoisation, and
the `rolesError` flag — is executed by no test. `requireFunction.spec.js:27-42` builds a hand-written
store double with `dispatch: jest.fn()`, so the middleware spec's
`routesToUnhealthyTenantWhenRolesFetchFailed` asserts against a `rolesError: true` fixture that
nothing proves the store can ever produce.

- Mutant A: `ensureRolesLoaded` made an immediate no-op → **170 passed** (survived).
- Mutant B: success path commits `setRolesError(true)`, i.e. every load reports an outage →
  **170 passed** (survived).
- Mutant C (`:180`): `MENU.filter(...)` → `[]`, i.e. no tiles ever render → **170 passed** (survived).
- Control `C5`: a hard syntax error in the file still leaves 170 passed — the module is never loaded.

**The specific defect this hides.** At `store/home.js:154-158`, when `username` is falsy the action
returns *without committing `setRolesLoaded`*, leaving `functions: []` and `rolesError: false`.
`require-function.js:34-40` then reads that as "loaded, holds nothing" and redirects to
`/not-authorized`. That is exactly the R6 cold-start bounce the file's own comment claims to prevent,
and it is reachable: `pages/index.vue:194` is the only other `setMenus` caller and it runs *after*
middleware, so a hard refresh or deep link has no username yet. No test can see it.

### 8. Medium — `FunctionGuardMockMvcUnitTest.java:120-144`
`everyGuardedControllerAdmitsAUserHoldingItsFunction` stubs `checkAnyAccess` to return
`AccessDecision.allow()` **unconditionally**, which makes the assertion tautological with respect to
*which* function the controller demands — despite the test's name. Relatedly, `SURFACE`'s second
column (the expected function, `:57-81`) is never read: both loops use only `e.getValue()[0]`. It
reads as a per-controller function contract, but only the path column is live.

- Mutant: `PickingController`'s class annotation `MOBILE_UI_VIEW_PICKING` → `MOBILE_UI_VIEW_INFO` →
  **91 tests, 1 failure**, and the sole failure was
  `FunctionGuardArchTest.controllerToFunctionMapMatchesTheGoldenMap:230`. All six MockMvc tests
  stayed green against a controller demanding the wrong function.
- Not "add more tests": the ArchTest does cover the mapping. The finding is that the MockMvc class
  advertises coverage it does not have, which is how a reviewer stops looking.

### 9. Medium — `Authority.java:82`
The header *value* `"X-Authz-Denied"` is a cross-repo contract with no test on either side pinning
it. Every Java assertion resolves it symbolically (`FunctionGuardInterceptorUnitTest:151`,
`SecurityConfigurationTest:87,105,120`), while `plugins/axios.js:50` and `axios.spec.js:47` hard-code
the lowercase literal `'x-authz-denied'`.

- Mutant: `"X-Authz-Denied"` → `"X-Mutant-Header"` → **100 tests, 0 failures** (survived).
- Effect: the mobile no-retry branch and the `Access-Control-Expose-Headers` entry both break
  silently, and per the plan's own M23 note neither curl nor the DevTools Network panel can detect
  the exposure failure — only JS reading the header can.
- Control `C3` proves the file compiles.

### 10. Medium — `AdminActionController.java:341`
`GET /v3/adminAction/accessAudit` returns every `mywms_user`'s function list;
`@PreAuthorize(Authority.IS_SB_ADMIN)` is its only guard, and nothing asserts the annotation is
present — not even an ArchUnit rule, though `FunctionGuardArchTest` already has a rule *forbidding*
`@PreAuthorize` on mobile controllers.

- Mutant: removed the `@PreAuthorize` line → **132 tests, 0 failures** (survived).

### 11. Medium — `V2.2.18__seed_mobile_workflow_functions.sql` (asserted only at `FunctionGuardArchTest.java:500-503`)
The only assertion about the migration is that a filename starting with `V2.2.18__` exists. Its
content — the two `mywms_function` inserts and the back-compat `REPLENISH_REQUEST` grant, which is
the *sole* path by which existing tenants keep access — is unverified.

- Mutant: commented out the `INSERT INTO mywms_function` block → **87 tests, 0 failures** (survived).
- Control `C4`: renaming the file to `V2.2.19__` *does* turn the row red, which isolates the gap to
  content rather than existence.
- Defect that ships: on an existing tenant, operators lose the RTS tile, the Transfer tile and the
  Replenish-request half on deploy, with green CI. Not fixable by a unit test — this belongs in the
  verify script or a Flyway lane, not in `anySatisfy(startsWith)`.

### 12. Low — `v2/wms2-mobile-ui/util/menuCatalog.js:23` (and every other `role:`)
`menuCatalog.spec.js:36-46` checks only that `role` is *truthy*; nothing cross-checks the twelve role
strings against the API's `FunctionEnum`, the Java `GOLDEN_MAP`, or
`AccessAuditService.GATED_WORKFLOWS`. There are three independent copies of this map and no test
relating any two.

- Mutant: `role: 'MOBILE_UI_VIEW_PICKING'` → `role: 'MOBILE_UI_VIEW_WRONG_MUTANT'` →
  **170 passed** (survived).
- Effect: the Picking tile never renders and the route guard denies `/picking` to everyone,
  permanently.

### 13. Low — `AccessService.java:135`
`requiredFunction = functions[0]` is unasserted, so the function named to the operator, in the
ProblemDetail body and in the `X-Authz-Denied` header for a multi-valued `@RequiresFunction` (today
only `LookupController#locationByLocationName`) is unpinned.

- Mutant: `functions[0]` → `functions[functions.length - 1]` → **100 tests, 0 failures** (survived).

### 14. Low — `v2/wms2-mobile-ui/middleware/require-function.js:39`
`requireFunction.spec.js:79-80` asserts only `toContain('workflow')` and `toContain('fn')` — the
substrings, not the values — so both params can be empty and the `/not-authorized` page has nothing
to display, which is the entire reason the plan routes there rather than to `/`.

- Mutant: replaced the template literal with `redirect('/not-authorized?workflow=&fn=')` →
  **170 passed** (survived).

### 15. Low — `v2/wms2-mobile-ui/util/menuCatalog.js:100`
`UNGATED_ROUTES` is unasserted, and in fact redundant: `deriveRouteFunctionMap()` has no entry for
those paths, so `requiredFunctionFor` returns `null` for them either way.

- Mutant: `UNGATED_ROUTES = []` → **170 passed** (survived).

---

## Full mutant table

Every mutant attempted, including null mutants and positive controls.
"survived" = the suite stayed green against broken production code.

| # | Mutant | Target | Result |
|---|---|---|---|
| M0 | comment line added (**NULL MUTANT**) | `FunctionGuardInterceptor.java` | **survived** — harness sane |
| N1b | comment line added (**NULL MUTANT**) | `middleware/require-function.js` | **survived** — harness sane |
| N1 | (discarded) literal `\n` collapsed the line, commenting out the fn signature | `middleware/require-function.js` | harness bug, not a verdict — re-run as N1b |
| C1 | **CONTROL** `if (!guarded.contains(..))` → `if (guarded.contains(..))` | `FunctionGuardStartupAssertion.java` | killed (2F) — file recompiles & is observed |
| C2 | **CONTROL** injected type error | `WebConfig.java` | COMPILATION ERROR — file is on the compile path |
| C3 | **CONTROL** injected type error | `Authority.java` | COMPILATION ERROR — file is on the compile path |
| C4 | **CONTROL** migration renamed `V2.2.18__` → `V2.2.19__` | migration filename | killed (1F) — the filename row works |
| C5 | **CONTROL** hard syntax error appended | `store/home.js` | **170 passed** — module never loaded by any spec |
| C6 | **CONTROL** hard syntax error appended | `nuxt.config.js` | **170 passed** — file never loaded by any spec |
| M1 | fail-closed branch → `return true` | `FunctionGuardInterceptor:123` | **survived** (42 tests, 0 failures) |
| M2 | `GUARDED` → `Set.of()` | `FunctionGuardInterceptor:77` | **survived** (95, 0) |
| M3 | `addPathPatterns("/**")` → never-matching pattern | `WebConfig:35` | **survived** (95, 0) |
| M4 | `getMethod().getDeclaringClass()` → `getBeanType()` | `FunctionGuardInterceptor:110` | killed (5F/4E) |
| M5 | annotation resolution priority inverted | `FunctionGuardInterceptor:111-114` | killed (2F) |
| M6 | `X-Authz-Denied` header not set | `FunctionGuardInterceptor:169` | killed (1F) |
| M7 | `response.reset()` inserted before writing | `FunctionGuardInterceptor:164` | killed (1F) |
| M8 | empty varargs → `allow()` | `AccessService:139` | **survived** (91, 0) |
| M9 | 1-arg overload passes `Set.of()` | `FunctionGuardStartupAssertion:64` | **survived** (91, 0) |
| M10 | `if (!violations.isEmpty())` → `if (false)` | `FunctionGuardStartupAssertion:53` | **survived** (100, 0) |
| M11 | `held.contains(fn)` → `true` | `AccessService:145` | killed (1F) |
| M12 | `if (decision.allowed())` → `if (true)` | `FunctionGuardInterceptor:130` | killed (4F/5E) |
| M13 | `PickingController` fn → `MOBILE_UI_VIEW_INFO` | `PickingController` | killed (1F — ArchTest only; MockMvc blind) |
| M14 | `keycloakMapped` key omitted when false | `AccessAuditService:67` | killed (2F) |
| M15 | `GATED_WORKFLOWS` "lookup" entry removed | `AccessAuditService:95` | killed (1F) |
| M16 | `allowed()` → `reason != ALLOWED` | `AccessDecision:59` | killed (8F/6E) |
| M17 | denied metric renamed | `FunctionGuardInterceptor:71` | killed (2E) |
| M18 | `USER_NOT_PROVISIONED` tag → `"missing_function"` | `AccessDecision:43` | killed (1E) |
| M19 | `exported = false` → `true` | `FixLocationAssignmentRepository` | killed (2F) |
| M20 | drop `REPLENISHMENT` from lookup override | `LookupController` | killed (2F) |
| M21 | drop `requestAmount` method override | `ReplenishController:112` | killed (1F) |
| M22 | header value → `"X-Mutant-Header"` | `Authority:82` | **survived** (100, 0) |
| M23 | (not run — subsumed by M11/M16) | — | — |
| M24 | `functions[0]` → `functions[len-1]` | `AccessService:135` | **survived** (100, 0) |
| M25 | interceptor registration deleted entirely | `WebConfig:35` | **survived** (100, 0) |
| M26 | `@PreAuthorize` removed from `accessAudit` | `AdminActionController:341` | **survived** (132, 0) |
| M27 | seed grants `CANCELLATION` to 1 role not 4 | `UtilRestController` | killed (1F) |
| M28 | `V2.2.18` insert block commented out | `V2.2.18__…sql` | **survived** (87, 0) |
| M29 | `GATED_WORKFLOWS` putaway → wrong function | `AccessAuditService:96` | killed (1F) |
| N2 | `await` dropped on `ensureRolesLoaded` | `require-function.js:24` | killed (1F) |
| N3 | query-param values emptied | `require-function.js:39` | **survived** (170 passed) |
| N4 | ungated early-return removed | `require-function.js:17-19` | killed (1F) |
| N5 | `if (!held.includes(required))` → `if (false)` | `require-function.js:35` | killed (1F) |
| N6 | `if (home.rolesError)` → `if (false)` | `require-function.js:30` | killed (1F) |
| N7 | (not run — subsumed by N5) | — | — |
| N8 | `UNGATED_ROUTES = []` | `menuCatalog.js:100` | **survived** (170 passed) |
| N10 | header key wrong case | `plugins/axios.js:50` | killed (1F) |
| N12 | `403 && body.reason` → `403` | `plugins/axios.js:196` | killed (1F) |
| N13 | `middleware:` entry removed | `nuxt.config.js:12` | **survived** (170 passed) |
| N14 | `ensureRolesLoaded` → no-op | `store/home.js:135` | **survived** (170 passed) |
| N15 | success path sets `rolesError: true` | `store/home.js:157` | **survived** (170 passed) |
| N16 | `pageList` → `[]` | `store/home.js:180` | **survived** (170 passed) |
| N17 | menu role → bogus constant | `menuCatalog.js:47` | **survived** (170 passed) |

Also attempted and discarded: M10/M11/M12/M16/M21 first passes failed to apply at all (perl
brace-delimiter and modifier errors, reported as `MUTATION DID NOT APPLY`), and were re-run through a
python exact-literal harness. A non-applying mutation was never scored.

**Totals: 22 killed, 15 survived, 2 null mutants correctly surviving, 6 positive controls all
behaving as expected.**

## Shape of the result

The interceptor's *decision logic* is genuinely well covered and mutation-resistant — resolution by
declaring class, method-over-class precedence, the header, the CORS-safe write, the metric tags, the
three denial reasons, the ANY-of semantics, the Replenish split and the SDR un-export all have tests
with real teeth.

Every survivor is a **wiring** point rather than a logic point: Spring interceptor registration,
Nuxt middleware registration, the `GUARDED` set, the startup assertion's production call and its
throw, the migration's content, the audit endpoint's `@PreAuthorize`, the header literal, and the
entire mobile Vuex action. Two of those files are provably outside the test suite altogether (C5,
C6). The one exception to "wiring, not logic" is finding 3 — fail-closed — which is a logic branch
the design deliberately made unreachable from tests, and it is the single highest-value fix here.
