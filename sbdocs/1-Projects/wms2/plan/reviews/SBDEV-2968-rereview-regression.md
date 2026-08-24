# SBDEV-2968 Re-review — Regressions & Contract Breaks

status: complete — 2 High, 1 Medium, 5 Low. Verdict at the end.

Reviewer lane: `rereview-regression` (independent). Scope: the three review-fix commits only
(`dde7953`, `fa28026` in `wms2-api`; `1dfdb30` in `wms2-mobile-ui`).

Findings are appended below as they are established. Each is severity-rated and marked
**proved by execution** or **reasoned**.

---

## Findings


### F1 — HIGH · The 403 denial body ships NESTED in production; §14.19's refutation used the wrong mapper, and the mobile toast never fires

**Proved by execution** (serialisation) + **reasoned** (bean resolution).

§14.19 re-graded the "403 body shape" finding from High to *Medium, test fidelity* on the ground that
"Production injects Spring's [`Jackson2ObjectMapperBuilder`-built mapper], so **rendering works and the High
is REFUTED**". That premise is false for this application.

`v2/wms2-api/src/main/java/net/aim_ai/wms/WebConfigurer.java:72-83`

```java
@Bean
@Primary
public ObjectMapper objectMapper() {
    ObjectMapper mapper = new ObjectMapper();      // <-- plain; no ProblemDetailJacksonMixin
    ...
}
```

Spring Boot's own `ObjectMapper` bean (`JacksonAutoConfiguration.JacksonObjectMapperConfiguration`) is
`@ConditionalOnMissingBean`, so it backs off entirely once this bean exists. The only other candidate,
`StartApplication.repositoryPopulator()` (`StartApplication.java:73`), returns `WmsObjectMapper.standard()`
which is *also* a bare `new ObjectMapper()` (`util/WmsObjectMapper.java:38`). `@Primary` resolves
`FunctionGuardInterceptor`'s constructor parameter (`FunctionGuardInterceptor.java:95`) to the
`WebConfigurer` one. **Neither candidate carries the mixin, so there is no configuration of this app in
which the flattened shape is produced.**

Measured on the exact jars this branch resolves (spring-web 6.2.15, jackson-databind 2.19.4, Java 21),
replaying `WebConfigurer.objectMapper()`'s configuration verbatim:

```
WEBCONFIGURER-PRIMARY : {"type":"about:blank","title":"Forbidden","status":403,
                         "properties":{"requiredFunction":"MOBILE_UI_VIEW_CYCLE_COUNT",
                                       "reason":"MISSING_FUNCTION"}}
Jackson2ObjectMapperBuilder (for contrast) : {"type":"about:blank","title":"Forbidden","status":403,
                         "requiredFunction":"MOBILE_UI_VIEW_CYCLE_COUNT","reason":"MISSING_FUNCTION"}
```

Consumer: `wms2-mobile-ui/plugins/axios.js:196-198`

```js
const body = (error && error.response && error.response.data) || {}
if (status === 403 && body.reason) {
  app.$toast.error(authzDenialMessage(body))
}
```

