---
ticket: SBDEV-3183
kind: review
lane: independent code review (single lane, T1)
subject: chore/SBDEV-3183-sdr-shadow-would-deny-log — 61af4b55, d1081231 on origin/develop
reviewed: 2026-10-13
verdict: SHIP IT (with two Low/Medium follow-ups recommended in the same branch)
---

# Review — SHADOW would-deny log line (SBDEV-3183 AC-5)

Read-only review. Maven was not run (a `mvn clean verify` was in flight in the worktree). Everything below is
from `git diff origin/develop..HEAD` plus reads of the surrounding code on that branch, and `git grep` of
`origin/develop` in `wms2-web-ui` and `oms-laravel-api`.

Files reviewed:
- `src/main/java/net/aim_ai/wms/security/SdrFunctionGuard.java` (diff + `evaluate`, `denied`, `currentUsername`)
- `src/test/java/net/aim_ai/wms/unit/security/SdrFunctionGuardUnitTest.java` (diff + setup)
- Context: `FunctionGuardInterceptor.java`, `landlord/config/TenantFilter.java`, `landlord/config/TenantContext.java`,
  `src/main/resources/logback-spring.xml`, `src/main/resources/application.properties`,
  `service/AccessService.java`, `security/SdrGuardMode.java`, `security/SdrFunctionRules.java`

## Summary

| Severity | Count |
|---|---|
| High | 0 |
| Medium | 1 |
| Low | 6 |
| Open questions | 1 |

The change does what it says. It changes no authorization decision, it is null-safe, and the tenant reaches
the line through MDC. The one finding that affects AC-5 directly is **M1**: the line drops `decision.reason()`,
so "user not provisioned in this tenant" and "user lacks the function" print the same text. The most useful
test fix is **L1**: swapping the `label` and `function` arguments does not fail any test.

---

## 1. Correctness: no decision changes, right request, null-safety — PASS

- **No decision changes.** All three call sites change only the `wouldDeny` argument list, and each
  `return` is untouched:
  - row 3: `wouldDeny(SdrVerdict.NO_DOMAIN_TYPE, "index", request); return SdrVerdict.allow(SdrVerdict.NO_DOMAIN_TYPE);`
  - row 6: `wouldDeny(SdrVerdict.NO_DOMAIN_TYPE, "unresolvable", request); return SdrVerdict.allow(...)`
  - row 4: `wouldDeny(label, decision.requiredFunction(), request); return SdrVerdict.allow(label);`

  Each call is still reachable only in the `!mode.enforces()` arm. OFF short-circuits above all three
  (`if (mode == SdrGuardMode.OFF) return SdrVerdict.allow(...)`). ENFORCE_RULED and FAIL_CLOSED take the
  `denied(...)` arm. So the log, like the counter, fires in SHADOW only. The counter's tags are unchanged:
  `functionTag` is the same `function == null ? "none" : function` expression, moved into a local.
- **Right request.** `evaluate(HttpServletRequest request, Class<?> declaring)` has one request in scope, and
  all three sites pass it. `FunctionGuardInterceptor.preHandle` passes its own `request`:
  `sdrReadGuard.evaluate(request, declaring)`.
- **Null-safety.**
  - `currentUsername()` returns `authentication == null ? null : authentication.getName()`. A null goes to
    SLF4J as an argument and prints `'null'`, with no NPE. The interceptor's `Denied` line has the same
    behaviour.
  - `request` is never null on this path.
  - `getMethod()` and `getRequestURI()` are non-null for a real servlet request, including on an ERROR
    dispatch, where they return the method and the error-page path.
  - `function` is null-guarded before use.
  - Note: in row 4, `decision.requiredFunction()` is non-null whenever the rule set is non-empty, because
    `AccessService.checkAnyAccess` sets `required = functions[0]`. So `"none"` is reached only through rows 3
    and 6, and there the function slot holds `"index"` or `"unresolvable"`, never null.

