## Summary
I checked the plan against wms2-api `60ddb320` and wms2-mobile-ui `b03b96a`, both re-fetched today and unchanged. Option A holds up: every API symbol the plan names exists and the check order works. There are no High findings. There are 5 Medium and 6 Low.

The most important Medium is M1. The service throws a programmatic `AccessDeniedException`, which reaches the wire as a bare 403 from Spring Security. That 403 has no `X-Authz-Denied` header and no `reason` body, so it breaks the denial contract the mobile client is built on.

**Verdict: SOUND-WITH-FIXES.**

## 1. Antithesis (steelman against Option A)
The plan's own text undercuts A's main advantage, "binds every caller":
- `resolveDestinationName` is kept apart from `validateOperatorDestination` so that 3733's system-chosen fallback can skip the operator gate.
- So the only caller that will ever pass operator input is the controller. "Holds for any future caller" protects a caller the design already exempts.

Meanwhile, Option C (a separate route with a method-level `@RequiresFunction(RTS_CHOOSE_DESTINATION)`) would get several things for free:
- the interceptor's typed denial: the `reason`/`requiredFunction` body, the `X-Authz-Denied` header, the `wms2.authz.denied` metric and `logDenial`. A loses all of these (M1);
- visibility in GOLDEN_MAP and `FunctionGuardArchTest`, where A needs a hand-maintained mutation suite (M-a to M-e).

The con the plan gives for C, "VIEW would have to be re-listed", is overstated. That route only needs the new function, and its holders are outbound-manager and super-admin. The other con, "duplicates the flow", is avoidable because both routes can call the same 4-arg service method. What really blocks C is D1's request shape, which is not open. So A wins on D1, not on engineering merit, and it should take C's wire behaviour (synthesis below).

## 2. Tradeoff tension and synthesis
**Tension:** keeping the gate inside the service vs. keeping a single HTTP denial contract.
- Only `FunctionGuardInterceptor.deny()` produces the contract `plugins/axios.js` and `util/apiError.js` depend on.
- `FunctionGuardInterceptor.java` says so itself: "wms2-mobile-ui/plugins/axios.js:106 gates on the header's PRESENCE to short-circuit its retry path".
- A service-thrown `AccessDeniedException` bypasses that contract entirely.

**Synthesis:** keep G1, but give its denial the interceptor's wire format.
1. Add `FunctionAccessDeniedException extends AccessDeniedException` carrying an `AccessDecision`. Get that decision from `accessService.checkAnyAccess(getAuthorizedName(), fn)` rather than `doesUserHaveAnyAccess`, so the reason is known.
2. Pull the body and header writing out of `FunctionGuardInterceptor.deny()` into a shared static helper, keeping the explicit map (the javadoc explains why a ProblemDetail must not be used).
3. In `MobileEndpointExceptionHandler`, add `@ExceptionHandler(FunctionAccessDeniedException.class)`. Spring's `ExceptionDepthComparator` picks it over the generic `AccessDeniedException` rethrow. It writes 403 with the typed body and the `X-Authz-Denied` header, and increments the denied metric.

Callers that are not mobile still see an `AccessDeniedException`. The cost is about 30 lines and one more mobile-advice unit test.

## 3. Soundness findings

**M1 — Medium. The destination 403 is a bare Spring Security 403, not the typed denial the mobile client expects.**
- *How the 403 is produced:*
  - `MobileEndpointExceptionHandler.java:80-82` has `@ExceptionHandler(AccessDeniedException.class) protected void rethrowAccessDenied(AccessDeniedException ex) { throw ex; }`.
  - `SecurityConfiguration.filterChain` sets `.oauth2ResourceServer(...)` and has no `.exceptionHandling(...)`; `git grep accessDeniedHandler` over `src/main` finds nothing.
  - So the default `BearerTokenAccessDeniedHandler` renders it: a 403 with an empty body and only a `WWW-Authenticate` header.
- *What the mobile client does with it:*
  - `plugins/axios.js` `retryCondition` gets past `if (headers['x-authz-denied'] ...) return false` because the header is missing. It calls `app.$kc.updateToken(5)` and retries if the token was refreshed (`retries: 3`).
  - In practice that means at most one wasted retry when the token is close to expiry. It is not a logout, because `updateToken` returns false on a fresh token.
  - `apiErrorMessage` then falls through to `` `${fallback} (HTTP ${status})` ``, so the operator sees "Failed to complete reversal. (HTTP 403)". The message does not name the missing function.
  - There is no `wms2.authz.denied` count and no `logDenial` line.