`body.reason` is `undefined` against the nested shape, so **no toast fires on any server-side denial** — the
precise silent failure the code comment three lines above warns about ("the gate would work and the operator
would see nothing"). `authzDenialMessage`'s three-way branch is dead in production.

**Concrete scenario.** Operator lacking `MOBILE_UI_VIEW_PICKING` hits any `/v3/picking/**` handler (stale tab,
back button, or — see F2 — a cold start where the client guard now declines to decide). Server 403s correctly,
`X-Authz-Denied` suppresses the retry, and the screen shows *nothing at all*: no toast, no message, no reason.
Support gets "the handheld does nothing when I press Pick", which is unanswerable without server logs.

**Why the test cannot see it** — `FunctionGuardInterceptorUnitTest.java:64` and
`FunctionGuardMockMvcUnitTest.java:85` both construct the interceptor with `new ObjectMapper()`, and the only
body assertion is `FunctionGuardInterceptorUnitTest.java:118-121`:
`assertThat(response.getContentAsString()).contains("MOBILE_UI_VIEW_CYCLE_COUNT").contains("MISSING_FUNCTION")`.
Both substrings are present in **both** shapes, so the assertion is blind to the axis that decides whether the
operator sees a message. Answering the lead's question directly: **no, a `.contains(...)` pair is not adequate
for a security-response contract** — it pins that the two tokens appear *somewhere*, not that the client's
accessor path resolves. Even had the mapper been the flattened one, the test would still have been the wrong
shape; the mapper defect just turns a fidelity gap into a live production defect.

**Fix is one line** — the interceptor should not depend on which mapper it is handed. Either write the map
explicitly, or (better) let Spring render the `ProblemDetail` and stop hand-serialising. A regression test must
assert `objectMapper.readTree(body).get("reason")` is non-null, i.e. key on the **path**, not on a substring —
and must be run against the injected `@Primary` bean's configuration, not a bare `new ObjectMapper()`.

### F2 — MEDIUM · `fa28026`'s step-1 guard converts a loud migration failure into a silent total lockout of the workflow it seeds

**Reasoned** (the divergent state is measured absent on all reachable tenants, so it cannot be reproduced today).

`V2.2.18__seed_mobile_workflow_functions.sql:38-41` — the new guard:

```sql
WHERE NOT EXISTS (
        SELECT 1 FROM mywms_function e
        WHERE e.function = f.name
           OR e.name     = f.name);
```

Steps 2 and 3 of the same file resolve the function they grant **by `name`, not by `function`**
(`:53-54`, `:79`, `:89`), and the runtime gate resolves it by `name` too —
`UserRepository.getAllRoles` is `SELECT DISTINCT f.name … JOIN mywms_function f`
(`repo/jpa/UserRepository.java:27-34`), consumed as a string `contains` in
`AccessService.checkAnyAccess:145`.

So take the exact state the new guard was written for: a tenant holding
`mywms_function(function='MOBILE_UI_VIEW_REPLENISH_REQUEST', name=NULL or a legacy display name)`.

| | before `fa28026` | after `fa28026` |
|---|---|---|
| step 1 | inserts → `23505` on `UNIQUE (function)` → **whole file rolls back**, tenant frozen at V2.2.17 | guard matches on `function` → **skips**, statement succeeds |
| step 2 | not reached | `CROSS JOIN (SELECT id … WHERE name='MOBILE_UI_VIEW_REPLENISH_REQUEST')` → **0 rows** → no grants |
| step 3 | not reached | same, for `MOBILE_UI_VIEW_CANCELLATION` → no grants |
| Flyway | fails (visible in `flyway_schema_history`, and `plan-state.sh`/the runbook look there) | **succeeds** |
| runtime | function absent, but the gate is also absent (V2.2.18 never ran) → prior behaviour | interceptor requires the function, `getAllRoles` never returns that `name` for anyone → **every user on that tenant is 403'd out of replenish-request / cancellation, permanently** |

The fix removed a *detectable* failure and left an *undetectable* one. A frozen chain is what the Flyway
runbook and `plan-state.sh` are built to surface; "migration green, one workflow dead for everyone" surfaces
only as operator tickets.

**Not a blocker on today's data** — §14.20/§14.21 measured `name = number = function` with zero NULLs across
all five reachable tenants plus prd, so the divergent row does not exist. It is a Medium because the guard's
whole purpose is the case it now handles worse, and because nothing in the file or the tests marks the
inconsistency.

**Fix:** make the file resolve on one column throughout. Guard on `function` (the unique one) and key steps
2/3 on `function` as well, or `COALESCE(name, function)`. Then a divergent-name tenant still receives its
grants. A `SELECT`-only pre-check on each tenant (as §14.20 already did) is not a substitute — it proves
today's data, not the guard.

**`SELECT DISTINCT` (the other half of fix 4) is correct and harmless**: `DISTINCT` over
`(rf.rolelist_id, req.id)` where `req` is a single-row subquery cannot drop a wanted row, and the
`NOT EXISTS` anti-join is unchanged. No finding.

### F3 — HIGH · `1dfdb30` silently changes what "back to main" does at 24 existing call sites, and stops the `vuex-mobile` blob being cleared on every workflow exit

**Proved by execution** for the pre-state (git archaeology on the merge base) + **reasoned** for the effect.
Nothing in the 182-test suite touches `refreshMenus`; `grep -rn refreshMenus test/` returns nothing.

`store/home.js:225-233` is unchanged by this commit:

```js
async refreshMenus(context) {
  context.commit('setPageList', [])
  if (context.rootState.home.profile.username)
    context.dispatch('setMenus', { username: context.rootState.home.profile.username })
  else {
    this.$router.push('/')
    this.$kc.logout()
  }
}
```

On the merge base (`7f83d55`) **`home.profile` could never be populated** — `git grep setProfile` at that commit
returns exactly two hits, the mutation definition (`store/home.js:13`) and a commented-out line in
`layouts/no-tenant.vue:30` naming a *different* module. So the `if` was always false and **every**
`refreshMenus` dispatch took the `else`.

`1dfdb30` adds `this.$store.commit('home/setProfile', profile)` at `pages/index.vue:111`. The `if` is now
true, and the `else` never runs again.

**24 existing call sites** dispatch this — `components/{picking,palletizing,putaway,lookup,cancellation,
cycleCount,moveStock,moveUnitload,truckLoading,transferOrder,replenish}/…` plus `pages/replenish.vue`, all
from a `backToMain()` / `goMain()` handler (e.g. `components/picking/scanSection.vue:47`,
`components/lookup/search.vue:41`). Their behaviour changes wholesale:

| | before `1dfdb30` | after |
|---|---|---|
| `$kc.logout()` | ran | never runs |
| `clearPersistedSession()` (inside it) | ran → **`localStorage.removeItem('vuex-mobile')`** (`plugins/keycloak.client.js:60-64`) | never runs |
| navigation | `window.location.replace(origin + '/mobile')` — a **full page reload**, because `logout()` nulls `state.keycloakInstance` *before* `state.keycloakInstance?.logout(...)`, so the `\|\|` fallback fires (`keycloak.client.js:104-110`) | in-SPA `$router.push('/')` |
| network | none | a new `GET /user/getAllRoles/{username}` on every exit, ×24 sites |

**The load-bearing loss is `clearPersistedSession()`.** Its own javadoc, `keycloak.client.js:40-54`, states
the hazard verbatim: handhelds are *shared between shifts*, every workflow module persists a `process` step
marker plus its working set, and **"five of the ten workflow pages (cancellation, cycle-count, move-stock,
move-unitload, transfer-order) read `state.<module>.process` straight out of the blob with no reset on entry,
so the next operator can land part-way through the previous operator's job."** Until this commit, pressing
"back to main" from *any* workflow wiped that blob. It no longer does.

