## Summary
All 11 of my round-1 findings (M1–M5, L1–L6) were fixed in the design, not just mentioned. I checked every piece of round-2 surface you listed against `origin/develop` (wms2-api `60ddb320`, wms2-mobile-ui `b03b96a`). Each Spring mechanism the plan depends on works as claimed.

There is one new Medium. One refusal path in the validator still throws a plain `BusinessException`, which reaches the handheld as an untyped 422 — exactly the H1 hazard. The rest are Lows. Of the 5 new types, the typed 422 is the right size and cannot be made smaller safely. The typed 403 is the least proportionate part, but it can be kept as written if it is a pure move.

**Verdict: SOUND-WITH-FIXES.**

## 1. Round-1 findings

| R1 | Status | Evidence |
|---|---|---|
| M1 bare 403 | **Fixed.** The design works (see §2) | `deny()` depends only on `objectMapper`, `meterRegistry` and `declaring.getSimpleName()` (`FunctionGuardInterceptor.java:327-371`) |
| M2 `@Transactional` "or" | **Fixed.** Identical annotation on both overloads; AC-21 compares the two annotations with `equals` | The current annotation is at `CancellationReversalService.java:233` |
| M3 stale Vuex destination | **Fixed in principle.** Wiring gap L-2 below | `pages/cancellation.vue:6` `<cancellation-action v-else-if="process === '2_action'" />` really does remount per entry |
| M4 deploy coupling | **Fixed**: ALTER first, a per-tenant `flyway_schema_history` gate, and §6 rewritten | — |
| M5 `LocationTypeRepository` | **Fixed**, via the validator | `Location.getTypeId()` at :115; the repo exists at `repo/jpa/LocationTypeRepository.java` |
| L1–L6 | **Fixed** | `getEntityLock()` is `Integer` and `NOT_LOCKED` is `int 0` (`WmsConstants:1664`), so `Objects.equals` boxes correctly. `LockRefusalMessages.describe(Integer)` exists |

## 2. Round-2 surface checked against code (no finding unless noted)
- **`AuthzDenialWriter` extraction:**
  - `deny()` reads no other instance state, so a static `write(resp, mapper, registry, decision, controllerTag)` reproduces it byte for byte. `METRIC_DENIED` is `private static`, so it has to move with the code.
  - `logDenial` stays in the interceptor. Its `USER_NOT_PROVISIONED` ERROR branch cannot fire on the RTS path, because the class gate has already passed.
  - There are 14 `new FunctionGuardInterceptor(` sites, all left unchanged.
- **The advice's two constructors:**
  - With one `@Autowired` constructor, Spring uses it.
  - The test sites are 6 `new …MobileEndpointExceptionHandler()` calls in `ReplenishControllerUnitTest` (:160, :313, :416, :433, :469, :519). The seventh is the subclass `TestableMobileEndpointExceptionHandler extends MobileEndpointExceptionHandler` (`MobileEndpointExceptionHandlerUnitTest:53`), whose implicit `super()` call needs the no-arg constructor. It is component-scanned into `@SpringBootTest` contexts, but scoped so it matches nothing.
- **Handler resolution:**
  - `RestExceptionHandler` (`@Order(0)`, unscoped) has no handler for `AccessDeniedException`, `RuntimeException` or `Exception`. The cause-chain rule it documents does not apply, because `FunctionAccessDeniedException` has no cause.
  - Inside `MobileEndpointExceptionHandler`, the depth comparator picks the new handler (depth 0) over `rethrowAccessDenied` (depth 1) and `handleUnexpected`.
- **`HandlerMethod` as a parameter of an `@ExceptionHandler`:** supported. `ExceptionHandlerExceptionResolver` passes the handler method as a provided argument. A `void` return with an `HttpServletResponse` parameter marks the request handled.
- **`checkAnyAccess` and `AccessDecision`:** `AccessService.java:134` returns `AccessDecision(Reason reason, String requiredFunction)`, which has `allowed()` and `reason().metricTag()`. The varargs stub `eq("alice"), eq(FN)` is valid.
- **`RequestRefusedException` on mobile:**
  - The mobile advice is `LOWEST_PRECEDENCE` and has no `BusinessException` handler. So `RestExceptionHandler` (`:143`, order 0, unscoped) renders it, and the new, more specific handler wins inside that advice.
  - `BusinessException(String)` and `(String key, Object...)` are both present. Single-argument `super(msg)` binds to the non-varargs form.
- **ProblemDetail `type`:** `getType()` is a root bean property under any mapper, mixin or not, and `URI` serialises as a string. `forStatusAndDetail` defaults to `about:blank`.
- **Mobile `isRequestRefusal`:** `apiErrorMessage` already reads `data.detail` from these 422s, so reading `data.type` works the same way.
  - `isPositionRefusal(status)` (`store/cancellation.js:77`) is the rule AC-19b must keep.
  - The 403 path still yields `null` from `apiErrorMessage` because the writer puts `reason` at the root.
