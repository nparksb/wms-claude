# SBDEV-2968 re-review — mobile route guard (commit `1dfdb30`)

status: complete — REQUEST CHANGES (1 High, 3 Medium, 5 Low)

Reviewer lane: independent re-review of `wms2-mobile-ui` worktree
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-mobile-ui/SBDEV-2968`,
branch `bugfix/SBDEV-2968-mobile-function-gating`.

Scope: commit `1dfdb30` and the files it touches — `store/home.js`,
`middleware/require-function.js`, `pages/index.vue`,
`plugins/persistedState.client.js`, `test/store/home.spec.js`,
`test/middleware/requireFunction.spec.js`.

Findings appended as established.

---

## Log

### Baseline

- Branch suite: `Test Suites: 16 passed, Tests: 182 passed` (exit 0), run with
  `node node_modules/.bin/jest` under nvm node v24.15.0 from the worktree root.
  Proved by execution.

---

## F1 — HIGH (reasoned, endpoint-proved): the fail-open's stated justification is false. Two of the twelve gated screens drive endpoints the server-side interceptor does not cover, one of them a mutating one.

`middleware/require-function.js:34-40` declines to decide when `rolesLoaded === false`,
and the comment there — repeated verbatim in `store/home.js:172-176`, in the commit
message, and in `test/middleware/requireFunction.spec.js:124-126` — justifies it with
"the server's FunctionGuardInterceptor still enforces every endpoint".

That premise does not hold. `FunctionGuardInterceptor.GUARDED`
(`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-2968/src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:77-88`)
is an explicit set of **eleven mobile controllers**. Everything outside it is allowed
(`:117-119`). The mobile pages do not talk only to those eleven:

| gated route | required function | endpoint it actually drives | covered? |
|---|---|---|---|
| `/move-stock` | `MOBILE_UI_VIEW_STOCK_TRANSFER` | `POST /v3/stockUnit/transferStock` (`store/moveStock.js:189`) | **NO** — `StockUnitController.java:68`, class not in `GUARDED`, no `@RequiresFunction` anywhere in the file |
| `/move-stock` | same | `GET /v3/stockUnit/storageLocationsForStockMovement` (`store/moveStock.js:157`) | **NO** — `StockUnitController.java:567` |
| `/picking` | `MOBILE_UI_VIEW_PICKING` | `GET /v3/section`, `GET /v3/section/search/findByName` (`store/picking.js:388`, `:186`) | **NO** — Spring Data REST (`SectionRepository.java:13`); the interceptor's own javadoc (`:61-63`) states `RepositoryRestHandlerMapping` never reaches it |
| `/picking` | same | `GET /v3/dashboard/orderMonitorViewSummary` (`store/picking.js:244`) | **NO** — `DashboardController.java:24`, not in `GUARDED` |
| `/replenish` | `MOBILE_UI_VIEW_REPLENISHMENT` | `GET /v3/dashboard/replenishMonitorViewSummary` (`pages/replenish.vue:133,153`) | **NO** — same |

`grep -c '@RequiresFunction'` over the whole API branch returns hits in exactly the
eleven mobile controllers (+ the annotation and its two test/assertion sites). Nothing
else in the API is function-gated.

`POST /v3/stockUnit/transferStock` is the *commit* action of Move Stock — it moves real
inventory. So for `/move-stock` the route guard is not "a UX affordance in front of the
real boundary"; on that endpoint it is the **only** function check that exists.

**Concrete failure scenario.** An authenticated operator who does *not* hold
`MOBILE_UI_VIEW_STOCK_TRANSFER` opens `/mobile/move-stock` as a deep link (bookmark,
history entry, shared link) on a handheld where Keycloak init takes longer than
`AUTH_READY_TIMEOUT_MS = 5000` (`store/home.js:14`) — a 5s barrier on warehouse wifi is
not a hypothetical. `awaitAuthReady` resolves on the timeout, `tokenParsed` is still
undefined, `resolvePrincipal` returns null, the action returns without committing,
`rolesLoaded` stays false, and the middleware lets the navigation through. The page then
renders and its requests carry the `kcToken` that `plugins/axios.js` reads out of
localStorage, so `GET /storageLocationsForStockMovement` and `POST /transferStock`
succeed — no function check on either side. The operator completes a stock transfer they
are not entitled to perform.

**Is the deviation still the right call?** Yes on the lockout question — failing closed
here demonstrably locked entitled operators out of every cold-start deep link, and that
is worse. But the deviation is being justified with a claim about server coverage that is
not true, and §3.2-B3's fail-closed text is being overridden on the strength of it.
Two things are needed before this ships:

1. Correct the justification everywhere it appears (4 sites listed above). "The server
   enforces every endpoint" → "the server enforces the eleven mobile controllers; SDR
   endpoints, `DashboardController` and `StockUnitController` are not covered."
2. Close the `StockUnitController` hole, or narrow the fail-open. The cheapest honest fix
   is to annotate the two `StockUnitController` handlers the mobile app calls and add the
   class to `GUARDED` (it extends `AdminController`, so declaring-class resolution already
   handles the 43-alias problem). Failing that, the fail-open should be bounded — retry
   the barrier rather than resolving on timeout, and treat "unresolved after a real
   retry" as a redirect to `/unhealthy-tenant?reason=roles` (an outage page, not a
   denial) rather than a pass-through.

Note this is **not a regression**: before this ticket there was no gating anywhere, so
nothing that was previously blocked is now reachable. It is a defect in the claimed
security posture, and in one named mutating endpoint that the plan's own model says is
covered when it is not.

---

## F2 — MEDIUM (proved by execution): the persisted-blob exclusion protects the WRITE path only. A blob that already holds `rolesLoaded: true` is rehydrated and silences the fetch for the whole session.

`plugins/persistedState.client.js:41-44` filters through `reducer`. In
`vuex-persistedstate@3.2.1` the reducer is applied **only in the `subscriber` write
path**; on install the library does
`store.replaceState(merge(store.state, JSON.parse(localStorage[key])))` on the **raw**
blob (`node_modules/vuex-persistedstate/dist/vuex-persistedstate.es.js`, the
`replaceState(r.overwrite?f:i(n.state,f,…))` call). Nothing filters the read.

Proved by execution with a throwaway probe (since removed; worktree is clean):

```
localStorage['vuex-mobile'] = {"home":{"functions":["MOBILE_UI_VIEW_INFO"],"rolesLoaded":true,"rolesError":false}}
persistedState({ store })
→ AFTER-INSTALL home = {"page":0,…,"functions":["MOBILE_UI_VIEW_INFO"],"rolesLoaded":true,"rolesError":false}
await store.dispatch('home/ensureRolesLoaded')   // token principal 'entitled-op' available
→ calls= 0   functions= ["MOBILE_UI_VIEW_INFO"]
```

Zero HTTP requests, because `store/home.js:161` short-circuits on
`rolesLoaded && !rolesError`. The stale snapshot is then the guard's authority for the
whole session — which is bug 3 of the commit message, unfixed for the first boot after
upgrade. Self-healing only happens on the *next* boot, once some mutation has rewritten
the blob through the new reducer.

Reachability: a "pre-fix blob" exists on any device that ran a build carrying
`ab20df7` (which introduced these three keys and persisted them). Not on develop —
`git grep setProfile origin/develop` and the develop `store/home.js` confirm the keys do
not exist there — so this only bites devices that ran the WIP/dev build. That is why
this is Medium and not High.

**Fix.** This file already has the exact remedy for the identical situation, five lines
below: `:47-51` re-asserts `warehouseTimezone` after install specifically because "browsers
that already hold a pre-fix blob will have just rehydrated a stale" value. Do the same
here — after `createPersistedState(...)(store)`, commit
`home/setRolesLoaded(false)`, `home/setFunctions([])`, `home/setRolesError(false)`.
Cheap, symmetrical with the precedent in the same file, and it makes the strip correct in
both directions.

⚠ Do **not** reach for a blanket `localStorage.removeItem('vuex-mobile')` or a wholesale
`replaceState` here: `picking.timer` lives in this same blob and is a live `setInterval`
handle — clearing it blindly can kill Keycloak's token refresh (the SBDEV-2930 landmine).
Commit the three specific mutations.

**No test covers this direction.** See F6.

---

## F3 — MEDIUM (proved by execution): `home.profile` is still persisted, and this commit is what makes the profile fallback live. On a shared handheld that can resolve the *previous* operator as the principal.

`stripAuthzState` (`plugins/persistedState.client.js:33-37`) removes `functions`,
`rolesLoaded`, `rolesError` — but **not `profile`**. Before this commit that did not
matter: nothing ever committed `setProfile`, so the fallback in `resolvePrincipal`
(`store/home.js:32`) was always dead. `pages/index.vue:110` now commits it, so it becomes
a persisted, live principal source.

Proved by execution:

```
// probe B
store.commit('home/setProfile', {username:'operator-A'})
→ persisted blob = {"home":{…,"profile":{"username":"operator-A","groups":[]},"pageList":[]}}
// fresh boot, that blob present, $kc.tokenParsed undefined (init timed out / settled unauthenticated)
await store.dispatch('home/ensureRolesLoaded')
→ fetched for = [ '/user/getAllRoles/operator-A' ]
```

And the endpoint it fetches does not check that the path username is the caller:
`UserController.getAllRoles` at
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-2968/src/main/java/net/aim_ai/wms/controller/UserController.java:342-346`
is `userRepository.getAllRoles(username)` with no principal comparison and no
`@RequiresFunction`. So the fetch **succeeds** and the UI is populated with operator A's
grants.

