# SBDEV-2968 — review lane: mobile client half

- **Reviewed**: `.claude/worktrees/wms2-mobile-ui/SBDEV-2968` @ `ab20df7` (`bugfix/SBDEV-2968-mobile-function-gating`), 12 files / ~650 insertions vs `origin/develop`.
- **Lens**: mobile client correctness, races, and what an operator actually experiences.
- **Date**: 2026-08-20
- **Not blocked.** Jest ran. Baseline: **15 suites / 170 tests, all pass** — which is itself finding 6.
- **Read-only**: no code edited, nothing staged, nothing committed (`git status --porcelain` empty). This review file is the only file created.
- **Reusable evidence probes** (outside the repo, run against the worktree without touching it):
  `/tmp/claude-1000/-home-nampark-dev-wms-claude/8697cde7-bbc9-40aa-8186-f1423187edab/scratchpad/probe/`
  → `jest.config.js`, `coldstart.spec.js`, `poison.spec.js`, `persist.spec.js`

---

## Direct answers to the five questions

1. **Can the guard decide on a roles list it has not fetched? — YES, and it always does.** `ensureRolesLoaded` can never fetch, because the username it needs is never populated anywhere in the app (finding 1), and its memoised promise is poisoned by its own `finally` (finding 2). On a cold start with an empty store the guard reads `functions: []` and denies. **Loop between `/not-authorized` and itself: NO** — both terminal pages are in `UNGATED_ROUTES` and return before any dispatch.
2. **Is a fetch failure distinguishable from a denial? — In design yes, in practice no.** The `rolesError` branch exists and is correct, but `ensureRolesLoaded` never issues a request, so it can never *set* `rolesError`; the no-principal path returns with `rolesError` false and the guard reports "denied". An outage therefore does reach the operator as a permissions problem — via the empty-list path rather than the path the plan guarded (findings 1, 2, 5).
3. **Does a newly persisted field rehydrate stale and outrank a fresh fetch? — YES.** `functions`, `rolesLoaded`, `rolesError` all ride in the `vuex-mobile` blob, and `rolesLoaded: true` short-circuits the fetch (finding 3, verified by execution).
4. **Can the axios branch swallow a genuine stale-token 403, or still log the operator out? — NO to both.** Ruled out by execution + reading the axios-retry source; details in "Actively ruled out".
5. **Does the 403 ProblemDetail render on the screens that matter? — YES.** The toast fires from the global `onError`, independent of any page's 200-with-`errors` catch; verified by execution. The remaining rendering gap is the *client-side* denial page, which ignores the params the guard passes it (finding 4).

---

## Findings

### 1. High — the guard's roles fallback can never fetch, so a cold-start deep link denies every operator, including a fully entitled one
`middleware/require-function.js:23` + `store/home.js:143-146`
*Established by execution* (`probe/coldstart.spec.js`, tests A and B, real store + real middleware) **and** reading.

`ensureRolesLoaded` derives the principal solely from `home.profile.username`, and **nothing in this app ever commits `home/setProfile`**: `grep -rn setProfile` over the whole repo returns one mutation definition (`store/home.js:28`), one commented-out line (`layouts/no-tenant.vue:30`), and zero writers. `pages/index.vue:100` builds a local `profile` object and drops it on the floor. So the action always takes the `!username` early return, commits nothing, and leaves `rolesError` false — after which the guard reads `functions: []` and treats "never fetched" as "denied". The only thing that ever populates `functions` is `setMenus`, dispatched from `pages/index.vue:194`, i.e. only when the operator passes through `/`.