## 2. Does the tenant reach the line? — YES on the live appender, with one caveat (Open Question Q1)

- **The filter runs before the interceptor.** `TenantFilter` is a servlet `Filter` with
  `@Component @Order(Ordered.HIGHEST_PRECEDENCE)`. `FunctionGuardInterceptor` is a `MappedInterceptor`
  (`WebConfig`) and runs inside `DispatcherServlet`, so it runs after the whole servlet filter chain. In the
  filter, `TenantContext.setCurrentTenant(tenantProfile)` executes before `chain.doFilter(...)`, and
  `TenantContext.clear()` runs in the `finally` after it. On a REQUEST dispatch the MDC is therefore set on the
  same thread for the whole of `preHandle`.
- **The MDC value.** `TenantContext.setCurrentTenant` does `MDC.put("tenantId", tenantPrefix + "-" + facilityCode)`.
  That is the routing key form, for example `wh01`-style `first4-facility`, not the raw tenant name. It is
  usable for attribution because it is the same key every other tenant log line carries.
  - `MDC.remove` happens when the profile is null, which is the case when the headers are missing. Such a
    request prints `[]`, but it also cannot authenticate against a tenant realm.
  - No other request-path code clears `tenantId`. The only other MDC writes on the request path are
    `IdempotencyFilter`'s `idempotencyKey` put and remove.
- **Appender patterns.** `logback-spring.xml` has one **active** appender, `CONSOLE`:
  `... %-5level %logger{36} - [%X{tenantId}][%X{idempotencyKey:-}] %msg%n`. The second pattern
  (`[Tenant: %X{tenantId}]`) belongs to a `FILE` appender that is **commented out**, so "both appenders" means
  one live appender. Both patterns do include `tenantId`.
- **No conflict with `application.properties`.** That file sets
  `logging.pattern.console=%clr(%d{...}) %-5level %logger{36} - %msg%n`, which has **no** `%X{tenantId}`. The
  property only takes effect through Boot's default `base.xml`/`console-appender.xml` (`${CONSOLE_LOG_PATTERN}`).
  `logback-spring.xml` declares its own literal pattern, so the property has no effect. Nothing in
  `src/main/resources`, the `Dockerfile` or `.github` sets `logging.config` or `LOGGING_CONFIG`. I could not
  check Portainer stack env, so a stack-level `LOGGING_CONFIG` override is the one way this could be untrue on
  a deployed box. The fastest proof is one grep of a dev container's stdout for `[loca-develop]` (or the
  tenant's equivalent) on any existing net.aim_ai line.
- **Level.** `application.properties` sets `logging.level.root=ERROR` but `logging.level.net.aim_ai=DEBUG`, so a
  WARN from `net.aim_ai.wms.security.SdrFunctionGuard` is emitted.

**Q1 (Open question, Low/LOW confidence): ERROR dispatch.** `TenantFilter` is a plain `Filter`, not a
`OncePerRequestFilter`, and has no explicit `FilterRegistrationBean`. Boot therefore registers it for
`DispatcherType.REQUEST` only. On an ERROR dispatch it does not run, and its `finally` has already cleared the
MDC. If the guard is ever reached on an ERROR dispatch, the line would print `[]` for the tenant and
`getRequestURI()` would return the error-page path, not the original URI. `SdrFunctionGuard`'s row-3 comment
says row 3 "absorbs a MISSING attribute on a {repository}-shaped dispatch, which is the shape of an ERROR
re-dispatch". However, `/error` maps to `BasicErrorController`, which is not an SDR handler, so I believe this
is unreachable in practice. If it is reachable, the symptom is a SHADOW `would deny index ... GET /error` line
with a blank tenant. It would read like reconnaissance of the root index, and it is not. No change requested.
Worth knowing when reading the shadow cycle's output.

## 3. Security / privacy of the line — ACCEPTABLE

