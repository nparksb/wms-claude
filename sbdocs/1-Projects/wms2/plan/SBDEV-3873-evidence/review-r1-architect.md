# SBDEV-3873 — ralplan round 1 — Architect review

**Reviewed:** `plan-snapshot-r1.md` (fixed snapshot, not edited). **Code basis:** `origin/develop` wms2-api `bafa2301`,
wms2-web-ui `98accaf` (fetched 2026-10-22); web-ui `origin/main` `0a2e178`. No Maven, no DB writes.

**Verdict: ITERATE — approve the design with changes.** Option A is sound. The mechanisms it depends on hold in code
(typed DTO, route, `SDR_WRITE_WITHDRAWN`, the 409, the gate). Two stated behaviours are wrong (the 400 status and the PIT
coverage), and option C was rejected on a reason that no longer applies. Counts: **High 0 · Medium 3 · Low 7.**

---

## 1. Steelman antithesis (against option A)

> "The defect is field binding on PRD at guard mode OFF. Option A leaves it **fully open on PRD** through two release
> trains, because PR 1 narrows nothing and PR 2 has to wait for PR-W to reach `main`. Meanwhile it adds a permanent
> endpoint whose main traffic is an echo-on-load no-op (see L1). Option C was rejected for two reasons, and neither
> holds here.
> - (a) *'collection POST bypassed the same annotation (SBDEV-3215)'*: collection POST is **already withdrawn** on both
>   types (`RestConfiguration.configureAdviceCollectionCreateWriteExposure` and
>   `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN = {…, Cyclecount.class, …}`), and item PUT/DELETE are withdrawn
>   too. The only remaining write path is merge-PATCH, which is one of the three paths the class javadoc says consults
>   `@ReadOnlyProperty`.
> - (b) *'a closed list that drifts'*: a metadata-derived pin removes the drift. Assert that, over
>   `PersistentEntities`, every writable property of `Advice` and `Cyclecount` is in `{comment}`. A new column then
>   fails CI unless someone annotates it.
>
> One wms2-api PR, with no UI change and no cross-repo ordering, closes PRD in a single release. Option A can follow
> later, or never."

Why it does not win outright:
- At OFF, C still leaves `comment` writable by any `wms_user`. That is low impact, but it is not closed.
- C is a filter, which runs against Principle 1.
- Removing the cycle-count echo (D1) is independent of C anyway.

It does expose a real gap, which section 2 takes up.

## 2. Tradeoff tension and synthesis

**Tension: Principle 3 (no UI is ever left without its write path) against Driver 1 (PRD exposure today).** Principle 3
creates the ordering (PR 1, then PR-W, then wait, then PR 2), and the ordering is what keeps Driver 1 open. Measured
cadence: both repos are promoted together as one OWL release, the same day and the same version
(`v2.0.155` = wms2-api v0.0.42 + wms2-web-ui v0.0.37, both `main` merges on 2026-10-21; earlier pairs 10-16, 10-10,
10-08, 10-02 …). The window is therefore about one to two release cycles (days to a week each), not open-ended. It is
still a full PRD window during which "any `wms_user` can retype or re-client an advice".

**Synthesis (flag for Nam; does not touch D1–D4):** put an interim field fence into **PR 1**, which has to ship first
anyway:
- `@ReadOnlyProperty` on every `Advice` and `Cyclecount` field except `comment` (18 + 7 own fields, plus the inherited
  `created`; `modified` and `version` are overwritten by auditing/locking but should be fenced as well);
- one context test, derived from metadata: "writable SDR properties of Advice/Cyclecount ⊆ {comment}", with a
  sensitivity floor.

This keeps today's UI working (it sends `{id, comment}`) and closes the field-binding exposure when PR 1 is promoted.
PR 2 still removes the verb (Principle 1), and the annotations can stay as defence in depth or go in PR 2.
- Cost: about 25 one-line annotations and one test.
- Risk: `@ReadOnlyProperty` is a Spring Data annotation that Spring Data JPA does not consult for persistence, so
  service-layer writes are unaffected. The precedent is `state`, which already carries it and is set by
  `AdviceService` and `CyclecountService`.