- **The `customerorderId` watch:** `order` is computed from `state.cancellation.selectedOrder` (`cancellationAction.vue:137`). The watch can only fire if the order changes while the component is mounted. That never happens today, so it is defence in depth, as the plan says.

## 3. Findings

**M-1 — Medium. Ambiguous location names still reach the client as a plain `BusinessException`, which brings back H1 for that input.**
- `ScannedCodeResolver.java:103-113`:
  ```java
  @throws BusinessException keyed {@code scanCodeAmbiguousLocation} when two or more locations differ from each other only by letter case
  ...
  return single(matches, scanned, WmsConstants.MSG_SCAN_CODE_AMBIGUOUS_LOCATION);
  ```
- Validator step 3 calls `canonicalLocationName(trimmed)` before the FOR UPDATE read. When two lanes differ only by case, this throws a plain `BusinessException`, which becomes an untyped 422.
- On mobile, `isPositionRefusal(422)` is true. Every position is marked waivable and the loop keeps going, giving N POSTs and N Waive buttons for a request-level fault. That is H1's exact shape.
- **Fix:**
  - In `RtsDestinationValidator`, wrap the call: `catch (BusinessException e) { throw new RequestRefusedException(MSG_SCAN_CODE_AMBIGUOUS_LOCATION, trimmed); }`.
  - State the invariant in §3.2: *every exception the validator throws is a `RequestRefusedException` or a `FunctionAccessDeniedException`.*
  - Add `RDVUT.ambiguousCase_refusedTyped`, asserting the class plus `getKey()`.
  - Mutant: drop the catch, and that test goes red.

**L-1 — Low. AC-8d calls the handler directly, so it cannot see which advice handles the exception, and M-m is credited to the wrong test.**
- The direct call never goes through the cross-advice ordering or the depth comparison.
- The existing MockMvc harness would hit a null-pointer exception if a test pushed `FunctionAccessDeniedException` through it. `TestableMobileEndpointExceptionHandler` uses the no-arg constructor, so its mapper and registry are null.
- M-m ("throw a plain `AccessDeniedException`") is a change to the service, so AC-8d cannot detect it. AC-8 / RDVUT kill it, but only if they assert `isInstanceOf(FunctionAccessDeniedException.class)`.
- **Fix:**
  - Add `@GetMapping("/test/function-denied")` to `ThrowingController`.
  - Give `TestableMobileEndpointExceptionHandler` a constructor `(new ObjectMapper(), new SimpleMeterRegistry())`.
  - Assert 403 plus the header through `setControllerAdvice(new RestExceptionHandler(), …)`.
  - Mutant: delete the new handler; the rethrow surfaces and the test goes red.
  - Re-attribute M-m to AC-8.

**L-2 — Low. The mobile return-value wiring is incomplete.**
- `cancellationAction.vue` currently has:
  ```js
  complete() {
    this.$store.dispatch('cancellation/completeSelectedPositions', { … })
  },
  ```
  It is not `async` and does not await, so `destinationError` can never be assigned from the result.
- `completeSelectedPositions` also has bare `return`s at `if (!selected.length) {… return }` and `if (!refreshed) return`. The `!refreshed` one sits after the loop, so a request refusal followed by a failed re-read loses `requestRefusal`.
- **Fix:**
  - Make `complete()` `async` and `await` the dispatch.
  - Have every return path in the action return `{ requestRefusal }`. Capture `requestRefusal` before `fetchDetail` runs.
  - Extend AC-19 with "refresh fails → `requestRefusal` still returned".

**L-3 — Low. The refusal is shown twice.**
- `completeReversal`'s catch block runs `toastError(this.$toast, context, message)`, so a typed 422 is both toasted and shown under the scan field.
- **Fix:** skip the toast when `isRequestRefusal(error)`, or state in §3.5 that both are shown on purpose.

**L-4 — Low. Two comments become false.**
- `Authority.java:141` says "**Emitted by `FunctionGuardInterceptor` and nowhere else**".
- `FunctionGuardArchTest.java:1172` says "THIS plan the header's first and only emitter".
- After the change, the mobile advice also emits the header.
- **Fix:** reword both to "emitted only through `AuthzDenialWriter` (interceptor plus `MobileEndpointExceptionHandler`)", and add them to §0 as rows. This repo has a history of a rule outliving its retitled section.

**L-5 — Low. The controller tag is not derived the same way as the interceptor's.**
- The interceptor uses `handlerMethod.getMethod().getDeclaringClass()` (`:197`).
- The plan uses `hm.getBeanType()`. These differ for handlers inherited from a base class such as `AdminController`.
- They give the same value for `completeReversal`, but the next caller may not be so lucky.
- **Fix:** use `hm.getMethod().getDeclaringClass().getSimpleName()`.

**L-6 — Low. The no-arg constructor leaves null collaborators behind.**
- **Fix:** make it `this(new ObjectMapper(), new SimpleMeterRegistry())`, or null-guard the handler, so an advice built for a test cannot throw a null-pointer exception on a denial.