- `HttpServletRequest#getRequestURI()` returns the path only. Per the Servlet spec it excludes the query string
  and is **not** URL-decoded. SDR paths on ruled types are `/v3/{repository}`, `/v3/{repository}/{id}`,
  `/v3/{repository}/{id}/{property}` and `/v3/{repository}/search/{search}`, so the line carries a repository
  name, a numeric id and a search-method name.
- Search arguments stay out of the line. That covers `groupName=Backend` on `sysprop/search/findByGroupname`
  and user-typed keywords on `stockrecordView/search/findByKeyword`, both of which are in the query string.
- Because the URI is not decoded, an encoded `%0A` stays literal, and Tomcat rejects raw CR/LF in the request
  line. I see no log-forging vector.
- **Compared with the existing line.** `FunctionGuardInterceptor.logDenial` logs
  `"Denied {} on {} for user '{}' ({})", function, on, username, decision.reason()`. That is the function, the
  controller and resource, the username and the reason, with **no** method and **no** URI. The new line adds
  the method and the path. That is new information in the log, but it is not sensitive information, given the
  path shapes above. The username was already logged.
- Not pinned by a test: see L2.

## 4. Log volume in SHADOW on a busy prd tenant — per-request WARN is right; do not rate-limit

Measured from `origin/develop`:

- **Steady-state would-denies should be close to zero.** Each screen that reads a ruled type over SDR is
  menu-gated on the **same** function as the rule. `wms2-web-ui/pages/admin.vue`:
  - Parameters & Configuration → `WEB_UI_VIEW_SYSTEM_PROPERTY` (rule: `SYSTEM_PROPERTY_VIEW`)
  - User Management → `WEB_UI_VIEW_USER_MANAGEMENT` (rule: `USER_ADMIN_VIEW`)
  - Service Log → `WEB_UI_VIEW_MESSAGES` (rule: `MESSAGES_VIEW`)
  - Stock Unit report → `STOCK_UNIT_RECORD_VIEW`

  The one known cross-gate is the System Management **Overview** sub-tab (`store/admin/mgmt/overview.js`,
  `GET /sysprop/search/findByGroupname`, gated on `WEB_UI_VIEW_IMPORT_DATA`). That is one request per tab open,
  and `SdrFunctionRules` measured 0 IMPORT_DATA-only users on both dev and hydra prd.
- **The login bootstrap was moved off SDR.** `store/index.js` now uses `/user/getAffiliatedGroups`, an MVC
  endpoint, so a login generates no would-deny. The mobile UI hits only MVC `/user/*` endpoints. OMS calls no
  ruled SDR type (`config/wms.php:191`).
- **Fan-out per screen load, if a user did reach a screen without the function** (deep link, stale tab, menu
  bug):
  - User Management: about 3–6 SDR reads across `store/admin/management.js`, `group.js` and `role.js`
    (`/user`, `/userFunction`, `/userGroup/search/findByConnectorFalse`, `/userRole/search/findByConnectorFalse`, ...).
  - Parameters & Configuration: 1–2 (`getParamConfigInfo` → `findByGroupname`, plus `/sysprop/{id}` on row
    open; labels, patterns and settings go through MVC `/system/searchSystemByGroupname/*`).
  - Stock Unit report: one per search or page.

  This is single digits per human action.
- **A scripted caller gets one line per request.** That is the signal you want, since it is the
  reconnaissance case the programme exists to close. It is also exactly the volume the interceptor's existing
  `Denied` WARN will produce for the same caller once the tenant is at ENFORCE_RULED. SHADOW's log volume is
  therefore bounded by ENFORCE's, which the rollout has already accepted.
- **Context.** Prd runs `net.aim_ai=DEBUG`, so a handful of WARNs is noise-floor relative to the existing log.
  Every tenant was measured at `OFF` (2026-09-03), so the line emits nothing until someone flips a tenant.

**Recommendation: keep one WARN per request. Do not deduplicate or rate-limit.**
1. AC-5's finding is "which user, which request". A dedupe keyed on (user, type) throws away the second and
   later URIs, and those are what distinguish "one stale tab" from "a screen fan-out we will 403".