If Nam declines, the plan should at least correct the option C row, because its objection (a) is no longer true.

## 3. Architectural soundness checks (verified against `origin/develop`)

### 3.1 Does a typed DTO prevent binding? Yes.
`WebConfigurer.java` (the `@Primary` mapper):
```java
@Bean
@Primary
public ObjectMapper objectMapper() {
    ...
    mapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);
```
The same setting is repeated in `jsonCustomizer()` (`builder.featuresToDisable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)`)
and in `extendMessageConverters`. Unknown keys (`externalid`, `clientId`, `state`, …) are **dropped with a 200, not
rejected with a 400**, which is what AC-2 expects. The DTO is never mapped onto the entity, so the only write is the
explicit `setComment`. AC-2 is the right pin: it kills the mutant "`@RequestBody Advice` + save". It does **not** kill
"a DTO that later grows a field which gets copied". That would need a review rule, not a test.

### 3.2 Will `POST /v3/advice/setComment` collide? No.
- `AdviceController`: `@RequestMapping("/v3/advice")`. Its existing literal subpaths are `/create`, `/update`,
  `/setPurchaseOrderNumber`, `/closeInboundBol`, `/closeInboundBol/{id}`, `/acceptHubAndSpokeBol/{id}/{locationId}`,
  `/fixHubAndSpokePalletIssues`, `/detailView`, `/adviceDetailsById/{id}` and `/exportInboundNotice`. None is
  `setComment`.
- `git grep` finds no other `"/v3/advice` mapping in `src/main`.
- SDR: `AdviceRepository` is `@RepositoryRestResource(collectionResourceRel = "advice", path = "advice")`. Its item
  template `/v3/advice/{id}` carries no POST, and annotated MVC mappings resolve first. The live precedent is
  `POST /v3/advice/setPurchaseOrderNumber`, which has the same shape on the same prefix and is pinned in the tranche map
  at `row("AdviceController","/v3/advice/setPurchaseOrderNumber","WEB_UI_VIEW_INBOUND_BOL")`.
- `/setComment` also avoids SDR's `/{repository}/{id}/{property}` template, as A §4.1 notes.

### 3.3 Does `SDR_WRITE_WITHDRAWN` disable every axis? Yes, and adding to it cannot be undone by the remaining calls.
```java
private static final HttpMethod[] WRITE_VERBS =
    {HttpMethod.POST, HttpMethod.PUT, HttpMethod.PATCH, HttpMethod.DELETE};
...
private void configureUnwrittenResourceWriteExposure(RepositoryRestConfiguration config) {
    for (Class<?> domainType : SDR_WRITE_WITHDRAWN) {
        config.getExposureConfiguration()
            .forDomainType(domainType)
            .withCollectionExposure((metadata, httpMethods) -> httpMethods.disable(WRITE_VERBS))
            .withItemExposure((metadata, httpMethods) -> httpMethods.disable(WRITE_VERBS))
            .withAssociationExposure((metadata, httpMethods) -> httpMethods.disable(WRITE_VERBS));
```
Composition was verified in spring-data-rest-core **4.5.7** sources (`ExposureConfiguration.TypeBasedExposureConfigurer`):
```java
config.item = config.item.andThen(withTypeFilter(type, filter));
```
Per-type filters are chained with `andThen`, not replaced, and every one of them only `disable`s. So the leftover
`disable(PUT, DELETE)` calls are redundant but harmless, and deleting them (Fix C) is safe whatever the order.
- The association axis is moot: neither entity has a `@ManyToMany`.
- The search axis is already safe: `AdviceRepository.updateAdviceToStateById` is `exported = false`, and
  `CyclecountRepository` has no `@Modifying` method.

