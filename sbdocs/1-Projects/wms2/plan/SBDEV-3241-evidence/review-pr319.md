# Review — PR #319 (SBDEV-3241 grant fixture)

- **Worktree**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3241-403`
- **Branch**: `bugfix/SBDEV-3241-403-grant-fixture`, HEAD `f07b2ab9`, base `origin/develop` @ `a158cf30`
- **Diff**: 2 files, both `src/test`
  - `src/test/java/net/aim_ai/wms/unit/controller/CustomerOrderControllerH2Test.java`
  - `src/test/java/net/aim_ai/wms/unit/controller/ReplenishOrderControllerH2Test.java`
- **Reviewed**: 2026-09-07
- **Verdict**: **MERGE, after F1 and F2 are fixed** (two lines each, both in the new test method). Everything
  else is Low. No `src/main` change, no production risk.

---

## 0. Verdict summary

The fix is correct and the diagnosis behind it is correct: `FunctionGuardInterceptor` really is installed in
this lane, really does evaluate `@RequiresFunction`, and `@WithMockUser(roles="ADMIN")` really does confer
zero WMS functions. Granting at `AccessService` rather than relaxing the gate is the right call, and the
author correctly recognised that a permissive gate mock needs an honesty check beside it.

The problem is that the honesty check as written is **materially weaker than the one it claims to copy**, and
I have a surviving mutant that proves it. The javadoc's "Same seam and same shape as
`CustomerOrderControllerIntegrationTest`" is half true — same seam, different shape — and the half that is
missing is precisely the half the reference test's own javadoc identifies as load-bearing.

| # | Severity | Finding |
|---|---|---|
| F1 | **Medium** | Honesty test is blind to *which* function is demanded — mutant SURVIVED. "Same shape as CustomerOrderControllerIntegrationTest" is false. |
| F2 | **Medium-Low** | Honesty test asserts nothing about status, so it stays green if the grant fixture itself stops working. |
| F3 | Low | `grantEveryFunction()` does not grant every function — only `checkAnyAccess`; `doesUserHaveAccess` is left at Mockito's `false`. |
| F4 | Low | The probe covers 1 of the 2 gated routes each class exercises. |
| F5 | Low | Fully-qualified inline names instead of imports; inconsistent with both files' existing import block and with the reference test. |
| F6 | Low | `throws Exception, BusinessException` on the new tests is redundant and unreachable. |
| F7 | Low | The claim "the other **five** tests in that class stay green" is a wrong count — there are two. Substance of the mutation claim is correct. |
| F8 | Low (pre-existing) | `cancelReplenishOrder` asserts only the response message, never that the order's state actually flipped. |

---

## 1. Is `theGateIsActuallyConsulted` sound, or does it pass for the wrong reason?

**It is sound for the failure it was written for (annotation deleted / interceptor not installed), and it is
blind to two adjacent failures.** Re-derived, not taken on trust.

### 1.1 Nothing other than this endpoint's gate can satisfy the `verify`

- `checkAnyAccess` has exactly **two** call sites in `src/main`:
  `FunctionGuardInterceptor:280` and `SdrFunctionGuard:296`
  (`grep -rn "checkAnyAccess" src/main/java`). `SdrFunctionGuard.evaluate` is reached only under
  `if (SdrFunctionGuard.isSpringDataRestHandler(declaring))` (`FunctionGuardInterceptor:209`); the declaring
  class here is our own `ReplenishOrderController` / `CustomerOrderController`, so that branch is not taken.
- `FunctionGuardInterceptor` is the **only** `HandlerInterceptor` in `src/main`
  (`grep -rln "implements HandlerInterceptor" src/main/java` → one file). No filter or second interceptor
  can produce a stray invocation.
- It is registered once, as `new MappedInterceptor(new String[]{"/**"}, functionGuardInterceptor)`
  (`WebConfig:86-87`), so one request produces one `preHandle`.
- `preHandle` runs **before** the handler by construction, so the 404 the probe provokes (id `1` is never
  seeded and both services throw `EntityNotFoundException`) cannot prevent the call.

### 1.2 Mock invocations do NOT bleed across test methods — measured, not assumed

The obvious way this test could pass for the wrong reason is a sibling test's invocation satisfying
`atLeastOnce()`. It cannot, and I have a direct measurement rather than a reading of Mockito's defaults:

Surefire execution order in `ReplenishOrderControllerH2Test` is
`cancelReplenishOrder` → `replenishorderDetailsById` → `theGateIsActuallyConsulted`
(`grep -o 'testcase name="[^"]*"' target/surefire-reports/TEST-…ReplenishOrderControllerH2Test.xml`).

In **Mutation 1** below I removed the annotation from `replenishorderDetailsById` only —
`cancelReplenishOrder` at `ReplenishOrderController:197` kept its `@RequiresFunction` and therefore *did*
invoke `checkAnyAccess`, first, in the same class. `theGateIsActuallyConsulted` still went **red**. So
`@MockitoBean`'s default `MockReset.AFTER` is genuinely clearing invocations between methods.

### 1.3 Mutation 1 — remove `@RequiresFunction` from `replenishorderDetailsById` → **KILLED**

`src/main/java/net/aim_ai/wms/controller/ReplenishOrderController.java:341`, annotation commented out.
Confirmed the edit applied, confirmed it **compiled** (`[INFO] Compiling 1 source file with javac`), then
restored and `diff`-verified byte-identical against a pre-mutation copy; `git status --short` clean.

```
[INFO]  Tests run: 3, Failures: 0, Errors: 0 -- CustomerOrderControllerH2Test
[ERROR] Tests run: 3, Failures: 1, Errors: 0 -- ReplenishOrderControllerH2Test
[ERROR]   ReplenishOrderControllerH2Test.theGateIsActuallyConsulted  <<< FAILURE!
[INFO] BUILD FAILURE
```

**The lead's mutation claim is correct in substance.** Exactly one test failed, and it was the honesty test.
Mechanism: `ReplenishOrderController` is **not** in `FunctionGuardInterceptor.GUARDED` (that set is the 16
mobile/user-admin controllers, `FunctionGuardInterceptor:122-171`) and carries **no class-level**
`@RequiresFunction`, so with the method-level annotation gone `preHandle` hits
`if (!GUARDED.contains(declaring)) return true;` — allowed, `AccessService` never consulted. The route becomes
ungated, so `replenishorderDetailsById()` still gets its 200 and stays green. That is the fail-open the
honesty test exists to catch, and it caught it.

**F7 (Low) — the count in the claim is wrong.** Each class has exactly **3** tests (2 pre-existing + the new
one), 6 across both — measured, `grep -c "@Test"`. So "the other **five** tests in that class stay green"
should read "the other **two**".

### 1.4 Mutation 2 — demand the WRONG function → **SURVIVED** (this is F1)

`ReplenishOrderController:341`, `WEB_UI_VIEW_REPLENISHMENT_ORDER` → `WEB_UI_VIEW_ORDER`. Compiled
(`[INFO] Compiling 1 source file`), restored and `diff`-verified.

```
[INFO] Tests run: 3, Failures: 0, Errors: 0 -- ReplenishOrderControllerH2Test
[INFO] BUILD SUCCESS
```

The replenishment screen's endpoint now demands the *orders* function, and the whole class is green. Nothing
in this PR can see it. This is not a hypothetical mutant: swapping or **widening** an ANY-of set to include a
function every user already holds is the realistic way this gating programme regresses, and
`CustomerOrderController.detailsByOrderId` already carries a four-element ANY-of set
(`CustomerOrderController:153-157`) that is exactly the shape that drifts.

**F1 (Medium).** The reference test does catch this, with the captor form:

```java
// CustomerOrderControllerIntegrationTest:218-221
ArgumentCaptor<String[]> demanded = ArgumentCaptor.forClass(String[].class);
verify(accessService).checkAnyAccess(eq("admin"), demanded.capture());
assertThat(demanded.getValue())…
```

vs. this PR's

```java
verify(accessService, atLeastOnce())
    .checkAnyAccess(anyString(), any(String[].class));