2. A rate limiter adds shared mutable state (a concurrent map, an eviction policy and a tenant dimension) to an
   authorization hot path. This codebase has repeatedly found that kind of state to be where defects live.
3. A kill switch already exists per tenant: setting the `WMS2_SDR_READ_GUARD_MODE` sysprop back to `OFF`
   silences it within a cache TTL.

If a shadow cycle on a real tenant shows more than about 1k lines per hour, revisit with a measured number.
Do not pre-build for it.

## 5. Test quality — sound, with one surviving mutant class

Sound:
- **Appender isolation.** `captureGuardLog()` attaches a fresh `ListAppender` to the `SdrFunctionGuard` logger,
  and every test detaches it in `finally` via `release(appender)`. The attach happens immediately before the
  `try`, with nothing that can throw in between. No leakage across tests.
- **No parallel execution.** The pom has no `parallel` config, so no other test's guard log can interleave.
- **Not vacuous on level.** Plain unit tests do not load `logback-spring.xml`, so logback's default DEBUG root
  applies. If an earlier Spring context in the same fork reconfigured logging, `src/test/resources/application.properties`
  still sets `logging.level.net.aim_ai=DEBUG`. The two negative tests (`isEmpty()`) are therefore not vacuous on
  level, and the positive tests in the same class act as their positive controls.
- **The "would deny" filter does not catch other lines.** It does not match the row-6 `"...resolves to no
  ResourceMetadata..."` WARN or the collision ERROR.
- **Commit 2 is sound.** `meterRegistry` is a fresh `SimpleMeterRegistry` per test (`@BeforeEach`), and
  `buildIndex` runs once under the double-checked lock, so `isEqualTo(1.0)` is exact rather than order-dependent.
  The comment is accurate: `counter(...)` registers the meter, so a tag-only assertion survives a deleted
  `increment()`.

### L1 (Low, HIGH confidence) — swapping the `label` and `function` arguments survives every test

`SdrFunctionGuard.java:352-353`:
```java
LOG.warn("SHADOW: would deny {} on SDR[{}] {} {} for user '{}'",
        functionTag, label, request.getMethod(), request.getRequestURI(), currentUsername());
```
Swap the first two arguments and the output becomes `"would deny UserGroup on SDR[WEB_UI_VIEW_GROUP] ..."`.
- `shadowWouldDenyLogsAttributableLine` asserts `.contains("UserGroup")` and `.contains("WEB_UI_VIEW_GROUP")`
  separately, so it stays green.
- `shadowRootIndexWouldDenyIsLogged` asserts `.contains("index")`, and `SDR[index]` contains that too, so it also
  stays green.

PIT's default operators do not generate argument swaps, which is why PIT reports 55/55 and still misses this.
The cost is real: anyone grepping the shadow cycle output by `SDR[UserGroup]` would find nothing.

**Fix:** assert the whole formatted line in the first test, for example
`.isEqualTo("WARN SHADOW: would deny WEB_UI_VIEW_GROUP on SDR[UserGroup] GET /v3/userGroup/search/findByName for user 'sbtest'")`,
or at minimum `.contains("would deny WEB_UI_VIEW_GROUP on SDR[UserGroup] ")`. In the index test, assert
`.contains("would deny index on SDR[none] GET /v3 ")`.

### L2 (Low, HIGH confidence) — "query string excluded" is not pinned

None of the tests sets a query string, so changing the call to
`getRequestURI() + "?" + getQueryString()`, or to `getRequestURL()`, would not be caught for the query part.
(`getRequestURL()` is caught only incidentally, because of the `http://localhost` prefix.) The query string is
where `groupName=Backend` and user-typed keywords live.

**Fix:** in the first test, call `request.setQueryString("name=secret-probe")` and add
`.doesNotContain("secret-probe")`.