### 3.4 Is the 409 on an optimistic lock true? Yes, for this controller.
`RestExceptionHandler` (`@Order(0) @ControllerAdvice`, unscoped):
```java
@ExceptionHandler(ObjectOptimisticLockingFailureException.class)
protected ResponseEntity<ProblemDetail> handleOptimisticLock(ObjectOptimisticLockingFailureException ex) {
    ...
    return ResponseEntity.status(HttpStatus.CONFLICT).body(problemDetail);
```
The competing `RestEndpointExceptionHandler` (HIGHEST_PRECEDENCE, which maps the same exception to **503**) is
`@ControllerAdvice(basePackages = "net.aim_ai.wms.controller.rest")`. `AdviceController` lives in
`net.aim_ai.wms.controller`, so the 409 applies.

Caveat for the risk row: the load, setComment and commit happen within milliseconds, so in practice the conflict falls on
the **other** writer (a `closeInboundBol` that loaded the advice earlier), not on `setComment`. That is the correct
direction, because the comment is never silently reverted. The risk row should say so; as written it implies
`setComment` is the side that gets the 409.

### 3.5 Does `@RequiresFunction` enforce on a non-GUARDED controller? Yes. Method-level annotations are enforced unconditionally.
`FunctionGuardInterceptor.preHandle`:
```java
RequiresFunction methodLevel = handlerMethod.getMethodAnnotation(RequiresFunction.class);
...
RequiresFunction annotation = methodLevel;
if (annotation == null) {
    annotation = AnnotationUtils.findAnnotation(declaring, RequiresFunction.class);
}
if (annotation == null) {
    if (!GUARDED.contains(declaring)) {
        return true;
    }
    ...
}
String username = currentUsername();
AccessDecision decision = accessService.checkAnyAccess(username, annotation.value());
```
`GUARDED` only governs **unannotated** handlers (they fail closed). An annotated handler always reaches
`checkAnyAccess`. That method reads `userRepository.getAllRoles(username)`, consults no sysprop or guard mode, and fails
closed when the function set is empty.

Registration: `WebConfig.functionGuardMappedInterceptor()` is a `new MappedInterceptor(new String[] {"/**"}, functionGuardInterceptor)`
bean, so every handler mapping picks it up.
- **Tranche pin as the registration: yes, but it is a one-way ratchet.** `everyTrancheRouteCarriesItsIntendedFunctions`
  iterates `EXPECTED` and checks only listed keys. `SurfaceInventoryContextTest` dumps the surface and asserts nothing.
  So the row (AC-1) catches removal of the annotation or a change to the path; it cannot catch a new route that was
  never listed. AC-3 (403/200 through the real chain) covers this ticket's route independently.
- `AdviceController` must not join `GUARDED`, and the plan does not propose that. Doing so would fail-close any future
  unannotated handler there, which is fine, but it would also require `FunctionGuardArchTest` changes. Out of scope.

### 3.6 Principle checks
- P1 (close, don't filter): satisfied at PR 2. Violated in the interim; acknowledged in the risks.
- P2 (strictly narrower): satisfied. The function is the same as the SDR rule that applies at ENFORCE
  (`WEB_UI_VIEW_INBOUND_BOL`), the field set shrinks to `{comment}`, and the mode dependency goes away.
- P3: satisfied by D4. See L4 for rollback, which can still break it.
- P4: T4 retirement is allowed by the wording, but see L3.
- **Flag (not a violation):** wms-triage's *invariant-over-instance*. T4 is retired rather than generalised, and option
  C's drift objection is answerable with an invariant. Both are covered below.

## 4. Findings

### Medium

**M1. The "400 (`ApiInvalidParameterException`)" in the plan is a 422 in this codebase.** Plan §5 Fix A: "A missing `id`
returns 400 (`ApiInvalidParameterException`)", and the same for over 255 characters. AC-4 asserts 400.
`RestExceptionHandler`:
```java
private final HttpStatus invalidParameterStatus = HttpStatus.UNPROCESSABLE_ENTITY;
...
@ExceptionHandler(ApiInvalidParameterException.class)
protected ResponseEntity<ApiErrorMessage> handleInvalidParameters(ApiInvalidParameterException ex) {
    ...
    return ResponseEntity.status(invalidParameterStatus).body(ex.getErrorObject());
```
`MethodArgumentNotValidException` (a `@Valid @Size(max=255)` route) also returns `invalidParameterStatus`, i.e. 422.
The cited precedent, SBDEV-3545 `UserRoleController`, is pinned at 422
(`UserRoleControllerUnitTest:141` `status().isUnprocessableEntity()`).
- *Failure scenario:* the executor writes AC-4 as `isBadRequest()` and implements with `ApiInvalidParameterException`.
  AC-4 stays red for a reason the plan never anticipated, and the ralph loop "fixes" it ad hoc, either by changing the
  test to 422 (silently diverging from D3) or by adding a one-off `ResponseStatusException`.
- *Fix:* decide in the plan. Either keep D3's literal 400 and say how it is produced (a controller-side
  `ResponseEntity.badRequest()` or a `ResponseStatusException(HttpStatus.BAD_REQUEST, …)`), or ask Nam to amend D3 to
  the repo-standard 422. D3's substance (reject and leave the row unchanged) is safe either way; only the code differs.
