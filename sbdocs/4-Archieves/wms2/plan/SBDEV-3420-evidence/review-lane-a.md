# SBDEV-3420 — independent review, lane A

- **Reviewer:** lane A (did not author the change)
- **Date:** 2026-09-18
- **Under review:** commit `3e39dc53` ("SBDEV-3420: an SDR search parameter that cannot convert is 400, not 500") on top of `92196469` in `.claude/worktrees/wms2-api/SBDEV-3420`
- **⚠ The input diff I was handed was stale.** It was the working tree; the change has since been committed and the `RestExceptionHandler` javadoc and the test javadoc were both substantially revised (the handler's census paragraph now says "62 … repository files" and adds a 🔴 paragraph about an unreconciled runtime figure). All findings below are against the **committed** text, and I say where a claim the diff carried has already been fixed.
- **No build was run.** Everything is derived from source, bytecode (`javap -v` over the pre-existing `target/classes`), extracted dependency sources, and read-only `git`/`git grep` in the sibling repos.

**Verdict: 3 Medium, 5 Low. No High.** None of them is a runtime defect — the code change itself is correct, minimal, and lands on the right mechanism. Every Medium is a false or overstated claim in a durable comment, two of which contradict facts this repository has already established in its own code and tests. Given this programme's history (the javadoc itself records four stale-count incidents in one ticket), I am treating those as Medium rather than Low.

---

## Findings

### M1 · `src/test/java/net/aim_ai/wms/security/SdrSearchParameterConversionContextTest.java` — the `$.properties` explanation is wrong in both halves, and contradicts an existing test *and* an existing `src/main` comment

Quoted:

```
// found. On the MVC channel Spring registers ProblemDetailJacksonMixin, whose
// @JsonAnyGetter flattens custom properties to the root; that is why
// SdrReadGateEnforcementContextTest can assert `$.reason` at the root. The SDR/HAL
// channel uses its own ObjectMapper WITHOUT that mixin, so the same ProblemDetail
// serialises as {"properties":{…}} here.
```

**What is wrong — three independent refutations.**

1. **This application's MVC channel does not carry the mixin either.** `WebConfigurer.java` declares

   ```java
   @Bean
   @Primary
   public ObjectMapper objectMapper() {
       ObjectMapper mapper = new ObjectMapper();
   ```

   and then wires *that same instance* into the MVC JSON converter:

   ```java
   @Bean
   public MappingJackson2HttpMessageConverter mappingJackson2HttpMessageConverter() {
       MappingJackson2HttpMessageConverter jsonConverter = new MappingJackson2HttpMessageConverter();
       ObjectMapper objectMapper = objectMapper();
       jsonConverter.setObjectMapper(objectMapper);
   ```

   `ProblemDetailJacksonMixin` is registered only by `Jackson2ObjectMapperBuilder` (`Jackson2ObjectMapperBuilder.java:767`, `objectMapper.addMixIn(ProblemDetail.class, ProblemDetailJacksonMixin.class)`), and the mixin's own javadoc says so explicitly: *"Jackson2ObjectMapperBuilder automatically registers this as a mix-in for ProblemDetail, which means it always applies, **unless an ObjectMapper is instantiated directly and configured for use**."* That is exactly what `WebConfigurer` does.

2. **Measured counter-evidence is already in this repo.** `src/test/java/net/aim_ai/wms/integration/controller/CustomerOrderControllerIntegrationTest.java` — a **plain MVC** route, full context (`extends BaseControllerIntegrationTest`), handled by `RestExceptionHandler.handleEntityNotFound` — asserts:

   ```java
   mockMvc.perform(get("/v3/customerOrder/detailsByOrderId/999999"))
       .andExpect(status().isNotFound())
       .andExpect(jsonPath("$.title", is("Entity Not Found")))
       // ProblemDetail nests setProperty(...) values under "properties", not at the root.
       .andExpect(jsonPath("$.properties.retryable", is(false)));
   ```

   So the nesting is **app-wide**, not an SDR/HAL peculiarity.

3. **`SdrReadGateEnforcementContextTest`'s root-level `$.reason` is not a `ProblemDetail` at all**, so it cannot be evidence about a `ProblemDetail` mixin. `FunctionGuardInterceptor` hand-builds the body, and its comment states the *opposite* of the new javadoc:

   ```
   // ⚠️ The body is assembled EXPLICITLY rather than by serialising a ProblemDetail, and that is
   // load-bearing rather than stylistic. A ProblemDetail's extension fields only serialise at the top
   // level if Jackson carries ProblemDetailJacksonMixin, which Spring Boot's auto-configured mapper
   // registers — but `WebConfigurer` declares an @Primary bare `new ObjectMapper()`, and
   // JacksonObjectMapperConfiguration is @ConditionalOnMissingBean, so the auto-configured mapper backs
   // off and never contributes the mixin. The injected mapper therefore nested `reason` and
   // `requiredFunction` under a "properties" object.
   ```

**How it fails (concrete).** An engineer adds a sibling `ProblemDetail` handler to `RestExceptionHandler` for an MVC route, reads this comment, and pins `jsonPath("$.retryable")`. In a full-context test that path does not exist → "No value at JSON path", i.e. the same dead end this comment was written to prevent, arrived at *by following the comment*. The second failure mode is someone "fixing" this test's `$.properties.*` paths to the root form because the comment says the root form is the MVC norm.

Secondary observation, not introduced here but entrenched by the wrong explanation: `RestExceptionHandlerUnitTest`'s `assertThat(...getContentAsString()).contains("\"retryable\":false")` assertions pass only because `MockMvcBuilders.standaloneSetup(...)` builds its own default `Jackson2ObjectMapperBuilder` mapper (which *does* carry the mixin). That lane therefore asserts a body shape production never emits.

**Suggested fix.** Replace the paragraph with something like: *"In this application `ProblemDetail` custom properties ALWAYS nest under `properties`, on every channel — `WebConfigurer`'s `@Primary` bare `new ObjectMapper()` carries no `ProblemDetailJacksonMixin` and is wired into the MVC converter, and SDR's fallback converter is built on its own `basicObjectMapper()`, which has none either. The production shape is pinned by `CustomerOrderControllerIntegrationTest` on a plain MVC route. Root-level flattening appears only in `standaloneSetup` unit tests. `SdrReadGateEnforcementContextTest` can assert `$.reason` at the root because `FunctionGuardInterceptor` hand-builds a `LinkedHashMap` precisely because the mixin is absent."*

---

### M2 · `src/main/java/net/aim_ai/wms/repo/jpa/PickingorderRepository.java` — "the route had no working input at all" is refuted by `java.util.Date(String)` + `ObjectToObjectConverter`

Quoted:

```
// java.util.Date, and for a Date parameter the defect is not "bad input" but UNREACHABILITY: no
// ISO-8601 spelling binds (`2020-01-01`, `2020-01-01T00:00:00Z` and an epoch-millis value all failed
// on dev, build develop-40bc14ad), so the route had no working input at all.
```

**What is wrong.** The narrow claim ("no ISO-8601 spelling binds", 3 probes) is fine. The completeness claim ("no working input at all", and the reframing of the defect as *unreachability* rather than bad input) has no stated method behind it, and a `String -> java.util.Date` conversion path does exist:

- SDR's conversion service is a `DefaultFormattingConversionService`, and `DefaultConversionService.addDefaultConverters` registers `ObjectToObjectConverter` as the last-resort converter (`DefaultConversionService.java:100`).
- `ObjectToObjectConverter.matches` → `hasConversionMethodOrConstructor(targetType, sourceType)`; no static `valueOf/of/from(String)` exists on `java.util.Date`, so it falls to `determineFactoryConstructor` → `ClassUtils.getConstructorIfAvailable(Date.class, String.class)`.
- `javap java.util.Date` confirms `public java.util.Date(java.lang.String)` exists (deprecated, delegates to `Date.parse`).

So `?timeOut=Dec+25,+2020` or `?timeOut=Sat,+12+Aug+1995+13:30:00+GMT` would have bound. The route was *awkward*, not unreachable.

**How it fails (concrete).** The comment ends with "The revert is deleting `exported = false`." Whoever evaluates that revert is told the route had no working input; they will conclude nothing could ever have called it, when in fact a `Date.parse`-shaped caller would have worked. It also implies withdrawal was the only available remedy, when the handler half of *this same ticket* already converts those ISO failures from 500 to 400 (the failure path is `Date.parse` → `IllegalArgumentException` → `ConversionFailedException` → `QueryMethodParameterConversionException` → the new handler).

**Suggested fix.** Narrow to the measurement and separate the decision from the rationale: *"No ISO-8601 spelling binds — three spellings probed on `develop-40bc14ad`. A legacy `Date.parse` spelling would bind via `ObjectToObjectConverter` and the deprecated `Date(String)` constructor, so the route was awkward rather than unreachable, and the handler half of this ticket already turns the ISO failures into 400s. Withdrawal is a hygiene call on an uncalled route (Nam 2026-09-18), not the only remedy."*

---

### M3 · `PickingorderRepository.java` — the retracted "36 repositories" figure was corrected in two files and left in the third, and "402 query methods" does not reproduce

Quoted:

```
// on dev, build develop-40bc14ad), so the route had no working input at all. Measured over all 402
// query methods in the 36 @RepositoryRestResource repositories after PR #378 withdrew 53 searches,
```

The test javadoc **explicitly retracts this in the same commit**:

> *An earlier revision of this javadoc also said "the 36 repositories", which was SBDEV-3417's runtime repository count borrowed into a source population of 62 files; that is the exact failure mode this paragraph exists to prevent.*

and `RestExceptionHandler` was corrected to "the 62 `@RepositoryRestResource` repository files". `PickingorderRepository` still carries the withdrawn number. This is the sibling-copy failure mode: the retraction landed in 2 of 3 homes.

Two instruments on the real figure:

| | value |
|---|---|
| `grep -c '^@RepositoryRestResource' src/main/java/net/aim_ai/wms/repo/jpa/*.java` | 62 |
| of those, carrying `exported = false` | 27 |
| → exported repositories | **35** |
| bytecode census (`javap -v` over `target/classes`) | 62 / 27 / **35** |
| `SdrUncalledSurfaceNotExportedContextTest`'s own comment | "62 exported before Slice 2 - 27 withdrawn = 35 exported" |

So "36" is wrong under both readings (it is neither 62 nor 35), and it contradicts a figure this repo pins next to `assertThat(WITHDRAWN).hasSize(27)`.

**"402 query methods" does not reproduce either.** From bytecode: 413 methods declared across the 62 annotated repository interfaces, of which 9 are CRUD-name overloads (`PickingorderPositionRepository.delete/deleteAll/deleteById` ×2 each, `StockViewRepository.findAll` ×3 — all on class-withdrawn repositories), leaving **404** non-CRUD query methods. I could not find a definition that yields 402.

**Suggested fix.** In `PickingorderRepository`, drop the census sentence entirely and point at the test javadoc as the single home for it — or restate as "the 62 `@RepositoryRestResource` repository files (35 exported)". Also grep the plan doc / ticket / PR body for "36 repositories" and "402" before this merges; per the repo's own experience a token grep is not a sweep, so check the PR description and comments too.

---

### L1 · `PickingorderRepository.java` — the caller sweep names a repository that is not checked out, and omits four that are

Quoted:

```
// SBDEV-3183 rule: a bare-name sweep over ten repositories (both v2 UIs, siteboss-frontend, omsv2-UI,
// oms-laravel-api, both v1 UIs, v1/oms, v1/wms-api, this repo) and a second sweep on the `/search/`
```

`ls /home/nampark/dev/wms-claude/v1` → `carrier-integration  label-automation  qa-api  qa-ui  wms-api  wms-mobile-ui  wms-web-ui`. **There is no `v1/oms` in this working directory.** So one of the stated "ten" contributed a zero from a missing path — indistinguishable from a true zero, which is precisely the false-zero shape this programme's rules exist to catch. Only nine repositories exist, and four existing ones were not swept: `v1/carrier-integration`, `v1/label-automation`, `v1/qa-api`, `v1/qa-ui`.

**I re-ran the sweep to close the gap, and the conclusion holds.** Over all nine present repositories plus the four omitted ones: 0 hits on the bare method name anywhere outside `v2/wms2-api` (the 2 hits in `v1/wms-api` are v1's own copy of the repository and job). Positive control `findByClientId` is found in `wms2-web-ui` (5 files) and `oms-laravel-api` (7 files), so the instrument was live. On the `/search/` URL shape: `carrier-integration` has 1 file mentioning `/search/`, not this route. **No HTTP caller in any repository present here** — the verdict is right; only the stated method is wrong.

**Suggested fix.** Replace "ten repositories (… v1/oms …)" with the nine that exist plus the four that were omitted, and note that `v1/oms` is not cloned in this working directory rather than listing it as swept.

---

### L2 · `SdrSearchParameterConversionContextTest.java` (AC-3) — the justification for the body assertions names a file that does not read those fields

Quoted:

```
* body contract is not decoration on this programme: {@code wms2-mobile-ui/plugins/axios.js} keys its
* operator-visible behaviour on body fields, so a handler that silently stopped emitting them would
* be a live regression with no red test.
```

`wms2-mobile-ui/plugins/axios.js` reads exactly two body fields, and only for `status === 403`:

```js
const status = error && error.response && error.response.status
const body = (error && error.response && error.response.data) || {}
if (status === 403 && body.reason) {
```

plus `body.requiredFunction` inside `authzDenialMessage`. `git grep retryable` in `wms2-mobile-ui` hits only a comment in `plugins/tenant-auth-fetch.js` and a test fixture (`test/util/apiError.spec.js:14`); `git grep -ln retryable -- ':!test'` returns only that one comment file. In `wms2-web-ui`, `retryable` is a local computed property on `pages/unhealthy-tenant.vue`, unrelated to response bodies. **No client reads `retryable` or `parameter`.**

The assertions themselves are correct and worth keeping — the PIT evidence in the same javadoc (three `VoidMethodCallMutator` survivors against a substring-only assertion) is a sufficient and true reason. Only the "live regression" claim is false.

**Suggested fix.** Keep the assertions; drop the axios.js sentence, or restate it truthfully as "the 403 precedent in `wms2-mobile-ui/plugins/axios.js` shows this stack *does* branch on ProblemDetail body fields (`reason`, `requiredFunction`), which is why a body contract is worth pinning — no client reads `retryable`/`parameter` today."

---

### L3 · `RestExceptionHandler.java` — the 400 detail is uninformative for the 15 collection-typed exported parameters

Quoted:

```java
String requiredType = ex.getParameter().getParameterType().getSimpleName();
```

`getParameterType()` erases generics. For `Set<Long> clientIds` this yields `"Set"`, so

`GET /v3/itemdata/search/findByClientIdIn?clientIds=abc` → `{"detail":"Parameter 'clientIds' must be a valid Set."}`

The caller passed a valid `Set` spelling; what it got wrong was the *element* type. The census counts 15 such parameters on the exported surface (`Set<String>` 4, `List<Long>` 4, `Collection<Long>` 4, `List<String>` 2, `Set<Long>` 1), and the ticket's own framing is that naming the required type is "the half that makes it actionable". The path is reachable: `StringToCollection` converts the wrapper fine and fails on element conversion, which still surfaces as a `QueryMethodParameterConversionException`.

**Suggested fix.** Prefer the generic type when one is present, e.g. `ResolvableType.forMethodParameter(ex.getParameter()).toString()`, or `ex.getParameter().getGenericParameterType().getTypeName()` reduced to simple names, falling back to `getSimpleName()`. If you change it, add a row to AC-3 (or a new AC) with a collection-typed parameter — no assertion currently covers any type other than `Long`.

---

### L4 · `RestExceptionHandler.java` — the rejected value is logged at WARN unbounded and unsanitised

Quoted:

```java
LOG.warn("Rejected SDR query parameter '{}' -> 400: cannot convert [{}] to {}",
        safeName, ex.getSource(), requiredType);
```

`ex.getSource()` is the raw query-parameter value — arbitrary, caller-controlled, unbounded length. A value containing CRLF forges log lines; a long value floods the log. The handler's whole purpose is to make these responses cheap and correct for callers to trigger, so the rate is unbounded too. This stack already treats log hygiene as load-bearing (`redactAuthorizationHeaders` in both UI axios plugins, and SDR's own `RepositoryRestExceptionHandler` routes its message through `LogFormatUtils.formatValue(message, -1, true)`).

**Suggested fix.** Clamp and sanitise, reusing what SDR already uses: `LogFormatUtils.formatValue(String.valueOf(ex.getSource()), 100, true)` (`org.springframework.core.log.LogFormatUtils`, already on the classpath).

---

### L5 · Stated pre-fix evidence — "4/5 with `expected:<400> but was:<500>`" cannot be literally true

AC-4 is an AssertJ list assertion:

```java
assertThat(exported)
        .as("getPickingOrdersToReleaseExpiredPickingOrders takes a java.util.Date, …")
        .doesNotContain("getPickingOrdersToReleaseExpiredPickingOrders");
```

Pre-fix it fails with a "does not contain" message, not a status mismatch. Only AC-1, AC-2 and AC-3 can produce `expected:<400> but was:<500>`. So either the count is 4 and the message applies to 3 of them, or the message is right and the count is 3. The credibility of the red comes from "same message, same cause" — worth restating precisely on the ticket rather than collapsing two different reds into one message.

---

## Verified — explicit non-findings

I checked each of these and found nothing wrong. Listing them so an empty severity band is not mistaken for an unexamined one.

**No High findings.** Nothing in this change can produce a wrong status, a wrong body, a leaked route, or a broken caller on any path I could reach.

### 1. The exception type is right, and it steals nothing

`QueryMethodParameterConversionException` has **exactly one** throw site in the whole dependency tree:

```java
// ReflectionRepositoryInvoker.convert, line 206
} catch (ConversionException o_O) {
    throw new QueryMethodParameterConversionException(value, parameter, o_O);
}
```

reachable only from `prepareParameters` ← `invokeQueryMethod` — i.e. SDR **search** routes only. It is `extends RuntimeException` in `org.springframework.data.repository.support` (spring-data-**commons**), exactly as the javadoc says.

- SDR's `RepositoryRestExceptionHandler` declares no handler for it; `handleMiscFailures(@ExceptionHandler({InvocationTargetException, IllegalArgumentException, ClassCastException, ConversionFailedException, NullPointerException}))` is declared `INTERNAL_SERVER_ERROR`, matching via `getCause()`. Confirmed in the extracted source.
- **Entity id binding is unchanged.** `convertId` calls `conversionService.convert(...)` **without** the `try/catch`, so a bad id still throws a raw `ConversionFailedException`, which the new handler does not declare. Behaviour identical to before.
- **Association property paths are unchanged.** `RepositoryPropertyReferenceController` is the only SDR controller with its own `@ExceptionHandler` (for `HttpRequestMethodNotSupportedException`) and does not bind `@Param`s through `prepareParameters`.

### 2. Advice ordering is robust — and better-founded than the javadoc states

Verified in spring-webmvc 6.2.15 `ExceptionHandlerExceptionResolver.getExceptionHandlerMethod`: controller-local handlers are consulted first, then `exceptionHandlerAdviceCache` in sorted order, guarded by `advice.isApplicableToBeanType(handlerType)`. `RepositorySearchController` and its `AbstractRepositoryRestController` base declare no `@ExceptionHandler`. This repository has exactly three advices:

| advice | order | scope | applicable to `RepositorySearchController`? |
|---|---|---|---|
| `RestEndpointExceptionHandler` | `HIGHEST_PRECEDENCE` | `basePackages = "net.aim_ai.wms.controller.rest"` | no |
| **`RestExceptionHandler`** | **`@Order(0)`** | **unscoped** | **yes** |
| `MobileEndpointExceptionHandler` | `LOWEST_PRECEDENCE` | `basePackages = "net.aim_ai.wms.controller.mobile"` | no |
| SDR `RepositoryRestExceptionHandler` | none → `LOWEST_PRECEDENCE` | `basePackageClasses` (itself) | yes |

Nothing can pre-empt the new handler on an SDR route. The claim that SDR's own resolver (inserted at chain index 0 by `extendHandlerExceptionResolvers` → `exceptionResolvers.add(0, er)`) still discovers our advice is correct: it is built with `er.setApplicationContext(applicationContext)` before `afterPropertiesSet()`, so its advice cache is the full, order-sorted set.

**But the class javadoc's framing is wrong, and the lead's suspicion is right.** It says Spring uses *"the first one that has ANY matching handler"*. Cause traversal happens **inside** each advice's resolver:

```java
// ExceptionHandlerMethodResolver.resolveExceptionMapping, lines 192-199
ExceptionHandlerMappingInfo mappingInfo = resolveExceptionMappingByExceptionType(exception.getClass(), mediaType);
if (mappingInfo == null) {
    Throwable cause = exception.getCause();
    if (cause != null) {
        mappingInfo = resolveExceptionMapping(cause, mediaType);
```

so the actual rule is **"the first applicable advice that has a handler for the exception *or any of its causes*"** — which is stronger than the javadoc says (a cause-match in a higher-ordered advice beats a direct match in a lower-ordered one) and is what actually makes this fix reachable. Worth a one-line correction to that javadoc while the file is open; it is pre-existing text, not introduced here.

### 3. No conflict with `MobileEndpointExceptionHandler`

Its `@ExceptionHandler({HttpMessageNotReadableException.class, TypeMismatchException.class})` → 400 is a disjoint set of types on a scoped, disjoint channel. `QueryMethodParameterConversionException` is not a `TypeMismatchException` (it extends `RuntimeException` directly), and it never arises under `controller.mobile`. No overlap, no ordering interaction.

### 4. Blast radius of the 500 → 400 contract change is nil

- **No test pinned the old status.** The only `isInternalServerError()` expectations in the tree are `NoSuchElementException` (SBDEV-2218, deliberate), `FacadeException` (AC6), the catch-all `Exception` (AC11) — all in `RestExceptionHandlerUnitTest` / `MobileEndpointExceptionHandlerUnitTest` / `TenantHealthControllerUnitTest`, none on an SDR route.
- **No client branches on 5xx for these routes.** Both UI axios plugins retry *only* on 401/403:
  ```js
  if (!error.response || (error.response.status !== 401 && error.response.status !== 403)) {
    return false
  }
  ```
  (`wms2-web-ui/plugins/axios.js`, and the identical guard in `wms2-mobile-ui/plugins/axios.js`). A 500→400 flip changes no retry path, no logout path, and no toast.
- `oms-laravel-api` wires the live route as claimed: `config/wms.php` → `'itemdata_by_client' => env('WMS_ITEMDATA_BY_CLIENT_ENDPOINT', 'v3/itemdata/search/findByClientId')`. ✓

### 5. The withdrawal is correct and sufficient, and breaks nothing

- **In-process caller unaffected.** `ReleaseExpiredPickingOrdersFromUserJob:388` calls the method directly; `exported = false` is annotation-only and does not touch Spring Data's proxy.
- **`ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest` unaffected.** It reflects `PickingorderRepository.class.getMethod("getPickingOrdersToReleaseExpiredPickingOrders", int.class, String.class, Date.class)` and reads the `@Query` annotation. Neither the signature nor `@Query` changed.
- **`SdrUncalledSurfaceNotExportedContextTest` unaffected.** `assertThat(WITHDRAWN).hasSize(27)` is a hardcoded array of withdrawn **domain types**; `Pickingorder` is not among them, and withdrawing a single search does not change that set. Its sensitivity check uses `Customerorder` (21 searches) as the positive control.
- **Every other rail is a floor, and 183 → 182 clears all of them:** `SdrNonEntityCollectionSearchNotExportedContextTest` `> 100` / `> 50`, `SdrMutatingSearchNotExportedContextTest` `> 100`, `SdrLockingSearchNotExportedContextTest` `> 100`, `SdrSurfaceInventoryContextTest` `> 20`, `SdrUncalledSurfaceNotExportedContextTest` `> 0`. `SdrWriteWithdrawalContextTest`'s `hasSize(49)` / `hasSize(9)` are write-axis sets, untouched.
- **No SDR rule, sysprop or resource name references the path** — grep over `src/main/java` and `src/main/resources` returns only the repository declaration, the job, and javadoc.

### 6. AC-4 is sound — for a reason worth writing into the test

`SearchResourceMappings.iterator()` does **not** filter by `isExported()`:

```java
@Override
public Iterator<MethodResourceMapping> iterator() {
    return mappings.values().iterator();
}
```

(there is a separate `getExportedMappings()` that does the filtering, and several sibling rails defensively re-check `if (!m.isExported()) continue;`). AC-4 is nonetheless correct, because the **builder** filters:

```java
// RepositoryResourceMappings.getSearchResourceMappings
if (resourceMapping.isExported()) {
    for (Method queryMethod : repositoryInformation.getQueryMethods()) {
        RepositoryMethodResourceMapping methodMapping = new RepositoryMethodResourceMapping(...);
        if (methodMapping.isExported()) {
            mappings.add(methodMapping);
        }
```

so the collection contains exported mappings only, and the local variable named `exported` is accurate. **Suggestion (not a finding):** add one sentence saying the guarantee comes from the builder, not the iterator — otherwise someone will "harden" this into `getExportedMappings()` believing the current form was a bug, or copy the bare iterator into a context where it *isn't* pre-filtered.

### 7. The test can fail, and the control discriminates

- `findByClientId?clientId=1` → 200 on the **same route** as AC-1's 400. The 200 does not depend on fixture data (an SDR search returning an empty collection is still 200 on H2), so the control is robust to seeding.
- `Pickingorder` keeps **8** exported searches post-fix, so AC-4's `isNotEmpty()` non-vacuity guard is real, not decorative.
- AC-2's route exists and has the shape claimed. Bytecode: `getClosedCycleCountsPageAndKeyword(java.lang.String, java.lang.Long, Pageable)` with `@Param("keyword")` / `@Param("clientId")`, JPQL `@Query`, exported — so `clientId=NOT_A_NUMBER` genuinely exercises `Long` conversion on a second repository and a second query flavour, and cannot 400 for a missing-parameter reason.
- The `$.properties.*` paths are right for this channel. Double-confirmed mechanistically: SDR's resolver writes through `fallbackJsonConverter` = `new MappingJackson2HttpMessageConverter()` with `basicObjectMapper()` (`RepositoryRestMvcConfiguration.defaultMessageConverters`), which carries no mixin.

### 8. Null safety and correctness of the handler body

- `ex.getParameter()` cannot be null — the constructor asserts it (`Assert.notNull(parameter, "Method parameter must not be null")`), as it does the cause.
- `getParameterName()` really is non-null on this path, and for the reason the comment gives: `prepareParameters` throws `IllegalArgumentException(NAME_NOT_FOUND)` when `!StringUtils.hasText(parameterName)` **before** calling `convert`. The guard is correct belt-and-braces.
- `getParameterType()` and `getSimpleName()` cannot be null.
- `ex.getSource()` can be null per its javadoc, but not on this path (`convert` returns early when `value == null`); it is only passed to an SLF4J placeholder, which handles null. (Its sanitisation is L4.)
- Nothing in the handler body can throw, so the 400 handler cannot itself become a 500.
- Omitting `setTitle` is correct: `ProblemDetail.forStatusAndDetail(BAD_REQUEST, …)` derives `"Bad Request"` from the reason phrase, which is why PIT reported the removal as a survivor. The 400 (rather than this class's 422 for `ApiInvalidParameterException`) matches `MobileEndpointExceptionHandler`'s `TypeMismatchException` → 400 and RFC 9110 for a malformed request; no inconsistency worth changing.

### 9. The census numbers verify exactly — by a different instrument

I re-derived them from **bytecode**, not source text: `javap -v -p` over `target/classes/net/aim_ai/wms/repo/**`, parsing class-level `@RepositoryRestResource(exported=…)`, method-level `@RestResource(exported=…)`, `RuntimeVisibleParameterAnnotations` for `@Param`, and the generic `Signature` attribute for parameter types. This is immune to both source-parsing failures the javadoc records (`@Query` string literals breaking annotation capture, and literal-stripping eating `@Param` names).

Post-fix measurements, and the pre-fix figures obtained by adding back the one withdrawn method (`int state, String pickingType, Date timeOut`):

| claim | javadoc | lane A (bytecode) |
|---|---|---|
| exported searches | 183 | 182 + 1 = **183** ✓ |
| with ≥1 non-`String` typed `@Param` | 109 | 108 + 1 = **109** ✓ |
| typed `@Param`s on exported searches | 263 | 260 + 3 = **263** ✓ |
| of those, non-`String` | 166 | 164 + 2 = **166** ✓ |
| `Long` / `int` / `Integer` | 88 / 47 / 14 | 88 / 46+1 / 14 ✓ |
| `Set<String>` / `List<Long>` / `Collection<Long>` | 4 / 4 / 4 | 4 / 4 / 4 ✓ |
| `List<String>` / `Set<Long>` / `Date` / `long` | 2 / 1 / 1 / 1 | 2 / 1 / 0+1 / 1 ✓ |
| implied `String` count (263 − 166) | 97 | 96 + 1 = **97** ✓ |
| "the only `java.util.Date` parameter left on the exported surface" | — | ✓ **zero** `Date` params remain exported; 15 `Date`/`LocalDate` params exist elsewhere, all on class-withdrawn repositories |
| "#378 withdrew 53 searches" | — | ✓ commit `b20eb9f1` "SBDEV-3417: withdraw 53 exported SDR searches that cannot be rendered" |

Every number in the census reproduces. The two that do **not** are `36` repositories and `402` query methods (M3).

### 10. On the unreconciled 228-vs-236 gap

The test javadoc's 🔴 paragraph is honest and I would not remove it, but I can narrow it. It says the candidate causes ruled out are "no repository file declares two interfaces" and "none of the 183 is a CRUD override". **I ruled out two more:**

- **No two annotated repositories share a domain type** — 62 annotated repositories, 62 distinct domain types (extracted from each interface's generic `Signature`). A shared domain type would make `RepositoryResourceMappings` (keyed by domain type) publish one and silently drop the other's searches, which would have explained the gap. It does not.
- **No repository has two exported searches sharing a `rel`** — checked all 182, zero collisions. A duplicate `rel` would make a HAL `_links`-keyed runtime walk under-count.

One window factor the "before #378" framing does not cover: **PR #377** (`c251ff45`, "Withdraw the three caller-less replenish keyword searches", merged *before* #378) withdrew 3 more. Whether the 228 runtime figure predates it is not recorded. Since my bytecode instrument independently reproduces the source figure exactly, the source parse is not the source of the error; the gap most likely sits in the runtime figure or its measurement window.

---

## Rail-hygiene suggestions (not findings)

1. **No AC covers a type other than `Long`.** The mechanism is type-agnostic so I do not think coverage is a defect, but `int` is the second-most-common exported type (47 params) and a primitive follows a different `TypeDescriptor` path than a wrapper. One extra row on `pickingorder/search/getForRapidPickingScanPackage?packageName=x&stateCancelled=ZZZZ` → 400 would pin the primitive path for ~2 lines, and would sit right beside the *missing*-primitive 500 the javadoc documents as out of scope.
2. **The `parameterName == null` fallback (`"request parameter"`) is unreachable by the javadoc's own argument** and produces the slightly odd `"Parameter 'request parameter' must be a valid Long."`. Leaving the guard is right; consider a message that reads correctly in that branch, e.g. omit the quoted name entirely when it is null.
3. **Context cache:** the new test's `@MockitoBean` set (`SdrGuardModeProvider`, `AccessService`) is byte-identical to `SdrReadGateEnforcementContextTest`'s, so it shares that context cache entry and adds no new `ApplicationContext` to the suite. Good as-is — worth preserving if either test's mock set is edited.