## 6. Comment and javadoc accuracy

### M1 (Medium, HIGH confidence) — the line drops `decision.reason()`, so AC-5 cannot tell a provisioning gap from a missing function

`AccessService.checkAnyAccess` returns three deny reasons, and all three carry the same `requiredFunction`:
```java
return AccessDecision.deny(AccessDecision.Reason.USER_NOT_PROVISIONED, required);
return AccessDecision.deny(AccessDecision.Reason.NO_FUNCTIONS, required);
return AccessDecision.deny(AccessDecision.Reason.MISSING_FUNCTION, required);
```
`wouldDeny(label, decision.requiredFunction(), request)` passes only the function, so all three print the
identical line. The interceptor treats `USER_NOT_PROVISIONED` as a different kind of finding: it logs that one
at **ERROR**, "a provisioning defect, not a permissions question", with the tenant named. Its WARN line also
appends `({reason})`.

For an AC-5 shadow cycle, the action differs per reason:
- `USER_NOT_PROVISIONED` → create the `mywms_user` row in this tenant
- `NO_FUNCTIONS` → assign a group
- `MISSING_FUNCTION` → a grant decision, or an over-gated rule

The line as written cannot tell them apart. It also contradicts the javadoc's own claim that the WARN "matches
the interceptor's Denied line" (see L3).

**Fix (small):** pass the `AccessDecision`, or its reason, into `wouldDeny`. Log
`"SHADOW: would deny {} on SDR[{}] {} {} for user '{}' ({})"` with `decision.reason()` for row 4, and the
literal `SDR_SURFACE_INDEX` / `SDR_UNRESOLVABLE_RESOURCE` for rows 3 and 6. Those are the reasons the enforcing
arm would use there. Add one test assertion on `(MISSING_FUNCTION)`. The counter's tag set stays unchanged, so
there is no Micrometer series split.

### L3 (Low, HIGH confidence) — "WARN matches the interceptor's 'Denied …' line" is only partly true

`FunctionGuardInterceptor.logDenial` logs at **ERROR** for `USER_NOT_PROVISIONED`
(`LOG.error("Denied {} on {}: no mywms_user row for user '{}' in tenant '{}'", ...)`) and at WARN otherwise.
Its WARN also carries the reason, which the shadow line does not. Folding M1's fix in makes the claim nearly
true.

**Fix:** reword to "WARN, the level of the interceptor's MISSING_FUNCTION/NO_FUNCTIONS 'Denied …' line (it uses
ERROR for USER_NOT_PROVISIONED)".

### L4 (Low, MEDIUM confidence) — "nothing scrapes the registry"

- The main javadoc dates the claim: "as of 2026-09-02". That is consistent with the project memory note "wms2
  metrics unscraped — no Prometheus yet". I could not verify it live from here.
- The **test** comment says "nothing scrapes the registry" with **no date**, so it will go stale silently once
  scraping lands.

**Fix:** date the test comment, or point it at the javadoc rather than restating the claim.

### L5 (Low, HIGH confidence) — `SdrGuardMode` javadoc still names only the counter, and its table is wrong on root index (pre-existing)

- `SdrGuardMode.SHADOW` javadoc: "emits {@code wms2.authz.sdr.would_deny} ... only a counter of what would have
  been denied". Now that nothing scrapes that counter, the log line is the operative instrument, and this
  javadoc does not mention it.
- The class table row `SHADOW | evaluate, emit would_deny, allow | allow | allow` says root index → plain
  `allow`. The code emits `would_deny` on root index in SHADOW: row 3 calls `wouldDeny(..., "index", request)`.
  That drift predates this branch, but the branch touches exactly this behaviour.

**Fix:** add "and a WARN line with user + request (SBDEV-3183 AC-5)" to the SHADOW javadoc, and change the
root-index cell to "allow, emit would_deny".

### L6 (Low, MEDIUM confidence) — the function slot carries a pseudo-function on rows 3 and 6