- Note: a malformed body such as `"id":"abc"` gives a `HttpMessageNotReadableException`. The only advice mapping it to
  400 is scoped to `controller.rest`, so for this controller Spring's `DefaultHandlerExceptionResolver` returns 400
  bare. Pin whichever status AC-x claims.

**M2. PIT cannot reach the security-bearing assertions, yet the floor relies on it.** Plan §8: "mutation-check every
assertion with PIT on `AdviceService` and `AdviceController`".
- The pom's PIT block is explicitly scoped to `-DtargetTests=…UnitTest`. Surefire excludes `**/*IntegrationTest.java`.
- AC-1 (tranche context test), AC-2 (Testcontainers IT), AC-3 (real filter chain), AC-4 (IT) and AC-B1 to AC-B5 are
  context or IT tests that PIT will not execute. `AdviceControllerUnitTest` uses `setupMockMvc`, which has no
  interceptor, so even the unit lane cannot kill "delete `@RequiresFunction`".
- *Failure scenario:* PIT reports a strong score from unit tests on `AdviceService.setComment`. The two mutants that
  matter for this ticket, "drop the gate" and "bind the entity", are never shown red, and the floor is marked met.
- *Fix:* list the hand mutants in §8, each with the AC that must go red:
  - (a) delete `@RequiresFunction` → AC-1 and AC-3;
  - (b) `@RequestBody Advice` + `save` → AC-2;
  - (c) remove the length check → AC-4;
  - (d) set `clientId`/`externalid` from the request → AC-2;
  - (e) PR 2: drop `Advice.class` from `SDR_WRITE_WITHDRAWN` while also deleting the old method → AC-B1 and AC-B2;
  - (f) PR 2: retire T4 without replacement → the reviewer checks AC-B4.

  Keep PIT for the service's branches.

**M3. Option C was rejected on a reason that no longer holds, so the interim exposure is larger than it needs to be.**
RALPLAN-DR row C: "collection POST bypassed the same annotation before (SBDEV-3215)". That bypass is closed on both
types:
```java
private void configureAdviceCollectionCreateWriteExposure(RepositoryRestConfiguration config) {
    config.getExposureConfiguration()
        .forDomainType(Advice.class)
        .withCollectionExposure((metadata, httpMethods) -> httpMethods.disable(WRITE_VERBS));
```
```java
MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN = { Section.class, Boxtype.class, Client.class, Location.class,
        Sysprop.class, Cyclecount.class, UserGroup.class, UserRole.class };
```
- *Failure scenario:* PRD keeps accepting `PATCH /v3/advice/{id} {"clientId":…, "type":"REGULAR"}` from any `wms_user`
  for the whole PR 1 → PR-W → PR 2 train. An interim C-style fence in PR 1 would have closed it one train earlier at
  almost no cost.