**L-7 — Low. `FunctionAccessDeniedException` is `Serializable` through `RuntimeException`, but its `AccessDecision` field is not.**
- **Fix:** declare the field `private final transient AccessDecision decision`.

## 4. Is the scope proportionate? (steelman)
**Alternative S:** "Mobile treats any 422 on a request that carries `destinationLocationName` as request-level." This needs no new types on the API side.

S is **unsound**. Position-level 422s still happen when a destination is set:
- the null-source refusal (F3 orders destination validation *before* it);
- the refusals from 3326 and 3353 (AC-13);
- "amount=… requested is more than available=…", which applies to exactly the in-scope WineCo row `pos 35841889`.

Under S, the first such row breaks the loop. That row loses its Waive button, which is the remedy SBDEV-3740 provides for it, and the positions after it are never tried.

There is a weaker variant, S′: "not waivable, but keep going". It is safe because nothing gets wrongly waived. But it sends N POSTs for a locked lane and still hides Waive for genuine position-level refusals. The root `type` field is therefore the smallest discriminator that works: one exception, one handler and one JavaScript predicate.

**The 403 machinery is where the proportionality question really sits:**
- The scan field is hidden unless the function is granted. So the 403 is reachable only through a grant revoked mid-session, the rollback window, or a crafted request.
- The loop already breaks on 403. Without the machinery, the cost is an opaque "(HTTP 403)", at most one wasted retry, and no metric.
- **Smaller sound option:** leave `FunctionGuardInterceptor` untouched. Use the writer only from the advice, and add a parity test that runs both the interceptor and the writer on the same `AccessDecision` and asserts identical body, header and metric.

| Option | Pros | Cons |
|---|---|---|
| Plan: extract the writer from `deny()` | One source for the wire contract | Touches the guard on every gated route. Safe only as a pure move, gated on `FunctionGuardInterceptorUnitTest` and `ReplenishOrderControllerGateH2Test` passing unchanged |
| Duplicate the code plus a parity test | Zero change to the interceptor | About 15 duplicated lines; the parity test has to be kept |
| Untyped 403 (round-1 state) | Smallest | Opaque toast, possible retry, no metric |

My recommendation is to keep the plan's extraction, provided the PR shows `deny()` as a pure move with no edits to its logic and the interceptor test suites are part of the gate. Otherwise take the parity-test variant. Either way, no reviewer should spend another round on this.

## 5. Consensus addendum
- **Antithesis:** a ~1/week feature now has 5 new production types and touches the guard on every gated route. Most of the extra size (the typed 403) protects paths an operator cannot reach without crafting a request.
- **Tradeoff tension:** one denial wire contract vs. keeping the blast radius off the universal guard.
- **Synthesis:** keep the typed 422, which is required. Land the 403 as a pure-move extraction, or as advice-only with a parity pin.

## Verdict: **SOUND-WITH-FIXES**
- M-1 must be fixed before the TDD gate.
- L-1 through L-7 can be folded into the plan text and tests.

## References
- `/home/nampark/dev/wms-claude/v2/wms2-api` (origin/develop `60ddb320`):
  - `src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:197, :282-290, :327-371`
  - `src/main/java/net/aim_ai/wms/exceptions/MobileEndpointExceptionHandler.java:47-48, :80-82`
  - `src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java:29-48, :143-150`
  - `src/main/java/net/aim_ai/wms/service/AccessService.java:134-159`
  - `src/main/java/net/aim_ai/wms/security/AccessDecision.java:17, :92-106`
  - `src/main/java/net/aim_ai/wms/exceptions/BusinessException.java:42-61, :125-146`
  - `src/main/java/net/aim_ai/wms/service/ScannedCodeResolver.java:96-113`
  - `src/main/java/net/aim_ai/wms/Authority.java:141`
  - `src/main/java/net/aim_ai/wms/model/Location.java:11-12, :51, :115, :123`
  - `src/main/java/net/aim_ai/wms/service/CancellationReversalService.java:233-244`
  - `src/test/java/net/aim_ai/wms/unit/exceptions/MobileEndpointExceptionHandlerUnitTest.java:53, :97`
  - `src/test/java/net/aim_ai/wms/unit/controller/mobile/ReplenishControllerUnitTest.java:160, :313, :416, :433, :469, :519`
  - `src/test/java/net/aim_ai/wms/unit/config/FunctionGuardArchTest.java:1153-1174`
- `/home/nampark/dev/wms-claude/v2/wms2-mobile-ui` (origin/develop `b03b96a`):
  - `store/cancellation.js:77, :230-330, :401-441`
  - `components/cancellation/cancellationAction.vue:137, :196-266`
  - `pages/cancellation.vue:3-6, :26-27`
  - `util/apiError.js:45-65`
  - `plugins/axios.js:78-135`
- Plan: `/home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-3741-rts-choose-staging-lane-destination.md` (§3.2 step 3, §3.2.1, §3.2.2, §3.5, §7.1 AC-8d and M-m)