```

and the reference test's own javadoc says why that difference matters:

> The mock is deliberately **permissive but observed**: `GateContract.gateDemandsTheScreensFunctions()`
> asserts which functions each route actually demanded. **Without that, mocking the gate to "allow" would
> delete the very property these tests are valuable for.**

This PR imported the permissive mock and left behind the assertion that justifies it.

**Fix** (drop-in, both classes; the constants are already imported via `WmsConstants`):

```java
ArgumentCaptor<String[]> demanded = ArgumentCaptor.forClass(String[].class);
verify(accessService).checkAnyAccess(eq("admin"), demanded.capture());
assertThat(demanded.getValue())
    .containsExactly(WmsConstants.FunctionEnum.WEB_UI_VIEW_REPLENISHMENT_ORDER);
```

`eq("admin")` also tightens the username (see F2) and `verify(...)` without `atLeastOnce()` pins it at one
invocation, which is what one request through one `MappedInterceptor` should produce.

### 1.5 F2 (Medium-Low) — the probe asserts nothing about the response

```java
mockMvc.perform(get("/v3/replenishOrder/replenishorderDetailsById/1"));
```

No `.andExpect(...)`. That means the test is green in a world where the **grant fixture itself is broken and
the request 403s** — `checkAnyAccess` is still *invoked*, which is all the `verify` checks. The concrete way
that happens: `FunctionGuardInterceptor.currentUsername()` returns `null` when there is no `Authentication`
(`FunctionGuardInterceptor:371-374`), and `anyString()` **excludes null** — this repo documents that exact
Mockito trap in `NeverMatcherNullBlindnessArchTest`. A null username misses the `@BeforeEach` stub,
`checkAnyAccess` returns Mockito's default `null`, and `decision.allowed()` NPEs into a 500 — while
`theGateIsActuallyConsulted` still passes.

**Fix**: add `.andExpect(status().isNotFound())`. Id `1` is guaranteed absent (see §3c) and both services
throw `EntityNotFoundException`, which `RestExceptionHandler` has mapped to 404 since SBDEV-2994
(`CustomerorderService:198`, `ReplenishorderService:336-338`). A 404 assertion pins "the gate ran **and
allowed**"; the current form only pins "the gate ran".

---

## 2. What does the permissive mock hide?

**Today: nothing.** Full enumeration of all six tests in both classes — none is a negative-path or
authorization test, so no test that *should* see a 403 is silently passing.

### `CustomerOrderControllerH2Test` (3)

| Test | Route | Asserts | Could the mock mask it? |
|---|---|---|---|
| `detailsByOrderId` | `GET /v3/customerOrder/detailsByOrderId/{id}` | 200, `$.id`, `$.number == "CO-123"` | No. Seeds and reads back through the real controller → service → repo. |
| `batchUpdatePriorityByOrderIds` | `POST /v3/customerOrder/batchUpdatePriorityByOrderIds` | 200, `$.message == "UPDATED"`, **and** `customerorderRepository.findById(…).getPrio() == 100` for both orders (`:120-121`) | No. Real DB post-condition. |
| `theGateIsActuallyConsulted` (new) | `GET …/detailsByOrderId/1` | `verify(accessService, atLeastOnce())` | — (F1, F2) |

### `ReplenishOrderControllerH2Test` (3)

| Test | Route | Asserts | Could the mock mask it? |
|---|---|---|---|
| `replenishorderDetailsById` | `GET /v3/replenishOrder/replenishorderDetailsById/{id}` | 200, `$.number == "REPL-123"`, `$.clientNumber == "C001"` | No. |
| `cancelReplenishOrder` | `GET /v3/replenishOrder/cancelReplenishOrder/{id}` | 200, `$.message == "CANCELED REPLENISH ORDER"` | Not by the *authz* mock. But see F8. |
| `theGateIsActuallyConsulted` (new) | `GET …/replenishorderDetailsById/1` | `verify(accessService, atLeastOnce())` | — (F1, F2) |

**F8 (Low, pre-existing).** `cancelReplenishOrder` asserts only the message. The handler
(`ReplenishOrderController:197-221`) catches `FacadeException` into an `errors` map and returns **200** for
both outcomes, so the message assertion does distinguish success from the error branch — but nothing asserts
the order's state actually changed. Now that this test runs again, one line
(`assertThat(replenishorderRepository.findById(order.getId()).get().getState())…`) would make it a real
post-condition, matching what `batchUpdatePriorityByOrderIds` already does in the sibling class.

### What it hides going forward (accepted trade, but state it)

1. The `@BeforeEach` is class-wide, so **no future test in either class can observe a 403**. Anyone adding a
   denial test here must remember to re-stub in-method. Worth one sentence in the javadoc.
2. The four re-enabled tests no longer exercise the real user → group → role → function chain at all. That is
   the same trade `CustomerOrderControllerIntegrationTest` made deliberately, and the reference test paid for
   it with the captor assertion (F1).

### F3 (Low) — `grantEveryFunction()` does not grant every function

Only `checkAnyAccess` is stubbed. `AccessService.doesUserHaveAccess(...)` — the *other* grant API, used at
`StockunitService:292` (damaged-lock adjust), `MobileMoveUnitloadService:323,328`, `UserController:163`,
`UserAdministrationController:120` — is left at Mockito's default `false`. That **fails closed**, so it is
safe today (none of those paths is on the six tests' routes), but the method name and the javadoc's "grants
EVERY function for the whole class" are wrong, and the next person to add a damaged-lock or user-admin test
to either class will chase a spurious denial. Either rename (`allowTheFunctionGate`) or stub
`doesUserHaveAccess` too. `doesUserHaveAnyAccess` has **zero** callers in `src/main`, so it does not matter.

### F4 (Low) — one of two gated routes probed per class

Each class exercises two gated routes; the honesty probe covers one. `POST
/v3/customerOrder/batchUpdatePriorityByOrderIds` (`WEB_UI_VIEW_ORDER`, `CustomerOrderController:114`) and
`GET /v3/replenishOrder/cancelReplenishOrder/{id}` (`WEB_UI_VIEW_REPLENISHMENT_ORDER`,
`ReplenishOrderController:197`) are unprobed — deleting *their* annotation is not caught by anything in this
PR. Applying F1's captor form per route closes this for free.

---

## 3. Spring context implications

**(a) Cost: zero additional contexts.** Measured, not reasoned:

- 31 classes extend `BaseRepositoryIntegrationTest`; exactly **two** carry `@AutoConfigureMockMvc` — these
  two. `@AutoConfigureMockMvc` already forks the context cache key, so neither ever shared a context with the
  other 29.
- They never shared with *each other* either: before this PR `CustomerOrderControllerH2Test` declared
  `@MockitoBean KeycloakService` and `ReplenishOrderControllerH2Test` declared `KeycloakService` **and**
  `StockunitBusinessService`, on top of the base's `TenantHealthService` + `EndpointHealthCheck`. Different
  override sets → different keys already.
- Adding `AccessService` to both therefore changes *nothing* about how many contexts exist. Confirmed in the
  run log: two `Started …H2Test in …` lines, one per class.

The real cost is **un-disabling itself**, which is the point of the PR: ~34 s (cold context) +
~5 s in my two-class run. That is inherent to running two full `@SpringBootTest` contexts that were
previously skipped, not attributable to `@MockitoBean`.

**(b) Behaviour change inside these two contexts.** `AccessService` is injected into `WebConfig` →
`FunctionGuardInterceptor`, plus `SdrFunctionGuard`, `RestConfiguration`, `UserController`,
`UserAdministrationController`, `UtilRestController`, `StockunitService`, `PutawayConfigService`,
`MobileMoveUnitloadService`. All of them now hold the mock in these two contexts. None is on an exercised
route. Both contexts start clean — `FunctionGuardStartupAssertion: 792 deployed handlers checked, 16 guarded
controllers, 5 annotation-marked handlers open by design` passed in both.

**(c) SBDEV-3242 interaction: none broken, but there is a real coupling worth recording.** The base is
`@Transactional("tenantTransactionManager")` since SBDEV-3242, so seeded rows now genuinely roll back instead
of committing. That is *why* the honesty probe's hard-coded id `1` is guaranteed absent and 404s. Pre-3242,
when every `save()` committed, a leftover row with id 1 could have existed and the probe would have returned
200 — still passing, but for a different reason. Both classes pass under the 3242 fix; F2's status assertion
would make this coupling explicit rather than incidental.

---

## 4. Are the four re-enabled tests actually asserting something?

**Yes — three strongly, one adequately.** See the table in §2. Specifically checked for the two failure
shapes named in the brief:

- **Assertions satisfied by a mock default**: none. Every assertion in the four tests is on real JSON produced
  by the real controller/service/repo path. The only mock defaults in play are the four `@MockitoBean`s
  (`TenantHealthService`, `EndpointHealthCheck`, `KeycloakService`, `StockunitBusinessService`) plus the new
  `AccessService`, and no assertion reads through any of them.
- **Data the test seeded and read back through the same id**: yes, and that is legitimate here — it is a
  controller round-trip test, and the values asserted (`"CO-123"`, `"REPL-123"`, `"C001"`, `prio == 100`) are
  literals the test chose, so a broken read path would surface. `batchUpdatePriorityByOrderIds` goes further
  and re-reads from the repository after the request.

---

## 5. Is `AccessDecision.allow()` the right grant?

**Yes, and it fully satisfies the gate — no accident, no unstubbed second consultation.** Traced `preHandle`
end to end for these two routes:

1. `handler instanceof HandlerMethod` → true.
2. `SdrFunctionGuard.isSpringDataRestHandler(declaring)` → **false** (declaring class is our own controller),
   so `SdrFunctionGuard` — the only other `checkAnyAccess` caller — is never reached.
3. `getMethodAnnotation(PublicHandler.class)` → **null** on both handlers.
4. `getMethodAnnotation(RequiresFunction.class)` → **present** (method-level) on both, so the class-level
   fallback and the `GUARDED` fail-closed branch are both bypassed.
5. `accessService.checkAnyAccess(username, annotation.value())` → the stub.
6. `if (decision.allowed())` → `allowed()` is literally `reason == Reason.ALLOWED` (`AccessDecision:92-94`)
   and `allow()` is `new AccessDecision(Reason.ALLOWED, null)` (`AccessDecision:97-99`). Nothing else is
   consulted; the method returns `true` after one meter increment.

The `null` `requiredFunction` on an allow decision is never dereferenced on the allow path. So `allow()` is
exactly right, and the tests are not passing by some other route.

---

## 6. Javadoc accuracy

| Claim | Verdict |
|---|---|
| "`FunctionGuardInterceptor` installed and genuinely evaluating `@RequiresFunction`, which is why they returned 403" | **Accurate.** Confirmed by mutation 1. |
| "`@WithMockUser(roles = "ADMIN")` grants a Spring role, not a WMS function" | **Accurate.** |
| "the single seam the interceptor consults" | **Accurate** for these MVC routes (`FunctionGuardInterceptor:280`). |
| "**Same seam and same shape** as `CustomerOrderControllerIntegrationTest`" | **Half wrong — F1.** Same seam, and the same `@BeforeEach`/`@MockitoBean` boilerplate; but the *shape* of the honesty check is `verify(atLeastOnce()).checkAnyAccess(anyString(), any())` here vs. an `ArgumentCaptor` + `eq("admin")` + an exact function-set assertion there. The reference test's javadoc names that captor as the reason the permissive mock is acceptable. Either fix the test to match, or delete the words "and same shape". |
| "The mock is **permissive**, so on its own it would also pass if the gate were DELETED. `theGateIsActuallyConsulted` keeps it honest." | **Overstated.** It keeps it honest against *deletion* and against the interceptor not being installed. It does **not** keep it honest against a wrong or widened function (mutation 2, SURVIVED) or against the grant fixture itself failing (F2). Qualify it. |
| `@BeforeEach void grantEveryFunction()` | **Overstated — F3.** Grants every function *routed through `checkAnyAccess`*; `doesUserHaveAccess` stays denying. |
| Inline comment: "would make every test above pass just as happily if someone deleted the `@RequiresFunction`" | **Accurate**, and now measured. |

---

## 7. Style / hygiene (all Low)

- **F5** — fully-qualified names inline where both files already have an ordinary import block, and where the
  reference test imports the same symbols:
  `@org.springframework.test.context.bean.override.mockito.MockitoBean`,
  `org.junit.jupiter.api.BeforeEach`, `org.mockito.Mockito.when/verify/atLeastOnce`,
  `org.mockito.ArgumentMatchers.anyString/any`, `net.aim_ai.wms.security.AccessDecision.allow()`,
  `net.aim_ai.wms.exceptions.BusinessException`. Not wrong; it just makes the new method the least readable
  one in each file. Adding six imports removes ~200 characters of noise.
- **F6** — `throws Exception, net.aim_ai.wms.exceptions.BusinessException` on both new tests. Redundant
  (`BusinessException` is an `Exception`) and neither new body can throw it — copy-pasted from the
  neighbours. `throws Exception` suffices.
- The `@MockitoBean accessService` field and its `@BeforeEach` are inserted **between** two `@Autowired`
  repository fields in `CustomerOrderControllerH2Test` (`:52-66`, splitting `mockMvc` from
  `customerorderRepository`). Cosmetic; grouping the mock+setup below the `@Autowired` block would read better.

---

## 8. What I ran

All in the PR worktree, one Maven invocation at a time,
`JAVA_HOME=…/21.0.11-ms`, `…/maven/current/bin/mvn -o`.

| Run | Result |
|---|---|
| `test -Dtest='CustomerOrderControllerH2Test,ReplenishOrderControllerH2Test'` (unmutated) | **3/0/0** and **3/0/0**, BUILD SUCCESS. Confirms the four re-enabled tests + two new ones pass. |
| Mutation 1 — drop `@RequiresFunction` on `ReplenishOrderController:341` | **KILLED.** 1 failure, `theGateIsActuallyConsulted` only; the other two in the class green. Compiled first (`Compiling 1 source file`). |
| Mutation 2 — swap the demanded function to `WEB_UI_VIEW_ORDER` | **SURVIVED.** 3/0/0, BUILD SUCCESS. Compiled first. → F1 |
| `clean test` (full surefire lane) | see §9 |

Both mutations were restored with an inverse `sed` and verified byte-identical against a pre-mutation copy
(`diff` → no output); `git status --short` clean, `git diff --stat` empty. No git state was changed.

---

## 9. Full suite

`mvn -o clean test` on the PR HEAD, full lane, run by me in this worktree:

```
[WARNING] Tests run: 6330, Failures: 0, Errors: 0, Skipped: 6
[INFO] BUILD SUCCESS
```

**The lead's suite claim reproduces exactly: 6330 / 0 / 0, skipped 6.** Both re-enabled classes ran inside
that lane and were green:

```
[INFO] Tests run: 3, Failures: 0, Errors: 0, Skipped: 0 -- net.aim_ai.wms.unit.controller.CustomerOrderControllerH2Test
[INFO] Tests run: 3, Failures: 0, Errors: 0, Skipped: 0 -- net.aim_ai.wms.unit.controller.ReplenishOrderControllerH2Test
```

The `10 → 6` skip claim is arithmetically consistent with the diff (two class-level `@Disabled` markers
removed, 2 tests behind each, `10 − 4 = 6`) and the post-state (6) is measured; I did not re-run the
pre-change baseline to observe the 10 directly.

**Not independently verified: the failsafe claim (352 / 0 / 70 unchanged).** I did not run `mvn verify`. The
risk of it having moved is low on inspection — the diff adds no `*IT` class, touches no `src/main`, and
neither edited class matches failsafe's `<includes>` — but that is an argument, not a measurement, and it is
recorded here as such.

---

## 10. Recommendation

**Merge after F1 + F2.** Both are edits to the new test method only — no `src/main` change, no change to the
four re-enabled tests, and F1's fix is the exact code already living in
`CustomerOrderControllerIntegrationTest:218-221`. Doing them now is cheaper than the alternative, which is
that this PR establishes "permissive gate mock + `verify(anyString(), any())`" as the copy-paste template for
the next controller test class that hits a 403 — and that template cannot see a wrong function.

F3 and F6 are one-line edits worth taking in the same pass (repo convention is to fix Lows in the pass that
finds them). F4, F5, F7 and F8 are optional; F7 is a claim correction for the ticket, not a code change.