- *Fix:* the section 2 synthesis. At minimum, correct row C's "Against" text. **This is a flag for Nam, not an override
  of D4.**

### Low

**L1. The closed-notice textarea also echoes on load. The plan treats S1 as user-initiated only.**
`closedNoticeDescription.vue`: `mounted() { this.setInitialComment() }` and `watch.noticeDetails → this.setInitialComment()`
set `comment`. The `comment` watcher then fires `saveComment` after 700 ms. So after PR-W, **every view** of a closed
notice that has a comment sends `POST /advice/setComment`.
- It is benign in the DB: Hibernate does not dirty-check an unchanged value, so there is no UPDATE and no `@Version`
  or `modified` bump. That matches `db-verification.md`, where the last commented-advice `modified` is 2025-03-28
  despite page views.
- It does affect M2 ("reload" itself POSTs), the request-log volume, and the L4 blast radius.
- *Fix:* say so in §0 S1 and in M2. Optionally add AC-5b: "setComment with the unchanged value leaves `version`
  unchanged". This pins idempotency, and the plan already claims "a replay re-sets the same comment". No UI behaviour
  change is needed (out of scope; D1 covers only cycle count).

**L2. Risk row 2 says "new UI gets a 404". It is more likely a 405.** Without PR 1, `POST /v3/advice/setComment` has no
MVC match. It falls to SDR's item template `/v3/advice/{id}`, which matches the URL but not the method, so the response
is likely 405 `Method Not Allowed` (or a conversion failure on `id`). The user sees the same toast either way; fix the
text so nobody chases the wrong status in a log.

**L3. Generalise T4 instead of retiring it.** The analysis already offered a re-scope (A §3.4 T4). Prefer an invariant
derived from runtime metadata: "for every SDR-exported domain type that has a `state` property and still supports an
item PATCH or PUT, `state` is not writable", with a sensitivity floor on "exported types with a `state` property" (that
is ≥ 2 after PR 2: Advice, Cyclecount, and others in the withdrawn set).
- This stays non-vacuous and catches a future type that re-opens PATCH. Pure retirement leaves that to T3's
  `WITHDRAWN` name list, which only sees names already listed.
- Per Principle 4 and wms-triage invariant-over-instance.

**L4. Rollback has to run in reverse order, and the plan only says "revert any PR".** Once PR 2 is on an environment,
rolling back the web-ui image (or reverting PR-W) restores **both** echo-on-load PATCHes. On that environment every
closed-notice view with a comment and every planned-cycle-count view with a comment would then 405 and toast "Request
failed". *Fix:* in §5.1 and checklist (8), say: revert PR 2 before PR-W, and never roll the PRD web-ui image back past
PR-W while PR 2 is deployed.

**L5. Driver 2 ("promoted independently") understates how the repos are coupled.** Both repos ship in one paired OWL
release (see section 2), so the practical rule is in release terms:
- PR 1 and PR-W can ride the **same** OWL release only if the api deploys first. Otherwise PR-W rides release N+1.
- PR 2 merges only after the release that carries PR-W reaches `main` (D4, unchanged).

The mitigation in risk row 2, "check that `release` carries PR 1 before PR-W is promoted", should name **api `main`**
before **web-ui `main`**, not only `release`. Devops promotes, so the PR bodies must say this in release terms.

**L6. With `NON_NULL` serialization, a cleared comment drops out of the response body.** The primary mapper sets
`mapper.setSerializationInclusion(Include.NON_NULL)`, so returning `{id, comment:null}` serializes as `{id}`. AC-5 must
assert by DB reload, or with `jsonPath("$.comment").doesNotExist()`, not `.value(nullValue())` on a key that is not
present. The UI ignores the body, so there is no functional impact.

**L7. Pin the meaning of "length" and fix the plan's numbering.**
- *Length:* say `String.length()` (UTF-16 code units). It matches HTML `maxlength`, which also counts code units, and
  it is conservative against PG `varchar(255)`, which counts characters. It can never let through a value the DB
  rejects. A `codePointCount` check would diverge from the textarea.