**Scenario.** A handheld home-screen shortcut (or restored tab, or bookmark) to `/mobile/picking`, first launch of the shift. There is no `vuex-mobile` blob — the previous shift's logout deleted it (`plugins/keycloak.client.js:63`) — and no Keycloak cookie, so `init` returns unauthenticated → `guardedLogin` → `kc.login()` with **no** `redirectUri` (`plugins/kc-redirect-guard.js:37`), which keycloak-js defaults to `window.location.href`. The operator authenticates and returns to `/mobile/picking` with an empty store. The guard redirects to `/not-authorized`, which reads *"You are not authorized for this application."* A picker holding every function reports being locked out of the handheld app. Recovery is tapping the header logo to reach `/`, which no operator will guess.

Probe B reproduces exactly this for an operator whose server-side list *contains* `MOBILE_UI_VIEW_PICKING`.

### 2. High — the memoised `rolesPromise` is permanently poisoned by its own `finally`, so after one early return roles are never fetched again for the life of the page
`store/home.js:148-165`
*Established by execution* (`probe/poison.spec.js`).

On the `!username` path the async IIFE runs to completion **synchronously**, so `finally { rolesPromise = null }` executes *before* the assignment `rolesPromise = (async () => …)()` lands — the null-out is immediately overwritten by the settled promise. Every later call short-circuits at `if (rolesPromise) return rolesPromise`.

Probe: one no-principal call, then three calls with `profile.username = 'op1'` → **zero** HTTP requests issued, `functions` still `[]`.

This survives a fix to finding 1. The principal always arrives late (Keycloak init is async; `pages/index.vue:68-77` polls for it every 500 ms), so the first navigation of any session poisons the memo and no later navigation can recover. It also silently defeats the retry-after-failure behaviour the action's own docblock promises: once poisoned, a `rolesError` state can never be re-attempted.