**Concrete scenario.** Operator A works a cycle count to `process = '2_count'` with `countData` populated and
presses Back to Main. Pre-fix: blob wiped, page reloaded, clean. Post-fix: blob retained. Operator B picks up
the handheld, taps Cycle Count, and lands mid-count on A's unit load with A's counts pre-filled. This is the
exact defect class of SBDEV-2554 and SBDEV-2930 and it is re-opened as a side effect of a one-line
`setProfile` commit whose stated purpose was to fix a *computed property*.

**Also unexamined:** the same commit makes `home.profile` (username, name, firstName, groups) a **newly
persisted** value, because `plugins/persistedState.client.js` strips only `functions`/`rolesLoaded`/
`rolesError` from `home`. So on a shared handheld the blob now carries the previous operator's identity, and
`resolvePrincipal` (`store/home.js:28-33`) falls back to `rootState.home.profile.username` — a test pins that
fallback (`test/store/home.spec.js:84`). The exposure is bounded (with no live token the subsequent
`getAllRoles` 401s into `rolesError`, so the outcome is a misleading `/unhealthy-tenant?reason=roles` rather
than a wrong grant), which is why it is folded in here rather than raised separately — but it is the
**fourth** instance of the persisted-blob class in a commit whose own message calls it "the third bug of this
class on this blob".

**Fix:** either restore the clear explicitly at the workflow-exit boundary (`refreshMenus` should commit a
reset, not rely on a logout side effect), or land the per-page reset for the five named pages first. Add a
`test/store/refreshMenus.spec.js` asserting which branch runs and that the exit clears workflow state. Strip
`profile` from the persisted blob alongside the three authz keys, or drop the store-profile fallback in
`resolvePrincipal` now that the token is read directly.

### F4 — LOW · `X-Authz-Denied` end to end, and the one denial that emits no header

**Proved by execution** (code inspection + the dedup unit tests, which pass); exposure itself is **not**
verifiable here.

Answering the lead's three checks:

