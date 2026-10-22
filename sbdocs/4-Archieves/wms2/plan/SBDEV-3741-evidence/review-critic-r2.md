**VERDICT: APPROVE.** I found no High findings. Three Mediums and five Lows remain. Each has a small, concrete fix that can be folded in at the TDD gate without another consensus round.

Checked against origin/develop: wms2-api `60ddb320`, wms2-mobile-ui `b03b96a`, both re-fetched.

**Mode:** THOROUGH. I did not escalate: there is no Critical, there are fewer than three Majors, and the issues are isolated rather than systemic.

### 1. Were the round-1 findings fixed?

**Fixed:** H1, M1–M6, L1–L6, L8 and both OQs, with one exception. H1's invariant ("every request-level refusal is typed") is not yet complete; see Medium 1 and 2. I checked these against code:
- The DTO null-omission claim holds: `WebConfigurer:79,122` sets NON_NULL.
- `BaseRollbackIntegrationTest` omits `@Transactional`, so CRDIT commits and must assert by id. The plan says it does.
- The 7 no-arg test sites for `MobileEndpointExceptionHandler` are correct: 6 in `ReplenishControllerUnitTest` plus the `TestableMobileEndpointExceptionHandler` subclass.
- The keyed constructor `BusinessException(String, Object...)` exists. The message constructor resolves through `placeholder=%1$s`, so exact-message asserts work.

**L7 partial rejection: correct on persistence, but the replacement text is still inaccurate.**
- Correct: `persistedState.client.js:40-50` strips `functions` from what is written, and lines 61-63 re-assert an empty value on boot. My premise that the functions are persisted was wrong.
- Inaccurate: §8 says `"home/refreshMenus does not re-fetch it"` and `"Until reload, a handheld can still show the scan field"`.
  - `refreshMenus` itself doesn't re-fetch. But it does `this.$router.push('/')` (`store/home.js:265-268`), and so does `goBack()` in `cancellationAction.vue`.
  - Landing on Home remounts `pages/index.vue`. Its `mounted()` runs `handleAuthentication` → `redirectPage` → `home/setMenus` (`:243`), which commits `setFunctions` (`store/home.js:229`).
  - So the stale window ends at the next return to Home, not at an app reload. The plan's remedy is still safe, just over-strong. Logged as Low 1.

### 2. Is every exception the validator can throw typed?

No. There are two untyped 422 routes and one 500 route.

### Medium

**Medium 1. `ScannedCodeResolver.canonicalLocationName` throws a plain `BusinessException`, which reopens the H1 hazard.**
- Evidence: `ScannedCodeResolver.java:106-114`. When the exact `findByName` misses and two or more locations differ only by case, `single(..., MSG_SCAN_CODE_AMBIGUOUS_LOCATION)` throws a keyed plain `BusinessException`.
- That renders as a 422 without `type`, which `isPositionRefusal` treats as waivable (`store/cancellation.js:77`). The loop does not break (`:289`). Result: N POSTs and N Waive buttons, exactly the shape §3.2.2 claims is closed.
- It is reachable. WineCo PRD has 2 such case-collision pairs today (`adampetersen`, `michaelmorgan`, both non-lane; queried 2026-10-12). Scanning either name in a non-stored case triggers it.
- The plan's step 3 doesn't mention it, and §6 row "Error shapes" claims `"the mobile loop stops on both without marking rows waivable"`.
- **Fix:**
  - In `RtsDestinationValidator`, catch the resolver's `BusinessException` and rethrow `new RequestRefusedException(e.getKey(), <params>)`. Alternatively, add a `RequestRefusedException(BusinessException)` copy constructor that preserves key and params.
  - Add `RDVUT.ambiguousCaseSpelling_refusedTyped`, asserting `getKey()==MSG_SCAN_CODE_AMBIGUOUS_LOCATION` and class `RequestRefusedException`.
  - Add mutant M-q: let the plain exception escape → red.