- *Numbering:* the plan jumps from §2 to §4 (there is no §3), and puts "5.1 Prerequisites" under "## 7". Check that
  `plan-state.sh` still parses §5.1 (it keys on that section), or renumber.

## 5. Things verified true (no action needed)
- No `@RepositoryEventHandler` handles Advice or Cyclecount (`SdrCacheEvictionEventHandler` covers
  Client/Location/Sysprop/Itemdata; `PutawayConfigRepositoryEventHandler` covers putaway types). Moving the comment
  write off SDR drops no side effect.
- `Advice` and `Cyclecount` inherit `@Version Integer version` and `@LastModifiedDate modified` (through
  `@EntityListeners(AuditingEntityListener.class)`) from `AbstractBaseEntity`. The entity-save path bumps both when the
  value changes.
- Fix C counts: `MUST_STAY_WRITABLE` is {Section, Advice, Boxtype, Client, Cyclecount, Location, Sysprop, UserGroup},
  so 8 → 6. `WITHDRAWN` is pinned at `hasSize(51)`, so 51 → 53. After PR 2, none of the 6 remaining types declares a
  `state` field (grepped all 6 plus `AbstractBaseEntity`: 0 each), so T4's `isGreaterThanOrEqualTo(2)` goes red as the
  plan predicts.
- The web route guard `'/receiving/closedNotice/:id': 'WEB_UI_VIEW_INBOUND_BOL'` exists on **both** web-ui `develop` and
  `main` (`util/appMenuList.js:169`), so the new 403 path cannot fire on a page users can reach.
- `saveComment` is unchanged across web-ui `develop` and `main`: `$patch(/advice/${data.id}, data)` at
  `store/receiving/inboundNotices.js:408-416`, and `$patch(/cyclecount/${data.id}, data)` at
  `store/internalOps/cycleCount.js:259-267`.

## References
- `v2/wms2-api/src/main/java/net/aim_ai/wms/WebConfigurer.java:71-122`: FAIL_ON_UNKNOWN_PROPERTIES=false (three places)
- `v2/wms2-api/src/main/java/net/aim_ai/wms/RestConfiguration.java:28-29` (WRITE_VERBS), `:452-565` (SDR_WRITE_WITHDRAWN),
  `:567-582` (configureUnwrittenResourceWriteExposure), `:640-644`, `:682-686`, `:798-810`, `:857-881`, `:887-892`
- spring-data-rest-core 4.5.7 `ExposureConfiguration.TypeBasedExposureConfigurer.withItemExposure`: `andThen` composition
- `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/AdviceController.java:34-35, 142-170`: mapping and precedent
- `v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/AdviceRepository.java:19, 36`; `CyclecountRepository.java:15`
- `v2/wms2-api/src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java` (GUARDED set; preHandle method-level
  path); `service/AccessService.java:134-159`; `WebConfig.java` (MappedInterceptor "/**")
- `v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java:50-64` (422), `:89-101` (422), `:200-210`
  (404), `:384-390` (409); `RestEndpointExceptionHandler.java` (basePackages controller.rest, 503)
- `v2/wms2-api/src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java:66-68, 102-108, 948-1008, 1105-1113`
- `v2/wms2-api/src/test/java/net/aim_ai/wms/security/SdrWriteWithdrawalContextTest.java:196-205, 228, 336`;
  `SdrMustStayWritableStateNotPatchableContextTest.java:24-55`
- `v2/wms2-api/pom.xml:543-590` (PIT scoped to unit tests; surefire excludes *IntegrationTest)
- `v2/wms2-web-ui/components/receiving/closed/closedNoticeDescription.vue:97-102, 225-247` (echo-on-load watcher)
- `v2/wms2-web-ui/util/appMenuList.js:169` (route guard, develop and main)
- `git log --first-parent origin/main` in both repos: paired OWL releases, 2026-09-15 to 2026-10-21