1. **Emission.** `FunctionGuardInterceptor.deny()` (`FunctionGuardInterceptor.java:164-171`) sets the status,
   the content type and `Authority.AUTHZ_DENIED_HEADER` and then writes the body. **It calls neither
   `response.reset()` nor `resetBuffer()` — there is no reset at all**, which is the correct answer to the
   known trap: nothing can strip the CORS headers the filter already wrote. The regression test for it,
   `FunctionGuardInterceptorUnitTest.java:125-140`, pre-sets `Access-Control-Allow-Origin` and asserts it
   survives. Good as far as it goes.
2. **Exactly once in CORS.** `SecurityConfiguration.java:184-195` re-reads `configuration.getExposedHeaders()`
   after the SBDEV-2632 add and guards with `contains(...)` before `addExposedHeader`, so the header is listed
   once whether or not `rest.security.cors.exposed-headers` supplies it. `application.properties:106` supplies
   only `X-Export-Skipped-Cycle-Counts` today, so the programmatic add is the sole source. Both directions are
   pinned by `SecurityConfigurationTest.corsConfigurationSource_doesNotDuplicateAuthzDeniedHeader…` and
   `…_whenPropertyAbsent`, and the pre-existing assertion was correctly widened from `containsExactly` to
   `containsExactlyInAnyOrder` rather than relaxed to `contains`.
3. **Consumption.** `plugins/axios.js:49-52` checks both `headers['x-authz-denied']` and the mixed-case
   spelling and returns `false` from `shouldRetry`, before the auth-ready await. Correct.