**Medium 2. "Unit-load type not permitted on location" is a destination-caused refusal that stays untyped and waivable.**
- Evidence:
  - Whole-container arm: `UnitloadBusinessService.java:~321` throws a plain `BusinessException(MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION, …)`.
  - New-container arm: `StockunitService.java:275` throws the same key when `TRANSFER_DESTINATION_CONSTRAINT_ENFORCED` is on.
- P1 notes `"A lane type that excludes Case would refuse the whole-container arm … record it"`, but nothing types it. §3.2.2 names the in-request lock race as the only residual.
- On a tenant whose lanes exclude Case, or with enforcement on, every affected position gets an untyped 422 and becomes waivable, and the loop runs to the end. That is the SBDEV-3548 fence again, caused by the destination choice.
- **Fix:** pick one.
  - (a) In the 4-arg loop, when `dest != null`, catch a `BusinessException` whose `getKey()` equals `MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION` and rethrow it as `RequestRefusedException` with the same key and params. This matches on the key, not message text, so the §9 "fragile" objection doesn't apply.
  - (b) Make P1 a hard gate: do not grant the function on any tenant where a staging lane excludes Case or the minted type, or where the sysprop is enforced. List it in §3.2.2 as an accepted residual.
  - With (a), add a CRSUT test and a mutant.

**Medium 3. AC-8d's direct handler call cannot see advice resolution, and M-m is credited to a test that cannot see the mutant.**
- AC-8d builds its own `FunctionAccessDeniedException` and calls `handleFunctionDenied` directly. It is blind to three things §3.2.1 relies on:
  - `RestExceptionHandler` (`@Order(0)`) must have no matching handler;
  - `ExceptionDepthComparator` must pick the new handler over `rethrowAccessDenied` (`MobileEndpointExceptionHandler:80`) and `handleUnexpected(Exception)` (`:107`);
  - the `HandlerMethod` argument must resolve.
- M-m ("throw a plain `AccessDeniedException`") is a validator mutation. AC-8d never runs the validator, so the credit is vacuous. What actually kills M-m is AC-8's `assertThrows(FunctionAccessDeniedException.class)`.
- The harness for a real test already exists. `MobileEndpointExceptionHandlerUnitTest` has a `ThrowingController` plus `standaloneSetup(...).setControllerAdvice(new RestExceptionHandler(), new TestableMobileEndpointExceptionHandler())` (around `:97`).
- **Fix:**
  - Give `TestableMobileEndpointExceptionHandler` a `(ObjectMapper, SimpleMeterRegistry)` constructor.
  - Add a `ThrowingController` endpoint that throws `FunctionAccessDeniedException`.
  - Assert via MockMvc: 403, the `X-Authz-Denied` header, root `$.reason`, and the counter.
  - Re-attribute M-m to AC-8. Add a mutant that deletes the new `@ExceptionHandler` method → the MockMvc row gets the rethrow instead → red.

### Low

1. **§8 rollback wording.** Replace "reload the handhelds… refreshMenus does not re-fetch" with: "functions re-fetch when the operator returns to Home (`index.vue` → `setMenus`); a reload also works." Evidence is under item 1 above.
2. **Validator step 6 calls `locationTypeRepository.findById(loc.getTypeId())` with no null guard.** `Location.typeId` is a nullable `Long`, and `findById(null)` throws `IllegalArgumentException`. The codebase guards this explicitly (`UnitloadBusinessService` comment above `:321`). Unguarded, it becomes a mobile catch-all 500 per request. That is not waivable, but the loop doesn't break on 500, so all N requests are sent. **Fix:** `if (loc.getTypeId() == null)`, then refuse typed with the flow-bin/missing-type message; add `RDVUT.nullTypeId_refused`.
3. **The mobile dispatch path is under-specified.**
   - Today `complete()` (`cancellationAction.vue:254`) neither awaits nor returns.
   - `completeSelectedPositions` has two bare `return`s (the empty-selection path and `if (!refreshed) return`), so `{ requestRefusal }` is lost when the re-read fails.
   - **Fix:** state that `complete()` becomes `async` and awaits; return `{ requestRefusal }` on every exit after the loop, including `!refreshed`.
   - The component test "shows destination error" will go red until this is done, so it is not vacuous. It just shouldn't be discovered at the gate.