Rows 3 and 6 print `"SHADOW: would deny index on SDR[none] GET /v3 ..."` and
`"would deny unresolvable on SDR[none] ..."`. Read cold, "would deny index" looks like a function named
`index`. This mirrors the counter's existing `function=index` tag convention, so it is consistent, but the log
line is read by humans. M1's fix makes it unambiguous by adding `(SDR_SURFACE_INDEX)`, so no separate change is
needed.

Related, not a defect: row 6 already emits its own WARN (`"...resolves to no ResourceMetadata..."`), so an
unresolvable request in SHADOW produces two WARNs. That is acceptable, because row 6 is unreachable short of a
Spring upgrade.

## Positive observations

- The change is minimal and decision-neutral. The counter's tag expression was hoisted rather than duplicated,
  so the metric series is byte-identical.
- Logging only on the would-deny path, and never on allow or on an enforced denial, is the right call, and
  there are explicit negative tests for both exclusions.
- Relying on MDC for the tenant rather than repeating it in the message is consistent with every other tenant
  line in the codebase. I verified it end to end: `@Order(HIGHEST_PRECEDENCE)` filter → `MDC.put` → interceptor
  inside `DispatcherServlet` → the `%X{tenantId}` CONSOLE pattern.
- `getRequestURI()` was a good choice over `getRequestURL()` or the query string: no host noise, and no search
  arguments.
- Commit 2's comment explains exactly why tag-only assertions are vacuous for Micrometer counters. That is a
  reusable lesson.

## Verdict

**SHIP IT.** There are no High findings, and nothing changes an authorization decision. I recommend folding
**M1**, which adds the reason to the line and is about 5 lines plus one assertion, and **L1/L2**, which tighten
the assertions, into this same branch before the PR. M1 determines whether an AC-5 shadow cycle can tell
"provision this user" from "grant this function". It is not a correctness bug in the code as written.

---

## Re-review of 01b84a9a (2026-10-13)

Scope: `git show 01b84a9a` only. I read the diff and checked it against `AccessDecision`, `FunctionGuardInterceptor`,
the pom and the resolved SLF4J version. Read-only: Maven was not run, because a verify was in flight in the
worktree.

### Disposition of the original findings

| ID | Status | Evidence |
|---|---|---|
| M1 | **Fixed** | `wouldDeny(label, counterFunctionTag, AccessDecision decision, request)` now appends `({})` ← `decision.reason()`. `USER_NOT_PROVISIONED` → `LOG.error`, every other reason → `LOG.warn`. New test `shadowUnprovisionedUserLogsAtErrorWithReason` asserts `"ERROR SHADOW: ... (USER_NOT_PROVISIONED)"`. |
| L1 | **Fixed** | Both log tests use `containsExactly("<full line>")`, so a function/label swap now fails. |
| L2 | **Fixed** | The test sets `request.setQueryString("name=typed-search-term")`, and the exact-line assertion proves the query string is absent. |
| L3 | **Fixed** | The javadoc now says "ERROR for USER_NOT_PROVISIONED ..., WARN otherwise". That matches `FunctionGuardInterceptor.logDenial`. |
| L4 | **Fixed** | The test comment now says "nothing scraped the registry as of 2026-09-02". |
| L5 | **Fixed** | `SdrGuardMode` table: SHADOW root index → "record a would-deny, allow". The SHADOW javadoc names the log line and says "Read the LOG". |
| L6 | **Fixed** | Rows 3 and 6 log `(none)` plus `(SDR_SURFACE_INDEX)` / `(SDR_UNRESOLVABLE_RESOURCE)`. The counter keeps `function=index` / `unresolvable`, and that tag is now pinned in the index test and in the row-6 test. |
| Q1 | Unchanged | No change was requested. |

### 1. `Object[] args` with SLF4J: no pitfall