- *Where the plan is wrong:* §6 and AC-17 say the 403 "surfaces through the existing error path", which is true only in this degraded form. The AC-17 Jest test mocks `$axios`, so it cannot see the retry interceptor.
- *When it is reachable:*
  - a grant revoked mid-session (`home.ensureRolesLoaded` fetches functions once per boot);
  - the window during the §8 "delete grants first" rollback;
  - crafted requests.
- *Fix:* apply the synthesis above. Add a test: `MobileEndpointExceptionHandlerUnitTest`, `FunctionAccessDeniedException` → 403, `X-Authz-Denied` = function name, and `$.reason` at the top level. Mutation check: drop the header and the test goes red.

**M2 — Medium. Transaction annotations on the two overloads: the "or" in §7.5 row 2 lets an unsafe option through.**
- *Current code:* `CancellationReversalService.java:233-234` has `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class}) public CancellationDetailDto completeReversal(Long coId, String notes, List<Long> positionIds)`.
- *Plan text:* "the overload must carry the same annotation or be the annotated method."
- *Why the "or" is unsafe:* the 3-arg form delegates through `this.completeReversal(..., null)`, which is self-invocation and bypasses the proxy.
  - If only the 4-arg form is annotated, every proxied call to the 3-arg form runs with no transaction. That covers the ITs (14+2+1 sites) and any future internal caller.
  - In that case `findPendingReversalsForUpdateByCustomerorderId` (PESSIMISTIC_WRITE) throws `TransactionRequiredException`.
  - If only the 3-arg form is annotated, the controller's 4-arg call runs with no transaction in production.
- *Order of checks:* the order the plan wants (input checks → gate → location validation → FOR UPDATE) is achievable. The method's first DB access is at :244, nothing is written before it, and `AccessDeniedException` is a `RuntimeException`, so it rolls back by default.
- *Fix:* state it as an invariant. Both overloads carry the identical `@Transactional(...)`, and the controller calls the 4-arg form. Pin it with a reflection unit test asserting both `Method`s carry `tenantTransactionManager` and the same `rollbackFor`. Mutation check: remove either annotation and the test goes red.

**M3 — Medium. `rtsDestination` in the Vuex store goes stale from one order to the next.**
- *Where the state lives:*
  - `persistedState.client.js` persists everything except `home` authz state.
  - `pages/cancellation.vue` calls `resetState` only in `created()`.
  - After a completion, `store/cancellation.js:335` runs `if (!stillPending) context.commit('SET_PROCESS', context.state.sourceFlow)` without resetting.
- *Effect:* a lane scanned for order A is pre-filled, and if the operator does not notice, sent for order B. It also survives across this page's lifetime. AC-18 (reset clears it) does not cover this, because `resetState` is never called between orders.
- *Fix:* keep the scan value as component-local `data()` in `cancellationAction.vue`, which is not persisted and resets on each `2_action` mount, and pass it as an argument to `completeSelectedPositions` → `completeReversal`. Alternatively, clear it on `SET_SELECTED_ORDER`. Add a Jest test: complete order A with a lane, open order B, and the payload has no `destinationLocationName`.

**M4 — Medium. §6's claim "`hibernate validate` only checks mapped columns" is wrong for production, and it hides a deploy coupling.**
- *Evidence:*
  - `application.properties:133` has `spring.jpa.hibernate.ddl-auto=none`.
  - `StartupFlywayMigrationRunner` has the comment "Contract: migrations never take the app down."
- *Effect:* on a tenant where V2.2.38 fails (an `ALTER TABLE` needs table ownership), the new build boots anyway. Every load or insert of `CustomerorderCancellationLog` then fails, which includes:
  - `CancellationLogService.java:57/88` (`new CustomerorderCancellationLog()` … `logRepository.save(log)`), which is on the order-cancel path;
  - `PendingReversalReconciliationJob`.