4. **The typed refusal is shown twice.** `completeReversal`'s catch calls `toastError(...)` (`store/cancellation.js:~430`) before returning, so the operator gets a toast plus the message under the scan field. **Fix:** say whether to keep the toast (it's acceptable) or skip it on `requestRefused`, and pin the choice in AC-19.
5. **New store specs must not `jest.mock('~/util/apiError')`.** `isRequestRefusal` is the layer under test, and current cancellation specs don't mock it. Add one line to §7.2 so the new spec can't mock away the classifier.

### Per-position waivable path with a destination set (SBDEV-3548)

It stays intact for:
- null source (F3, still a plain `BusinessException`, raised after validation);
- 3326 and 3353;
- `amount > available` from `transferStockToUnitLoad`.

These remain untyped 422s. `isRequestRefusal` keys only on root `type`, so they stay waivable and the loop continues. AC-19b pins the plain-422 case.

### 3. AC vacuity

- AC-8d / M-m: Medium 3.
- Component AC-19: Low 3.
- Unchanged from the plan and fine:
  - the CRSUT refusal tests stub the finder, so `never()` has teeth;
  - M-g and M-h are now correctly attributed;
  - AC-8e's root `type` is a real ProblemDetail field, so it sits at the root on any mapper;
  - AC-7c on a non-transactional H2 base commits between calls, so the "between requests" scenario is real.

### 4. Executability

Every named class, test class, path and base class exists on develop:
- `BaseRollbackIntegrationTest`, `RestExceptionHandlerUnitTest`, `CancellationLogEntryDtoSerializationTest`, `MobileEndpointExceptionHandlerUnitTest`, `OrderCancellationControllerUnitTest`, `CancellationWaiveMigrationIT`;
- `FunctionGuard{InterceptorUnit,MockMvcUnit,Arch}Test`, `UtilRestController{Seed,}UnitTest`, `StockunitServiceParcelSourceRefusalUnitTest`;
- `LocationTypeRepository`, `AccessService.checkAnyAccess` (`:134`, returns `AccessDecision`), `StartupFlywayMigrationRunner`, `WebConfigurer`.

New classes are correctly marked new. An implementer can proceed without asking anything except the Low 3 detail.

### 5. Completeness words and proportionality

Two claims overreach:
- §6 "Error shapes" ("the mobile loop stops on both without marking rows waivable");
- the review-history line "addresses every finding".

Both are false until Mediums 1 and 2 are fixed; reword each with its method and blind spot. On proportionality, T3 is justified (authz function, Flyway, two repos), and this revision adds machinery (writer extraction, typed 422) only where a finding required it.

### Verdict justification

H1's core design (root ProblemDetail `type`, and mobile breaking on it while leaving plain 422s alone) is correct and verified against code. What's left are two un-enumerated producers of destination-caused untyped 422s, and one test that is too narrow to see what it claims. All are rare-path issues with single-file fixes and named tests.

**Realist check:** I rated Mediums 1 and 2 Medium rather than High. Mitigated by:
- Medium 1 needs a non-canonical-case scan of a case-colliding name; there are 2 such non-lane pairs on WineCo PRD.
- Medium 2 depends on tenant lane-type data and a sysprop, and P1 already probes both.

**Required before execution:** Mediums 1–3. Lows can be fixed in the TDD gate.

### Ralplan summary

- **Principle/option consistency:** Pass, once Mediums 1 and 2 close the remaining "refuse early, typed" gaps.
- **Alternatives:** Pass.
- **Risk/verification rigor:** Pass with Medium 3.
- **Deliberate additions:** N/A.

Files reviewed:
- /home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-3741-rts-choose-staging-lane-destination.md
- /home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-3741-evidence/disposition-r2.md
- /home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-3741-evidence/review-critic-r1.md