- **Overload resolution.** The project resolves `slf4j-api` 2.0.17 (`~/.m2`), which has `warn(String, Object)`,
  `warn(String, Object, Object)` and `warn(String, Object...)`. With an `Object[]` argument, both `(String, Object)`
  and `(String, Object...)` are applicable in JLS phase 1, because a varargs method called with an array is
  treated as fixed arity there. `Object[]` is more specific than `Object`, so `warn(String, Object...)` is
  selected and the array is spread as the arguments. It is **not** passed as a single `{}` argument. The
  exact-line test would print `[Ljava.lang.Object;@...` if this were wrong, so it pins the behaviour. The same
  holds for `error`.
- **Throwable-last.** SLF4J or logback treats the last argument as the throwable only if it `instanceof Throwable`.
  The last element is `decision.reason()`, an `AccessDecision.Reason` enum, so it is not extracted. All 6 values
  fill the 6 `{}` placeholders, and nothing is left over or short.
- **Enum rendering.** `AccessDecision.Reason` does not override `toString()`. It has `metricTag()`, but `{}` uses
  `toString()`, so the line prints `MISSING_FUNCTION` and not the metric tag `missing_function`. That is
  consistent with the interceptor's `({})` ← `decision.reason()`, and the test asserts it.
- The array is allocated before the level check, so it is built even if WARN were disabled. This path only runs
  on a would-deny, so the cost is irrelevant.

### 2. Comment and javadoc claims: no false claim found

- **"Levels mirror the interceptor's 'Denied …' line: ERROR for USER_NOT_PROVISIONED ..., WARN otherwise"** —
  true (`FunctionGuardInterceptor.logDenial`).
- **"three ... returned for one function"** — true. `checkAnyAccess` returns `USER_NOT_PROVISIONED`,
  `NO_FUNCTIONS` and `MISSING_FUNCTION`, each with `required = functions[0]`. Its fourth deny,
  `MISSING_FUNCTION, null` for empty `functions`, cannot be reached from SDR, because a present rule is non-empty.
- **"the tenant ... which TenantFilter populates via TenantContext"** — true. This is more precise than before.
- **"counterFunctionTag ... has always been the pseudo-value index / unresolvable; kept unchanged"** — true. The
  row-4 tag is still `decision.requiredFunction()`, which is non-null there, so its `"none"` fallback is
  unchanged in practice.
- **"The log line names the decision's own function ..., which is (none) for those two rows"** — true.
  `AccessDecision.deny(SDR_SURFACE_INDEX / SDR_UNRESOLVABLE_RESOURCE, null)`.
- **`SdrGuardMode` "one log line per request" and "the counter has no user, no request and no tenant tag"** —
  true.
- **Test comment on the unresolvable row: "a mutant feeding the decision's (null -> "none") into the counter
  instead survived until this was pinned"** — plausible. The old test asserted only `count == 1.0`, so a
  `function=none` mutant would have passed. I did not re-run it.

### 3. Did the fix break anything? No

- **Decisions.** All `return`s are byte-identical. The new `AccessDecision.deny(...)` objects on rows 3 and 6
  are built only inside the `!mode.enforces()` arm. They are passed to logging only, never returned, so the
  SHADOW verdict is still `SdrVerdict.allow(...)`.
- **Metric series.** The tag set (`domainType`, `function`) is unchanged and the values are unchanged. Two tests
  now pin that.
- **Null-safety.** `decision` is non-null at all three sites. `decision.reason()` is non-null for every `deny(...)`.
  `requiredFunction()` is null-guarded to `(none)`.
- **Format difference from ENFORCE.** The ENFORCE denial for the same row prints `"(none named: SDR_SURFACE_INDEX)"`,
  while SHADOW prints `"would deny (none) ... (SDR_SURFACE_INDEX)"`. The text differs, but the same reason token
  appears in both, so a grep on the reason finds both. Acceptable.