- *Likelihood:* V2.2.34 ALTERed the same table, which is evidence this works on all tenants, so this is Medium, not High. But §0 marks A22 as "X" without recording the coupling.
- *Fix:*
  - Add a §8 step: confirm V2.2.38 shows `success=true` in `flyway_schema_history` on all six tenant DBs, or use the `FlywaySchemaMetrics` gauge, before declaring the deploy good.
  - Record in §6: "an unmigrated tenant breaks order cancellation, not just RTS."
  - Keep the ALTER first in the script, so that if it fails the function insert also rolls back and the scan field stays hidden.

**M5 — Medium. Flow-bin check: the dependency list is incomplete.**
- `Location` stores only `private Long typeId;`.
- `StockunitService.java:399-401` resolves the type through `locationTypeRepository.findById(destinationLocation.getTypeId())` and compares with `locationType.getSltname().equals(WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN)` (the constant is `"flowbin"`, `WmsConstants.java:939`).
- §4 lists three new constructor dependencies. `LocationTypeRepository` is a fourth; without it step 6 cannot be written.
- *Fix:* add it, giving 17 constructor arguments. Use `WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN.equals(type.getSltname())` (null-safe).

**L1 — Low. The `staginglane` accessor does not exist as written.**
- `Location.java:33` has `private Boolean staginglane;` and line 123 has `public Boolean getStaginglane()`. There is no `isStaginglane()`.
- *Fix:* use `!Boolean.TRUE.equals(loc.getStaginglane())`. Null is refused.

**L2 — Low. The §0 and §7.1 claim "existing reversal tests are not edited" is false.**
- Both constructor call sites must change:
  - `CancellationReversalServiceUnitTest.java:128` (`service = new CancellationReversalService(logRepository, …, unitloadTypeRepository);`)
  - `StockunitServiceParcelSourceRefusalUnitTest.java:609`
- *Fix:* add them to §0 as covered sites with a "constructor-only edit" note.

**L3 — Low. The DTO "mapper" is not a separate class.**
- The only production construction site is `CancellationReversalService.toDetailDto`, at about :873 (`CancellationLogEntryDto entry = new CancellationLogEntryDto();`).
- *Fix:* name it in §4.

**L4 — Low. §3.2's F3 wording contradicts its own order of checks.**
- It says the null-`pickfromlocationname` refusal "stays ahead of any destination logic". In fact `validateOperatorDestination` runs before the FOR UPDATE read, so it runs before that refusal (`CancellationReversalService.java:274-277`).
- Behaviour is fine: AC-7b still holds with a valid destination. But a row with both a bad destination and a null source reports the destination error.
- *Fix:* reword to "the null-source refusal still applies after destination validation passes".

**L5 — Low. M7's SQL names the wrong tables.**
- The tables are `mywms_function` and `mywms_role_mywms_function` (V2.2.34: `INSERT INTO mywms_function (id, version, client_id, name, number, function)`), not `function`.

**L6 — Low. The §8 rollback "delete the grants first" does not reach running handhelds.**
- `home.functions` is not persisted, but `ensureRolesLoaded` fetches it once per app boot. Devices already running keep showing the scan field until they reload.
- *Fix:* add "and reload handhelds", or accept a short window. If M1's fix lands, that window gives a clean typed 403 instead.