### 3. High — `functions` / `rolesLoaded` / `rolesError` ride in the `vuex-mobile` localStorage blob, and `rolesLoaded: true` outranks any fresh fetch
`plugins/persistedState.client.js:26-29`, consumed at `store/home.js:135`
*Established by execution* (`probe/persist.spec.js`, real Vuex + real `vuex-persistedstate` + the file's own reducer).

The reducer excludes only `warehouseTimezone` / `selectedWarehouse` / `warehouses` from the **root** state; module state is untouched. The probe prints the actual blob:

```
{"tenantHealth":true,"home":{"page":0,"menus":[],"profile":{},"pageList":[],
 "functions":["MOBILE_UI_VIEW_PICKING"],"rolesLoaded":true,"rolesError":false}}
```

Because `ensureRolesLoaded` returns immediately when `rolesLoaded && !rolesError`, the guard's authority on any hard refresh is a rehydrated snapshot, and (finding 2) nothing re-fetches.

**Scenario a — stale denial (the lockout).** An administrator grants `MOBILE_UI_VIEW_CYCLE_COUNT`. The operator refreshes on a workflow screen; the guard reads the pre-grant list and keeps redirecting to `/not-authorized` even though the API would now allow them, until they happen to navigate to `/`.
**Scenario b — shared handheld.** Operator B re-authenticates through check-sso *without* an intervening logout (logout is the only thing that clears the blob), then deep-links into a workflow: both the tiles (`pageList`, also persisted) and the route decision come from operator A's snapshot. The server still enforces, so this is lockout/confusion rather than privilege escalation — but this is the third time this blob has produced this class of bug (SBDEV-2726 shared key; the stale persisted `warehouseTimezone`), and the persisted field is now load-bearing for an access decision.

### 4. Medium — the denial page ignores the `workflow` and `fn` params the guard is careful to build, and its text describes a whole-app lockout
`pages/not-authorized.vue:1-15` (vs `middleware/require-function.js:34-38`)
*Established by reading* (no `$route.query` anywhere in the page).

`middleware/require-function.js:36` calls both params load-bearing ("the page names the workflow the operator tried to open and the function to ask their administrator for"), and `test/middleware/requireFunction.spec.js` asserts they appear in the redirect URL — but nothing renders them. The template is a fixed *"You are not authorized for this application."*

**Scenario.** An operator holding 11 of 12 functions taps a stale shortcut to `/cycle-count`, sees a whole-application denial, and cannot tell their administrator which workflow was refused or which function to grant — which is §3.1-A7's entire stated reason for routing here rather than to `/`.

### 5. Medium — a transient roles-fetch failure is reported as "Tenant Warehouse Not Configured" and sticks
`middleware/require-function.js:33` → `pages/unhealthy-tenant.vue:8-11`
*Established by reading* + the persistence probe for the stickiness.

The `rolesError` destination shows *"The warehouse you are trying to access is not configured in SiteBoss OWL. Please contact the administrator."* with no retry affordance. `rolesError` is persisted (finding 3) and `ensureRolesLoaded` cannot clear it (findings 1 and 2), so it survives reloads.

**Scenario.** Index loads with a rehydrated `pageList`, so tiles render. `setMenus` fails on one handheld Wi-Fi blip → toast + `rolesError: true`, persisted. The operator taps any tile and is told the warehouse is not configured in SiteBoss OWL — on every tile — until a later visit to `/` happens to succeed. An outage is reported as a provisioning failure, which is the mirror image of the failure mode the branch was added to prevent.

### 6. Medium — `store/home.js` has no test at all; the plan's own `test/store/home.spec.js` is not in the commit
plan line 600 names `ensureRolesLoadedIsIdempotentUnderConcurrentCalls` and `setMenusSetsRolesErrorOnFailure`; `ls test/store/` → only `resetState.spec.js`
*Established by execution and reading.*

Every middleware test injects `{ rolesLoaded: true, functions: […] }` and a stubbed `dispatch`, so the action under review is never executed by the suite. That is precisely why findings 1 and 2 ship with 170/170 green, and why AC-19's `waitsForEnsureRolesLoadedBeforeDeciding` passes while the real `ensureRolesLoaded` does nothing.

### 7. Low — a second, divergent copy of the catalog is still committed on every home-screen mount
`store/home.js:43-118` (`setStaticMenus`), committed at `components/homePage/homePage.vue:52`
*Established by reading.*

Its `/replenish-request` entry still maps to the OLD `MOBILE_UI_VIEW_REPLENISHMENT`. Nothing reads `state.menus` any more, so it is inert today — but it is a live divergent copy of exactly the map `util/menuCatalog.js` was created to unify, no test pins it as dead, and restoring any reader reintroduces the tile/guard disagreement.

### 8. Low — deployment order: `/replenish-request` now requires a function that exists in no live tenant DB
`util/menuCatalog.js:96-101` vs API-side `V2.2.18__seed_mobile_workflow_functions.sql`
*Established by reading both worktrees.*

`MOBILE_UI_VIEW_REPLENISH_REQUEST` is created by the API migration; it is absent on the four UAT tenants and production today. If the mobile bundle reaches a tenant before the migration does — separate repos, separate pipelines, and runtime Flyway skips legacy psql-provisioned DBs and never aborts boot on a per-tenant failure — the Replenish Request tile disappears **and** the route redirects to `/not-authorized` for everyone, with no error surfaced anywhere. There is no client-side fallback to the old function. (The migration's back-compat grant itself is correct; the risk is purely ordering and reachability.)

### 9. Low — the AC-21 layout premise is false, and the page the guard now targets carries the same declaration untouched
`pages/not-authorized.vue:20`, `pages/unhealthy-tenant.vue:21`, `test/pages/notAuthorized.spec.js`
*Established by reading the installed Nuxt template*: `node_modules/@nuxt/vue-app/template/App.js:287` — `if (!layout || !resolvedLayouts['_' + layout]) { layout = 'default' }`.

Nuxt 2 silently falls back to `default` for an unresolvable layout, so the `splash` → `default` change is a runtime no-op and the spec's premise ("the page every denied operator is sent to references a layout that cannot resolve") does not hold. Meanwhile `pages/unhealthy-tenant.vue:21` still declares `layout: "splash"` — and that is the new `?reason=roles` destination. Flagged because the plan records this as a fixed live defect and a later reader will believe it.

---

## Actively ruled out

- **Header casing** *(execution)*: `error.response.headers['x-authz-denied']` works — axios **1.16.1** `AxiosHeaders` stores real XHR headers under normalized lowercase own properties (constructed from a raw header string, the lowercase bracket read returned the value). The mixed-case fallback covers hand-built mocks only, which is harmless.
- **Logout on an authorization denial** *(reading `node_modules/axios-retry/dist/cjs/index.js:195-199`)*: `handleMaxRetryTimesExceeded` fires only when `retryCount >= retries`; returning `false` at attempt 0 leaves `retryCount` at 0, so `onMaxRetryTimesExceeded` — and therefore `$kc.logout()` and the "Application will log out" toast — cannot fire on a denial.
- **Swallowing a genuine stale-token 403**: the server sets `X-Authz-Denied` only on an authorization denial (`FunctionGuardInterceptor.java:169`), so a credential 403 has no header, falls through to `awaitAuthReady` + `updateToken`, and still refreshes. `test/plugins/axios.spec.js#still attempts a refresh for a 403 with no authz header` pins the discriminator.
- **403 ProblemDetail actually rendering** *(execution)*: axios's default `transformResponse` JSON-parses `application/problem+json`; the toast fires from the global `onError`, so it is independent of any page's 200-with-`errors` catch and reaches the operator on every screen. A 200 + `{"errors":[…]}` does not trip it, and a 403 without `reason` correctly does not.
- **`OrderHeaderBlock` single response shape** *(reading the API worktree + executing the axios transform)*: `ReplenishController.fixedLocationUpperBound` returns `ResponseEntity.ok(BigDecimal|null)`; a null body arrives as `''`, which the new `resp === '' → null` branch handles, and `Number.isFinite` rejects anything else. No other v2 caller of the un-exported `findByAssignedlocationId` exists (only `v1/wms-mobile-ui`, which talks to a different API). The sibling SDR read in the same method (`/stockunit/search/getAmountAvailable`, line 69) is deliberately left exported (SBDEV-3017), so the component does not half-break. The component mounts only from `components/replenish/process/*`, i.e. `/replenish`, so its `MOBILE_UI_VIEW_REPLENISHMENT`-gated call can never fire on `/replenish-request`.
- **Redirect loop**: `/`, `/index`, `/not-authorized`, `/unhealthy-tenant`, `/unknown-tenant` are in `UNGATED_ROUTES` and return before any dispatch, so neither denial destination can bounce.
- **Guard coverage**: `pages/` holds exactly the 12 mapped workflow pages plus the 4 ungated ones — no nested or dynamic routes — and `router.middleware` in `nuxt.config.js` is global and does run on the initial SPA navigation. Fail-open for a *future* unmapped page is real but caught by `menuCatalog.spec.js#deriveRouteFunctionMapCoversEveryPageFile`, unless someone also edits that spec's hand-maintained `EXCLUDED` list.
- **Tile/guard divergence**: both now read `util/menuCatalog.MENU` — tiles via `MENU.filter` in `setMenus`, guard via `deriveRouteFunctionMap` — so a rendered tile and an admitted route agree.
- **Cross-workflow function mismatch mid-scan**: `/replenish`'s path through `/lookup/locationByLocationName` is double-gated on `INFO` **or** `REPLENISHMENT` (`LookupController.java:91-93`, AC-14); `/replenish-request` calls only the two `REPLENISH_REQUEST`-gated endpoints; `/dashboard/*`, `/section`, `/stockUnit/*` and `/user/getAllRoles` carry no `@RequiresFunction`. So no page the guard admits hits an endpoint demanding a different function.
- **Concurrent dispatch**: with a principal present, two concurrent calls genuinely do share one in-flight request (the IIFE suspends at the `await` before the assignment completes). The memo defect in finding 2 exists only on the synchronous return paths.