**Concrete failure scenario.** Shared handheld. Operator A finishes a shift and the
device is put on the charger without an explicit logout — `clearPersistedSession()`
(`plugins/keycloak.client.js:60-64`) runs only on the façade `logout`, the internal
auto-logout, and `onAuthLogout`, so `vuex-mobile` and `kcToken` survive. Operator B picks
it up and opens a bookmarked `/mobile/move-stock`. Keycloak `check-sso` init takes longer
than the 5s barrier; `tokenParsed` is undefined, so `resolvePrincipal` falls through to
the persisted `profile.username` = `operator-A`, the request goes out carrying A's still-valid
`kcToken` from localStorage (`plugins/axios.js:132-133`), returns **A's** function list,
and `rolesLoaded` is committed `true` — cached as authoritative for B's whole session.
B gets A's tiles and A's routes. Combined with F1 (`POST /v3/stockUnit/transferStock` is
not server-gated), B can then complete a real stock transfer on A's entitlement.

**Fix.** Add `profile` to `stripAuthzState` — it is derived per boot from the Keycloak
token, exactly like the three keys already stripped, and index.vue re-commits it on the
home path. Note that would make `fallsBackToTheStoreProfileWhenNoTokenIsPresent`
(`test/store/home.spec.js:82`) a test that pins the hazard rather than the contract;
that test should be re-pointed at "an in-memory profile committed this session", or the
store fallback dropped entirely (on a deep link the token is the only valid source, which
is the commit's own argument).

---

## F4 — MEDIUM (proved by execution): committing the profile silently changes the behaviour of 22 components' back-button, and nothing in the plan or the tests mentions it.

`store/home.js:227-233` — `refreshMenus` branches on
`context.rootState.home.profile.username`, and its else branch is
`this.$router.push('/'); this.$kc.logout()`. On `origin/develop` `profile` is never
committed (verified: `git grep setProfile origin/develop` finds only the mutation
definition and a commented-out line pointing at a different module), so that branch was
**always** taken. `refreshMenus` is dispatched from 22 components
(`components/lookup/search.vue:41`, `components/putaway/scanPallet.vue:43`,
`components/picking/scanSection.vue:48`, … — one per workflow's back affordance).

Proved by execution:

```
empty profile   (develop shape) -> logout: 1   push: [ [ '/' ] ]
populated profile (this branch) -> logout: 0   get: [ [ '/user/getAllRoles/op1' ] ]
```

So this commit flips a shipped behaviour on 22 call sites: a back tap that logged the
operator out now refetches the menu and stays in session. That is almost certainly the
*intended* behaviour and a real improvement — but it is an unscoped change riding inside a
commit whose stated subject is the route guard, it has no acceptance criterion, and no
test asserts either shape. Either give it an AC and a test, or split it out. At minimum it
needs a line in the plan and a QA item, because it changes what every workflow's back
button does.

---

## F5 — LOW (proved by execution): the memo-ordering mutant SURVIVES in isolation. The commit's "6 mutants, 6 killed" is not accurate, and the real protection is the `await`, not the ordering.

Applied each claimed-killed revert in turn to the branch and ran the full suite
(`node node_modules/.bin/jest`), reverting between runs:

| mutant | change | result |
|---|---|---|
| M1 | `resolvePrincipal` reads the store profile only (no token) | **killed** — 7 failed / 175 passed |
| M2 | memo cleared in a `finally` inside the IIFE; drop `.then(clear, clear)` | **SURVIVED — 182/182 passed** |
| M3 | drop `await awaitAuthReady(this)` | **killed** — 1 failed / 181 passed |
| M4 | commit `setFunctions([])` + `setRolesLoaded(true)` on unknown principal | **killed** — 2 failed / 180 passed |
| M5 | delete the `if (!home.rolesLoaded) return` pass-through (i.e. deny) | **killed** — 1 failed / 181 passed |
| M6 | reducer keeps the authz state in the blob | **killed** — 1 failed / 181 passed |
| M7 | null mutant (comment only) | survived, as it must — 182/182 |
| M8 = M2+M3 | the true pre-fix shape | **killed** — `retriesAfterANoPrincipalCallInsteadOfPoisoningTheMemo` **and** `awaitsTheAuthReadyBarrierBeforeReadingThePrincipal` both red |

Why M2 survives: the poisoning bug required a **synchronous** completion path through the
IIFE, and `await awaitAuthReady(this)` now guarantees at least one microtask before the
`finally` can run — so with the await in place, `finally`-inside is behaviourally
identical to `.then(clear, clear)`. The ordering fix is therefore inert *given* the
barrier, and no test pins it independently.

Not a live defect, but it changes what the branch is protected against: if anyone later
adds an early return **before** the await (an `if (!app.$kc) return` fast path is the
obvious one), the poisoning bug comes straight back and only `awaitsTheAuthReady…` stands
between it and green. Either keep the current shape and note in §14.20 that the memo
ordering is defence-in-depth rather than an independently-pinned fix, or add a test that
exercises the memo with a synchronous-completion double (`ready: undefined` plus a
`resolvePrincipal` that returns null) so the ordering has its own killer.

---

## F6 — LOW: the persistedState assertion is a source regex plus a re-implemented copy, so it tests the test.

`test/store/home.spec.js:206-228`. Two of the three assertions grep the plugin's *source
text* (`:216-217`); the third — labelled "prove the shape it produces, independently of the
plugin's Nuxt wiring" — declares a **fresh local copy** of `stripAuthzState`
(`:220-224`) and asserts on that. It cannot fail for any change to the plugin.

The source regexes do kill M6, so the strip is pinned — but only textually, and only in
the write direction. This is exactly why F2 was invisible: nothing here ever installs the
plugin against a store, so nothing observes what rehydration does. The probe in F2 is 15
lines and is the test this block should have been; it would also give F2's fix a killer.

Related, milder: `test/middleware/requireFunction.spec.js` still stubs `dispatch`
throughout (`:31-34`). That is now defensible because `home.spec.js` exercises the real
action, but **no test composes the two**, so the guard and the action are only ever
verified against each other's doubles. One integration test — real store module + real
middleware + an `$axios` double — would cover the seam both suites currently mock away.

---

## F7 — LOW: the 5s barrier is both the fail-open trigger and a blocking navigation delay.

`AUTH_READY_TIMEOUT_MS = 5000` (`store/home.js:14`) is awaited **inside** a Nuxt
`router.middleware` (`nuxt.config.js:13` → `middleware/require-function.js:24`), so on a
cold-start deep link with a slow Keycloak init the navigation is blocked for up to five
seconds with nothing rendered, and then falls through to the fail-open. Bounded and
non-wedging, so not a defect — but the same constant governs both the UX stall and the
security-relevant pass-through, and the plan should say which one it was chosen for.

Also: the `setTimeout` inside `awaitAuthReady` (`:19`) is never cleared, so every call
leaves a 5s timer pending even when `ready` wins the race. Harmless in production; it will
hang or mis-time any future suite that installs `jest.useFakeTimers()` around this action.

---

## F8 — LOW: dead fallback branch in `resolvePrincipal`.

`store/home.js:31-32` consults `context.rootState.home.profile` and then
`context.state.profile`. For a namespaced Nuxt module those are the **same object**, so
the second `||` arm is unreachable. Harmless, but it reads as two independent sources and
invites a future reader to trust one of them differently.

---

## F9 — LOW: a provisioned-in-Keycloak / absent-in-`mywms_user` operator is told "not authorized".

`GET /v3/user/getAllRoles/{username}` returns an empty list for a Keycloak identity with
no `mywms_user` row, so the guard sees `rolesLoaded: true, functions: []` and redirects to
`/not-authorized?workflow=…&fn=…`. The server-side interceptor distinguishes this case
explicitly (`FunctionGuardInterceptor.logDenial`, `Reason.USER_NOT_PROVISIONED`, logged at
ERROR as "a provisioning defect, not a permissions question"); the client has no way to
tell, so the operator is sent to their administrator to ask for a function they can never
be granted until someone notices the missing row. Pre-existing shape, newly user-visible
because this guard now acts on it.

---

## Things I checked and found clean

- **Route coverage.** `find pages -name '*.vue'` is exactly 16 files: the 12 MENU
  workflows plus `index`, `not-authorized`, `unhealthy-tenant`, `unknown-tenant`. There is
  no nested route and no flat page that `requiredFunctionFor` leaves ungated by accident,
  so the "any path not in MENU is ungated" fallthrough
  (`util/menuCatalog.js:123`) has no live gap today. It is still a fail-open default worth a
  comment if pages are ever nested.
- **`$kc` really is reachable from a Vuex action.** `plugins/keycloak.client.js:434` uses
  Nuxt `inject`, which decorates the store as well as `Vue.prototype`, and
  `nuxt.config.js:39-47` orders `keycloak.client` before `persistedState.client` and both
  before middleware. `this.$kc` in `ensureRolesLoaded` is not undefined on any gated route.
- **`$kc.ready` really is a promise, not a boolean.** `createEnhancedKeycloak`'s
  `get ready()` returns `state.ready`, the SBDEV-2554 barrier
  (`plugins/keycloak.client.js:22,76-78`). The `if (!ready) return Promise.resolve()`
  short-circuit therefore fires only when the façade is absent — and the only routes where
  the plugin returns without injecting (`/unknown-tenant`, `/error`, `:129-131`) are
  ungated, so the barrier is never skipped on a route that needs it. This was my main
  suspicion going in and it is unfounded.
- **Cold-start interleavings other than the timeout.** Init-succeeds: `settleReady` fires
  after `tokenParsed` is populated (`:261-269`), so the principal is always present when the
  barrier releases — there is no window in which `functions: []` is committed and cached.
  Init-resolves-unauthenticated (`:242-253`) and init-throws (`:292-311`) both settle ready
  and then navigate away, and both clear `kcToken` first, so the fetch 401s into
  `rolesError` → `/unhealthy-tenant` rather than into a false denial.
  `state.isInitializing` re-entry deliberately does not settle ready, so a second plugin
  run cannot release the barrier early.
- **`rolesError` ordering in the guard.** `middleware/require-function.js:30` is checked
  before the new `:38` pass-through, so an outage still routes to `/unhealthy-tenant` and
  is not swallowed by the fail-open.
- **`retriesAfterAFailureRatherThanCachingTheError`** is real: the short-circuit is
  `rolesLoaded && !rolesError`, so a transient failure does retry. Verified by M-run and by
  reading `:161`.
- **The Vue `:key` remount trap** flagged in the brief does not apply — this commit adds no
  `:key` and no `shallowMount` assertion on `$vnode.key`.
- **Baseline is the branch, not a red develop.** The branch is `up-to-date with
  origin/develop` (`merge-base --is-ancestor` true, 2 commits ahead) and the suite is
  16/16 suites, 182/182 tests green, so unlike its `wms2-web-ui` sibling there is no
  pre-existing red to net out.
- **Worktree left clean.** All probe files removed; `git status --porcelain` empty.

---

## Verdict

**REQUEST CHANGES.** The three High defects the previous round found are genuinely fixed
and the fixes are, with one exception, mutation-killed: the principal now comes from the
Keycloak token (M1 killed), the barrier is awaited (M3 killed), an unresolved principal no
longer commits a denial (M4, M5 killed), and the authz keys no longer ride in the written
blob (M6 killed). The cold-start deep link works.

Blocking before merge:

1. **F1 (High)** — the deliberate fail-open is defensible on the lockout argument but is
   justified by a false claim. `POST /v3/stockUnit/transferStock`
   (`StockUnitController.java:68`) is the commit action of a gated screen and carries **no**
   server-side function check; `/v3/section*` (Spring Data REST) and `/v3/dashboard/*` are
   likewise outside `FunctionGuardInterceptor.GUARDED`. Either gate `StockUnitController`
   on the API side or bound the fail-open, and correct the "enforces every endpoint"
   wording in all four places it appears.
2. **F2 (Medium)** — mirror the `warehouseTimezone` self-heal already in the same file so a
   rehydrated pre-fix blob cannot silence the fetch for a session.
3. **F3 (Medium)** — strip `profile` from the persisted blob (or drop the store fallback);
   as it stands the principal can resolve to the previous operator on a shared handheld,
   and `getAllRoles` will serve that operator's grants to anyone.
4. **F4 (Medium)** — give the `refreshMenus` behaviour change an AC and a test, or split it
   out. Twenty-two components change behaviour silently.

F5–F9 are non-blocking, but F5 should be corrected in §14.20 (the memo-ordering mutant
survives in isolation) and F6's probe is worth keeping as a real test since it is what
would have caught F2.

status: complete