**Verified as claimed (no finding):**
- *Access check:* `AccessService.doesUserHaveAnyAccess(String username, String... functions)` exists at `AccessService.java:107`.
- *Principal match:* `getAuthorizedName()` returns `authentication.getName()`, and `FunctionGuardInterceptor.currentUsername()` returns `authentication == null ? null : authentication.getName()`. They match whenever the request is authenticated; the only divergence is `getAuthorizedName`'s `getUserName()` fallback when there is no authentication, which cannot happen past the filter chain.
- *Advice order:* `RestExceptionHandler` (`@Order(0)`, unscoped) has no `Exception` or `AccessDeniedException` handler, so the mobile rethrow is reached.
- *Mobile loop:* `store/cancellation.js:289` has `if (outcome.status === null || outcome.status === 401 || outcome.status === 403) break`.
- *Location cache:* `LocationService.java:100-101` has `@Cacheable(value = "locations", …) public Location getByName`.
- *Uncached read:* `transferStock` uses `locationRepository.findByName(locationName)` at `StockunitService.java:396`, after `scannedCodeResolver.canonicalLocationName` (`ScannedCodeResolver.java:106`).
- *Repository signature:* `LocationRepository.findByName` returns `Optional<Location>`.
- *Lock messages:* the downstream refusal is "Destination location=… is locked=" at `StockunitBusinessService.java:~314`. Its `lock` is unboxed, so refusing a null lock up front also avoids a latent NPE.
- *Unknown JSON fields:* `FAIL_ON_UNKNOWN_PROPERTIES=false` is set in `WebConfigurer.java:78/108/121`.
- *Function provisioning:* the waive constant is at `WmsConstants.java:484`, the initDB waive grant at `UtilRestController.java:432`, and the "Both are required" comment at :422.
- *Tests and migrations named in the plan:* `CancellationWaiveMigrationIT` exists under `integration/schema/`, and so do `MobileEndpointExceptionHandlerUnitTest` and `OrderCancellationControllerUnitTest`. V2.2.34 already shows the ALTER plus function plus grant pattern.
- *No reflective lookups:* no test looks up `"completeReversal"` reflectively, so the overload breaks nothing.
- *Flyway number:* V2.2.38 is free. I swept `git ls-tree -r` over all 420 `refs/remotes/origin` (down from the plan's 422; branches were deleted since). Only V2.2.35, 36 and 37 were found, which is the expected control.
- *Rollback (§8):*
  - "Revert mobile first" is correct.
  - "The column is harmless if left in place" is correct, because `ddl-auto=none` and the old entity does not map it.
  - An applied V2.2.38 on a reverted build is an ignored "future" migration (`StartupFlywayMigrator.java:38-40`, where `ignoreMigrationPatterns` defaults to `*:future`).

## 4. Verdict: SOUND-WITH-FIXES
- Fix before the gate: M1 (use the synthesis), M2 (annotate both overloads and pin it), M3 (component-local destination) and M5 (add `LocationTypeRepository`).
- Fold into the plan text: M4's rollout check and L1–L6.

## Trade-offs
| Option | Pros | Cons |
|---|---|---|
| A as written | Minimal diff; class gate unchanged | Bare 403: opaque toast, possible retry, no denial metric |
| A plus the synthesis (typed exception and mobile handler) | Same wire contract as the interceptor; still binds any service caller | About 30 lines; the `deny()` body writer has to be shared |
| C (separate route) | Typed 403 and arch-test visibility for free | Contradicts D1's request shape, which is not open |

## References
- `/home/nampark/dev/wms-claude/v2/wms2-api` origin/develop:
  - `src/main/java/net/aim_ai/wms/service/CancellationReversalService.java:233-244, :274-277, :429, :873`
  - `src/main/java/net/aim_ai/wms/exceptions/MobileEndpointExceptionHandler.java:47-48, :80-82`
  - `src/main/java/net/aim_ai/wms/SecurityConfiguration.java:136` (no `exceptionHandling`)
  - `src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:327-372, :373-375`
  - `src/main/java/net/aim_ai/wms/service/AccessService.java:82, :107, :134`
  - `src/main/java/net/aim_ai/wms/SecurityContextUtils.java:70-76`
  - `src/main/java/net/aim_ai/wms/service/StockunitService.java:394-401`
  - `src/main/java/net/aim_ai/wms/model/Location.java:31-33, :123`
  - `src/main/resources/application.properties:133`
  - `src/main/java/net/aim_ai/wms/landlord/config/StartupFlywayMigrationRunner.java:~75`
  - `src/main/resources/db/migration/V2.2.34__cancellation_reversal_waive.sql`
  - `src/test/java/net/aim_ai/wms/unit/service/CancellationReversalServiceUnitTest.java:128`
  - `src/test/java/net/aim_ai/wms/unit/service/StockunitServiceParcelSourceRefusalUnitTest.java:609`
- `/home/nampark/dev/wms-claude/v2/wms2-mobile-ui` origin/develop:
  - `plugins/axios.js:78-135`
  - `util/apiError.js:45-65`
  - `store/cancellation.js:3-25, :272-289, :335, :404`
  - `pages/cancellation.vue:25-27`
  - `plugins/persistedState.client.js:30-60`
  - `store/home.js:170-215`