⚠️ **Exposure is NOT verified and I am not claiming it is.** Every assertion above reads a
`CorsConfiguration` object or a `MockHttpServletResponse`; MockMvc installs no `CorsFilter`, and neither
`curl` nor the DevTools Network panel can observe header *exposure* either — only JS `headers.get()` in a
browser discriminates. **Browser evidence is still owed** (the plan's M23).

**The finding (Low):** `deny()` emits the header only `if (decision.requiredFunction() != null)`
(`FunctionGuardInterceptor.java:166`). The fail-closed path at `:123` passes
`AccessDecision.deny(Reason.MISSING_FUNCTION, null)` — an unannotated handler on a guarded controller — so
**that denial carries no `X-Authz-Denied`**, and `plugins/axios.js` therefore treats it as a possible
stale-token 403: refresh, retry, deny again. Bounded by `handleMaxRetryTimesExceeded` needing
`retryCount >= retries` (§14.19 cleared the logout), so the cost is a wasted refresh + retry, not a logout.
Pre-existing to `efe0c6e`, not introduced by the three commits, and only reachable via a future unannotated
handler. Emitting the header unconditionally (with the reason when the function is unknown) closes it.

### F5 — LOW/MEDIUM · The verify script reproduces 129/0/2, but four of its rows cannot fail, including the whole A20 cluster the last review demanded

**All of the following proved by execution** — mutants applied to an isolated rsync copy of the worktree,
`PROJECT_ROOT` pointed at a symlink shadow root (`shadow/v2/{wms2-api,wms2-mobile-ui}`; the script is
mono-rooted, `PROJECT_ROOT` must contain `v2/…`).

**Baseline reproduced: `Result: 129 pass, 0 fail, 2 skip`**, both against the live worktrees and against a
clean rsync copy of `fa28026`. Matches §14.20 exactly. The classes of defect the lead named are mostly absent
by construction: no `perl -0777` helper anywhere (the file documents the fail-open memory and hardened every
helper with `[ -f "$2" ] || return 1`), no unbounded `.*?` gaps, and **no `mvn`/`yarn`/`jest` row at all**
(`grep -n 'perl\|mvn\|yarn\|jest'` → one comment hit), so the `mvn_test_passes` permanently-red class cannot
occur here.

What I did find:

**(a) The entire A20 cluster survives switching the feature off.** Mutant: `WebConfig.java:35` →
`.addPathPatterns("/**").excludePathPatterns("/**")` — the gate registered and inert, which is the exact
headline defect of §14.19.

```
--- verify against the mutant ---
Result: 129 pass, 0 fail, 2 skip
```

`A20a` greps for the literal `addPathPatterns("/**")`, which the mutant retains. `A20b/c/d` are
`file_exists` and `file_contains 'MappedInterceptor'` / `'containsExactlyInAnyOrderElementsOf'` — spelling
assertions about a test file, not evidence that any test runs. Second mutant, gutting every assertion in
`FunctionGuardWiringUnitTest` (7 × `assertThat(` → `if (false) …assertThat(`) while leaving the greppable
symbols in place: **A20, A20a, A20b, A20c, A20d all still PASS, 129/0/2.**

✅ **The gate itself is fine — `dde7953` does what it claims.** I ran the wiring test against the
`excludePathPatterns` mutant and it **kills it**, with the right diagnosis:

```
FunctionGuardWiringUnitTest$Registration.guardMatchesAGuardedPath:107
  [the interceptor is registered but its path pattern does not match a guarded endpoint —
   the gate is installed and inert, which is indistinguishable from absent at runtime]
FunctionGuardWiringUnitTest$Registration.guardMatchesAnArbitraryPath:117
  [registration must be path-agnostic so gating survives a @RequestMapping change]
Tests run: 6, Failures: 2
```

So the review's item 1 is genuinely closed. The finding is narrower and worth stating precisely: **"129 pass,
0 fail" is a statement about file contents, not about behaviour**, and the A20 rows in particular do not carry
the guarantee their descriptions claim ("... and a test PINS the registration behaviourally"). The verify
script cannot be the evidence for item 1; the suite run is. Grade **Low** for the script, given the test does
its job.

**(b) `R4` cannot fail.** `verify-…sh:290` — `file_contains 'SET 4b' "$API/…/audit-access-invariants.sql"`.
`SET 4b` occurs at three places in that file: `:14` and `:72` are **prose comments**, `:134` is a `\echo`
label. Mutant: delete the entire SET 4b block (`awk 'NR<134 || NR>195'`, removing the `\echo` and the whole
CTE chain):

```
  PASS  R4          ... and keeps the full roster as SET 4b
Result: 129 pass, 0 fail, 2 skip
```

This is the "positive grep satisfied by a comment" mirror of the class the script's own header warns about
(and hardened only for *negative* assertions, via `file_not_contains_code`). Fix: key R4 on something only
the query has, e.g. `FROM \(SELECT DISTINCT user_id, username FROM projected_held\)` counted `-ge 2`, or grep
for the `\echo` line specifically. Grade **Low** — R3/R5/R6 all resolve to real SQL (`:131`, `:102`/`:165`,
`:106`/`:169`), and R1/R2 to real SQL (`:40`, `:51`), so R4 is the only weak one of the six.

**(c) `A21` cannot fail for the thing that matters, and I caught the mutant live.** `A21` is
`file_exists "$SRC/security/FunctionGuardStartupAssertion.java"`. Mutant: remove `@Component` from that class
— the boot assertion never becomes a bean and never runs in production:

```
  PASS  A21       Startup assertion class exists
  PASS  H8        startup-assertion unit test exists
Result: 129 pass, 0 fail, 2 skip
```

This is the M9 hole §14.19 already lists as unkillable and defers to item 5, so it is not a new finding — but
it is now measured on the verify side too, and it is the same shape as (a): the class exists, the test exists,
nothing asserts the wiring. Grade **Low**, folded into item 5.

**(d) `R1`'s description is a live command substitution.** `verify-…sh:287`:

```bash
run R1 "V2.2.18 guards on `function`, the UNIQUE column"  file_contains …
```

Backticks inside a double-quoted string are command substitution, and `function` alone is a bash reserved
word, so every run emits two errors on stderr and prints the row with the word missing:

```
…verify-…sh: command substitution: line 287: syntax error near unexpected token `newline'
…verify-…sh: command substitution: line 287: `function'
  PASS  R1        V2.2.18 guards on , the UNIQUE column
```

Cosmetic for the verdict (the assertion itself is correct and does grade real SQL), but it is stderr noise in
a CI log where a real error is what you are scanning for. Fix: single-quote the description or escape the
backticks. Grade **Low**.

### Suites — measured, zero delta from the documented baseline

**Proved by execution.**

| Repo | Result | Baseline | Delta |
|---|---|---|---|
| `wms2-api` @ `fa28026` | `Tests run: 5280, Failures: 2, Errors: 0, Skipped: 67` | 2 known pre-existing on `develop` | **0** |
| `wms2-mobile-ui` @ `1dfdb30` | `Test Suites: 16 passed, 16 total · Tests: 182 passed, 182 total` | ~182 expected | **0** |

The two API failures are the known pair, named for the record:
`OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses:43` (6 pre-existing `Optional.get()` violations
in `PickLineRealignmentService`, `ReplenishGeneratorService`, `UnitloadBusinessService`,
`MobileReplenishService`) and
`MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate:468`. Neither is on this
branch's diff. Mobile: 16/16 suites green — no suite-level red of the kind `wms2-web-ui`'s develop carries, so
the suite count is trustworthy here as well as the test count.

Toolchain: `mvn` needed SDKMAN (`maven/current` + `java/21.0.11-ms`); the mobile repo has no `yarn` on PATH,
run via nvm node 24.15.0 + `node_modules/.bin/jest`. Both tools verified present before believing any red.

⚠️ **Process warning for the lead — my first API run was garbage and it looked like real work.** Run 1, in the
live worktree, reported `5280 tests, 13 failures, 4 errors`: ArchUnit rules "failed to check any classes",
`NoClassDefFound net/aim_ai/wms/Authority`, `messages.properties must exist on the classpath`. Cause: another
lane was running `mvn` in **the same worktree** at the same time (`ps` showed a live surefire JVM;
`target/classes` held resources but **zero** `.class` files). Every one of those 17 reds is a credible-looking
"work not done". I re-ran from an rsync copy in the scratchpad and got the clean 5280/2. **Two lanes must not
share a Maven worktree** — and the live worktree currently also carries an uncommitted mutant from another
lane (`FunctionGuardStartupAssertion.java`, `@Component` removed), so anything graded against it right now is
grading a mutant. My suite numbers and my clean-tree verify run both come from the isolated copy at
`HEAD == fa28026`.

### Q1 answered — no, the three commits do not widen the surface, and the premise in the brief is off

**Proved by execution** (`git diff --name-status`, `git log -- <path>`).

The three commits touch **7 files** and nothing else:

- `dde7953` — `src/test/java/…/unit/security/FunctionGuardWiringUnitTest.java` **(added, test-only)**. No
  production file. Cannot change any caller's behaviour.
- `fa28026` — `src/main/resources/db/audit-access-invariants.sql` and
  `src/main/resources/db/migration/V2.2.18__seed_mobile_workflow_functions.sql`.
- `1dfdb30` — `middleware/require-function.js`, `pages/index.vue`, `plugins/persistedState.client.js`,
  `store/home.js` (+ two spec files).

**Correction to the brief:** `fa28026` did **not** touch `FixLocationAssignmentRepository`, and `dde7953` did
**not** touch `WebConfig` or `SecurityConfiguration`. `git log <path>` puts all three in **`efe0c6e`**, the WIP
commit the earlier review already covered. I re-verified the two things that clearance rested on anyway:

- `audit-access-invariants.sql` is at `classpath:db/`, while `StartupFlywayMigrator` scans only
  `classpath:db/migration` (`:61`) and the file carries no `V`/`R` prefix — **it is never executed by the
  application**, so `fa28026`'s 142 changed lines there cannot reach any caller. Confirmed by config, not
  assumed.
- `findByAssignedlocationId` (`exported = false`, from `efe0c6e`) has **no caller outside the mobile UI**.
  Independent grep across `v2/wms2-web-ui`, `v2/omsv2-UI`, `v2/oms-laravel-api`, `v1/wms-{web,mobile}-ui`:
  the only HTTP call site is `wms2-mobile-ui/components/replenish/shared/OrderHeaderBlock.vue:92`, which this
  branch migrates to `ReplenishController#fixedLocationUpperBound`. `v1/wms-mobile-ui` has the same line but
  calls v1. Confirms the earlier review's "zero web-UI callers" independently. The HAL root `_links` listing
  does lose that entry, which is a real contract narrowing for any unknown external consumer — unverifiable
  from here, worth one line in the PR body.

**The one place the branch does widen access is not in these commits.** `V2.2.18` step 3 grants
`WEB_UI_VIEW_TRANSFER_ORDER` to `outbound-manager` and `inventory-manager` on every tenant at boot
(`migrate-on-startup=true`, `out-of-order=true`), while the file's own comment records it as held by
`super-admin` **only** on all five reachable tenants. That is a **web-UI-scoped** grant widening shipped
inside a mobile security change. `fa28026` only added the comment; the INSERT is unchanged from `efe0c6e`. It
is harmless today because the web UI enforces nothing, and it becomes live the moment SBDEV-2967 lands.
Flagging for the owner's item-5 privilege-scope decision, not as a finding against these commits — the
migration lane owns the grant sets.

### Q2 answered — re-graded UP, not down

The lead asked me to re-grade the carried-forward Medium. **It is a High, and for a different reason than
either earlier lane found.** The test-fidelity gap is real and is exactly as described — `new ObjectMapper()`
at `FunctionGuardInterceptorUnitTest.java:64` and `FunctionGuardMockMvcUnitTest.java:85`, with `.contains(…)`
assertions that hold under both shapes, so no, that is not adequate for a security-response contract. But the
premise underneath the earlier *refutation* is wrong: this app's `@Primary ObjectMapper` is a bare
`new ObjectMapper()`, so **the nested shape is what production emits**, and the mobile renderer keys on the
flattened one. See **F1**.

### Reviewed and agreed — not findings

- **The client guard now fails OPEN on an unresolved principal** (`middleware/require-function.js:38-40`).
  §14.20 flagged it for this review. I agree it is correct: ordering is sound (`ensureRolesLoaded` is awaited
  at `:24`, `rolesError` redirects at `:30` before the new branch), the server remains authoritative, and
  failing closed here is what produced the lockout. One consequence to state in the PR: failing open means
  *more* requests now reach the server and get 403'd, which makes F1's silent-denial rendering path hotter,
  not cooler.
- **`SELECT DISTINCT`** in `V2.2.18` step 2 — correct and cannot drop a wanted row (F2, last paragraph).
- **`response.reset()` / `resetBuffer()`** — the interceptor calls neither, which is the right answer (F4).
- **`X-Authz-Denied` listed exactly once** in CORS, both directions pinned by tests (F4).
- **Suites** — zero delta from baseline on both repos.

---

## Verdict

**NOT PR-ready. Two new High findings, one of which the previous review explicitly refuted on a false
premise.**

| # | Sev | What | Evidence |
|---|---|---|---|
| **F1** | 🔴 **High** | 403 denial body ships nested under `properties` in production (`@Primary` bare `ObjectMapper`, `WebConfigurer.java:72-83`); `plugins/axios.js:197` keys on `body.reason` → **no message on any denial**. §14.19's refutation used a mapper this app does not have. | proved by execution |
| **F3** | 🔴 **High** | `1dfdb30`'s one-line `setProfile` commit flips `refreshMenus`' branch at **24 existing call sites**, removing the `clearPersistedSession()` that wiped `vuex-mobile` on every workflow exit → shared handhelds retain the previous operator's workflow state. Also newly persists `home.profile`. Untested. | pre-state proved by execution; effect reasoned |
| **F2** | 🟠 Medium | `fa28026`'s `function OR name` guard turns a detectable Flyway failure into a green migration with one workflow dead for every user on a divergent-name tenant; steps 2/3 and the runtime gate all key on `name`. Latent on today's data. | reasoned |
| **F5a** | 🟡 Low | The whole `A20` cluster (5 rows) stays green with the gate switched off, and with every wiring-test assertion gutted. The test itself does kill the mutant — so item 1 is closed, but the verify script is not the evidence. | proved by execution |
| **F5b** | 🟡 Low | `R4` cannot fail: `SET 4b` matches two prose comments; deleting the whole SET 4b query leaves it green. | proved by execution |
| **F5c** | 🟡 Low | `A21` stays green with `@Component` removed from `FunctionGuardStartupAssertion` (= the boot assertion never runs). Same shape as M9, already item 5. | proved by execution |
| **F5d** | 🟡 Low | `verify-…sh:287` — backticks in a double-quoted description execute `function`; two bash errors on stderr every run, word dropped from the row label. | proved by execution |
| **F4** | 🟡 Low | The fail-closed denial (`requiredFunction == null`) emits no `X-Authz-Denied`, so the client burns a token refresh + retry on it. Pre-existing to `efe0c6e`. | reasoned |

**Q1: no widening.** The three commits touch one test file, two SQL files (one never executed by the app), and
four mobile files. `WebConfig`, `SecurityConfiguration` and `FixLocationAssignmentRepository` were all changed
in `efe0c6e`, already reviewed; I re-confirmed the SDR un-export has no caller outside the mobile UI.

**Still owed, unchanged by this review:** browser evidence for CORS exposure of `X-Authz-Denied` (the plan's
M23) — no test, no curl and no DevTools panel can supply it.

**Blocking for a PR:** F1 and F3. F2 should be fixed in the same pass (one-column consistency in the
migration); F5's four rows are cheap and worth doing while the file is open.

status: complete