- **Volume.** USER_NOT_PROVISIONED at ERROR in SHADOW adds an ERROR line that did not exist before. It fires
  only for a Keycloak identity with no `mywms_user` row, which is the same population ENFORCE would already log
  at ERROR. If ERROR-level alerting exists, a shadow cycle could trip it for those users. That is arguably the
  desired outcome, but it is worth a note to whoever flips a tenant to SHADOW. **Note, not a finding.**

### New findings

- **R1 (Low, HIGH confidence): NO_FUNCTIONS is not pinned to WARN.**
  - The level split is tested on two points: `MISSING_FUNCTION` → WARN and `USER_NOT_PROVISIONED` → ERROR.
    `SDR_SURFACE_INDEX` → WARN is pinned by the index test.
  - A mutant that widens the condition to `decision.reason() != Reason.MISSING_FUNCTION && reason.name().startsWith(...)`
    is too contrived to count. The plausible one is `reason == USER_NOT_PROVISIONED || reason == NO_FUNCTIONS`,
    which sends `NO_FUNCTIONS` to ERROR. **It survives**, because no test uses `NO_FUNCTIONS`.
  - Optional fix: add `NO_FUNCTIONS` to the unprovisioned test as a `@ParameterizedTest`
    `(reason, expectedLevel)`, or add a third short test.
  - Cost of the gap: one wrong level on a log line. Not blocking.
- **R2 (Low, style):** the reworded test comment line (`SdrFunctionGuardUnitTest.java:320`) is 127 chars, but the
  file already has lines over 200, and `pom.xml` declares checkstyle without a LineLength gate that has fired on
  this file. No action.

### Re-review verdict

**SHIP IT.** All seven original findings are fixed and correctly pinned. The SLF4J `Object[]` form is safe,
with no varargs misbinding and no throwable-last capture. No comment claim is false, and the fix changes no
decision and no metric series. R1 is optional hardening.

---

## Re-review of 17dd367e (2026-10-13)

Scope: `git show 17dd367e`, which touches only the test file. Read-only; Maven was not run.

- **CsvSource padding: it trims correctly.** The project resolves `junit-jupiter-params` 5.12.2 (pom note at
  `pom.xml:355`, and `~/.m2`). In 5.12.2, `@CsvSource.ignoreLeadingAndTrailingWhitespace` defaults to `true`
  (since 5.8), and unquoted values have always been trimmed.
  - `"NO_FUNCTIONS,         WARN"` → `"NO_FUNCTIONS"` and `"WARN"`.
  - Jupiter's implicit String→enum conversion (`Enum.valueOf`) then yields `AccessDecision.Reason.NO_FUNCTIONS`.
  - `level` is the trimmed `"WARN"` / `"ERROR"`, which equals `ILoggingEvent.getLevel().toString()` as
    concatenated in `wouldDenyLines`.
  - `"(" + reason + ")"` uses `Enum.toString()`, which `Reason` does not override, so it prints the name, matching
    what the production line prints.
- **R1 is closed.** All three `checkAnyAccess` reasons are now pinned to their level. The `NO_FUNCTIONS`→ERROR
  mutant is killed by row 2. That kill was confirmed by the author in a scratch worktree; I did not re-run it.
- **R2 is closed.** The section comment is rewrapped. It now also says "TenantFilter populates via
  TenantContext", which is accurate.
- **Isolation.** JUnit's default per-method lifecycle gives each invocation a fresh instance, so `@BeforeEach`
  rebuilds the mocks, the request and `SimpleMeterRegistry`. No `@TestInstance(PER_CLASS)` is present in the
  test or in `BaseUnitTest`. The appender is still attached and detached in `try`/`finally`.
- **Display name.** `@ParameterizedTest(name = "{0} -> {1}")` names each invocation, and `@DisplayName` names the
  container. That is the standard combination and has no effect on execution.
- **Nothing else wrong.** The diff makes no production change, and the expected strings are built from the same
  parameters, so the assertion cannot become tautological: the format, function, label, URI and user are all
  literals.

### Re-review verdict

**SHIP IT.** No new findings.
