# SBDEV-3142 — test-adequacy review of §6 (vacuity lane)

**Reviewer lane:** r4-tests · **Base:** `v2/wms2-api` @ `origin/develop` `d434a3e5` · **Date:** 2026-08-31
**Method:** read-only `git show origin/develop:<path>` / `git grep … origin/develop`. **No `mvn` run** (another lane owns maven in the shared worktree), so every claim below is derived from source read at that commit, not measured this session. Where that distinction changes the confidence I say so inline.
**Plan file read:** `sbdocs/1-Projects/wms2/plan/SBDEV-3142-report-read-gating.md` as on disk at 2026-08-31 12:1x. ⚠️ The file is being edited concurrently — its §6 **instruments table already cites `Sbdev3017TrancheGateContextTest` + 32 rows**, while the **T1–T6 scenario table below it does not**. I review both and flag the desync as F7.

---

## VERDICT

**The proposed tests would NOT be vacuous — provided every MockMvc row goes through `BaseControllerUnitTest.setupMockMvcWithGuard(...)`, which already exists and is already used correctly by a sibling suite.** The estate's documented vacuity trap is real but it is *already solved in this repository*; the plan's §6 warning is accurate but overstates the danger relative to the tooling on disk.

Two exceptions, both real:

- **T6 is vacuous as written** — not "might be", *is*. `FunctionGuardStartupAssertion` iterates the deployed surface and `continue`s on `if (!guarded.contains(declaring))`. None of `ReportController` / `ClubLineController` / `TransfersController` is in `FunctionGuardInterceptor.GUARDED` (14 entries, all read at the source). An annotation-only change on non-`GUARDED` classes **cannot** make that assertion throw, in either direction. T6 is a row that cannot fail. (F1)
- **T4 names a method that does not exist**, so it will not compile / will silently probe the wrong thing if written from the plan text. `DashboardController` declares `orderMonitorViewOverview` mapped to path `/orderMonitorViewSummary`. The plan's own §1.2 warns about exactly this class of trap two pages earlier. (F2)

And one structural gap: **T1–T6 pin the *mechanism* 19 times and the *data* (which function on which handler) zero times**, unless T1 asserts the exact function argument. The mechanism is already proven by `FunctionGuardMockMvcUnitTest`; the data is the entire content of this ticket. The instruments table's `Sbdev3017TrancheGateContextTest` rows are the right answer and belong in the scenario table with a row count and an anti-shrink number. (F3)

Everything else in T1–T5 is writable and non-vacuous in the available lane. **T3 does not need `@SpringBootTest`** — the plan is right that it is cheap (mechanism below, with my confidence stated).

---

## 1. What a 403 assertion must do to be meaningful — concretely

`BaseControllerUnitTest` (at `src/test/java/net/aim_ai/wms/common/base/BaseControllerUnitTest.java`) has **three** setup methods, not two:

| method | interceptor installed? |
|---|---|
| `setupMockMvc(Object)` | **no** |
| `setupMockMvc(Object, Object... controllerAdvice)` | **no** |
| `setupMockMvcWithGuard(Object controller, HandlerInterceptor interceptor)` | **yes** — `.addInterceptors(interceptor)` |

Its own javadoc names the property: *"This is the one MockMvc mode in which authorization can actually be exercised in this repository."*

The minimal correct setup, copied in shape from the existing non-vacuous suite:

```java
class ReportGateUnitTest extends BaseControllerUnitTest {

    @Mock private AccessService accessService;
    @Mock private ViewDtoService dtoViewService;
    @Mock private ReportService reportService;
    @Mock private OrderMonitorViewService orderMonitorViewService;
    @Mock private PrinterRepository printerRepository;

    private FunctionGuardInterceptor guard;
    private ReportController controller;

    @BeforeEach
    void setUp() {
        guard = new FunctionGuardInterceptor(
                accessService, new ObjectMapper(), new SimpleMeterRegistry());
        // A real Authentication is REQUIRED: preHandle's currentUsername() reads
        // SecurityContextHolder, and a null Authentication yields username == null, which
        // reaches AccessService and changes which Reason comes back.
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken("sbtest", "n/a", Collections.emptyList()));
        controller = new ReportController(null, 100, dtoViewService, reportService,
                orderMonitorViewService, printerRepository);
        setupMockMvcWithGuard(controller, guard);   // ← the whole review turns on this line
    }
}
```

Four non-obvious requirements, each derived from reading `FunctionGuardInterceptor.preHandle`:

1. **The deny stub must carry a `requiredFunction`.** `deny(...)` only sets `Authority.AUTHZ_DENIED_HEADER` (`= "X-Authz-Denied"`, `Authority.java:150`) and only emits `requiredFunction` in the body `if (decision.requiredFunction() != null)`. A stub of `AccessDecision.deny(reason, null)` makes T2's header assertion fail for a reason that has nothing to do with the production code. The existing suite gets this right:
   `.thenAnswer(inv -> AccessDecision.deny(AccessDecision.Reason.NO_FUNCTIONS, requiredFunctions(inv)[0]))`.
2. **The body is written with the interceptor's *injected* mapper.** Passing `new ObjectMapper()` is correct and matches production intent; the interceptor keys the map explicitly (`type/title/status/reason/requiredFunction`) precisely because `WebConfigurer`'s `@Primary` bare mapper broke `ProblemDetail` extension fields. So asserting `$.reason` is a legitimate wire-contract assertion, not an implementation detail.
3. **A guard-installed MockMvc proves *reach*, not *registration*.** The production registration (`MappedInterceptor` bean, so SDR mappings pick it up) is pinned only by `FunctionGateEnforcementPointContextTest`, whose javadoc says **DO NOT RENAME THIS CLASS**. Nothing this ticket adds protects that; nothing needs to. State the blind spot, do not re-cover it.
4. **`Set` an authentication, and clear it.** `FunctionGuardMockMvcUnitTest` sets it in `@BeforeEach` and never clears; JUnit's per-class isolation makes that survivable but it is leakage. Prefer `SecurityContextHolder.clearContext()` in `@AfterEach`.

---

## 2. Are the EXISTING gate tests non-vacuous?

**Answer: yes for the two that claim to be gate tests; and there is one thing worth knowing about `reprintLabels`.**

### 2a. `reprintLabels` (`WEB_UI_VIEW_PARCEL_PICKING`, added by SBDEV-3017) — non-vacuous, but reflection-only

There is **no MockMvc gate test for `reprintLabels`.** `ReportControllerUnitTest` calls plain `setupMockMvc(reportController)` in its `@BeforeEach` and its four `reprintLabels` cases (`POST /v3/report/reprintLabels`) are therefore **gate-blind**: delete the `@RequiresFunction` and all four stay green. That is *correct* — they test the handler, not the gate — but it means the gate's only coverage is:

`Sbdev3017TrancheGateContextTest`, two rows:
```java
row("ReportController", "/v3/report/reprintLabels",    "WEB_UI_VIEW_PARCEL_PICKING");
row("ReportController", "/v3/dashboard/reprintLabels", "WEB_UI_VIEW_PARCEL_PICKING");
```
That pin **is non-vacuous**: it reflects over `getBeansOfType(RequestMappingHandlerMapping.class).getHandlerMethods()` in a real (H2-backed) context, keys on `declaringClass + " " + path`, resolves annotations *the interceptor's way* (`findMergedAnnotation(m, …)` then on `m.getDeclaringClass()`), reports three distinguishable failure shapes (`UNGATED`, `expected [X] but was [Y]`, `ROUTE NOT DEPLOYED`), and has a separate anti-shrink test `assertThat(EXPECTED).hasSize(85)` deliberately split into its own `@Test` so a drift failure cannot mask a row deletion. It cannot prove a 403 is emitted — the mechanism is proven elsewhere — and that is stated in its own javadoc.

**So: no vacuous existing gate test found.** Method: read `BaseControllerUnitTest`, every file matching `git grep -l 'addInterceptors\|FunctionGuardInterceptor' origin/develop -- 'src/test/**'` (24 files), plus `ReportControllerUnitTest`. **Blind spot:** I did not audit the ~5,700-test suite for *other* controllers' gate assertions, only the ones touching this ticket's surface and the shared base class.

### 2b. `FunctionGuardMockMvcUnitTest` (mobile, 11 controllers) — non-vacuous, and the template to copy

`src/test/java/net/aim_ai/wms/unit/controller/mobile/FunctionGuardMockMvcUnitTest.java` uses `setupMockMvcWithGuard(instantiate(e.getKey()), guard)` and asserts 403 in the deny direction. Its allow direction is the interesting trick: controllers are built reflectively with **all-null collaborators**, so on the allow path the handler is entered and dies, and MockMvc rethrows a nested servlet exception — *the throw is the proof the gate allowed*. Read that before writing T1/T4; see F5 for why T4 must **not** use it.

### 2c. ⚠️ The two existing anti-drift rails do **not** cover this ticket's catastrophic mutant

This is the most load-bearing thing in this review.

- `FunctionGuardArchTest.SHARED_CONTROLLERS = ["StockUnitController", "DashboardController", "ReplenishOrderController", "UnitLoadController"]`. **`ReportController` is not in it**, so adding 19 method-level annotations trips no allow-list and needs no `REVIEWED_SHARED_*` edit. Good news for the implementation.
- But `DashboardController` **is** in it, and the rule `noSharedControllerCarriesRequiresFunction` tests the class level with `functionsOn(c)` → `element.getAnnotation(annotationType)`. `RequiresFunction` is declared `@Documented @Target({TYPE, METHOD}) @Retention(RUNTIME)` — **it is NOT `@Inherited`**. `Class.getAnnotation` honours only `@Inherited`; the interceptor's `AnnotationUtils.findAnnotation(declaring, …)` walks superclasses **regardless**. Therefore: **a class-level `@RequiresFunction` on `ReportController` is invisible to `FunctionGuardArchTest` while being fully live for `DashboardController` at runtime.**
- `Sbdev3017TrancheGateContextTest.resolve()` returns the joined function names with **no `M:` / `C:` prefix** (unlike `SurfaceInventoryContextTest.requiresFunction`, which does prefix). So the pin also cannot distinguish method-level from class-level, and it has **no `DashboardController` GET rows at all**.

⇒ **The plan's claim that T4 is "the only test that fails" is correct, and now has a mechanism rather than an assertion.** Specifically for the belt-and-braces mutant (*keep* the 19 method annotations **and additionally** add a class-level one on `ReportController`): the pin stays green, the arch rail stays green, and only T4 reds. (F4 proposes a cheaper second detector.)

---

## 3. T1–T6 assessed

| # | vacuous as written? | verdict |
|---|---|---|
| T1 | **partly** — proves the mechanism, not the data, unless it asserts the exact function argument | fix per F3 |
| T2 | no | writable as-is; see §1 requirements 1–2 |
| T3 | no — **and it stays in the standalone lane** | see §3.1 |
| T4 | no, and it is the unique detector — but **not writable as literally stated** | see §3.2 / F2 / F5 |
| T5 | n/a today | §3.4 resolves to a single-function gate + deleting the dead web action, so T5 is dead weight unless Nam reverses that |
| T6 | **YES — cannot fail** | F1 |

### 3.1 T3 — can `standaloneSetup` register the inherited mapping under the subclass prefix?

**Yes. T3 belongs in the standalone lane and the plan is right that it is cheap.**

Mechanism: `StandaloneMockMvcBuilder` builds a `StaticRequestMappingHandlerMapping extends RequestMappingHandlerMapping` and registers each controller through the **same** `AbstractHandlerMethodMapping#detectHandlerMethods` used in production. That method takes `userType = ClassUtils.getUserClass(handler)` — `DashboardController` — and enumerates methods via `MethodIntrospector.selectMethods(userType, …)`, which walks the **superclass chain**; the per-method mapping is then combined with the **type-level** `@RequestMapping` of `userType`, i.e. `/v3/dashboard`. `ClassUtils.getMostSpecificMethod(m, DashboardController.class)` resolves a non-overridden inherited method to the `Method` object whose `getDeclaringClass()` is still `ReportController`. Net: `standaloneSetup(new DashboardController(...))` registers `/v3/dashboard/exportInventory` with `declaringClass == ReportController` — the exact pair the plan's TSV evidence reports from production. Only interceptor *bean detection*, argument resolvers, and advice differ between the two lanes; mapping construction is the identical code path.

**Confidence:** derived from the shared code path, **not measured this session** (no `mvn`). It is also corroborated indirectly: `Sbdev3017TrancheGateContextTest`'s `/v3/dashboard/reprintLabels` row proves the dual registration in a real context and its javadoc states the mechanism is inheritance. Cheap confirmation for the gate phase, five lines, before writing 13 rows:

```java
@Test void standaloneRegistersTheInheritedMappingUnderTheSubclassPrefix() throws Exception {
    setupMockMvcWithGuard(new DashboardController(null, 100, dtoViewService, reportService,
            orderMonitorViewService, printerRepository), guard);
    // 404 here would mean the dual mapping is NOT reproduced in this lane and T3 needs a context test.
    assertThat(mockMvc.perform(post("/v3/dashboard/exportInventory")
            .contentType(APPLICATION_JSON).content("{}"))
        .andReturn().getResponse().getStatus()).isNotEqualTo(404);
}
```

**What T3 actually buys over T2** (worth writing in the plan, because "403 twice" looks redundant): the annotation is method-level and resolution is on `declaringClass`, so T3's 403 is *structurally* the same decision as T2's. T3 reds on exactly one mutant T2 cannot see — **the dual mapping ceasing to exist** (someone drops `extends ReportController`, or moves a handler). That surfaces as **404 ≠ 403**, because a request matching no mapping never reaches an interceptor. That is a genuine, attributable signal. Keep T3; describe it as the *mapping* pin, not a second gate pin.

### 3.2 T4 — the mobile-safety pin

**It is writable, it is the unique detector, and it must be written differently from the plan text.**

Correct target (read from `DashboardController.java` at `origin/develop`):

| path | method | body |
|---|---|---|
| `/v3/dashboard/orderMonitorViewSummary` | `orderMonitorViewOverview` ⚠ **not** `orderMonitorViewSummary` | `dtoViewService.getOrderMonitorViewSummary()` |
| `/v3/dashboard/replenishMonitorViewSummary` | `replenishMonitorViewSummary` | `dtoViewService.getReplenishMonitorViewSummary()` |

Would it red if someone added a class-level `@RequiresFunction` to `ReportController`? **Yes — traced through `preHandle`:** `declaring = DashboardController` (the method *is* declared there); `getMethodAnnotation(PublicHandler)` → null; `getMethodAnnotation(RequiresFunction)` → null; `AnnotationUtils.findAnnotation(DashboardController.class, RequiresFunction.class)` → **walks to `ReportController` and finds it**; `accessService.checkAnyAccess` is consulted; a user holding nothing → 403. Expected 200 ⇒ red. It also reds on the other mistake direction (a class-level annotation on `DashboardController` itself), where `findAnnotation` finds it directly.

**Write it as a real 200, not as "not 403".** `DashboardController` has one 6-arg constructor and both handlers touch only `ViewDtoService`, so mock it and get a genuine 200:

```java
@Test
@DisplayName("T4 · the two mobile dashboard reads stay 200 for a user holding NOTHING")
void mobileDashboardReadsAreNotGated() throws Exception {
    when(accessService.checkAnyAccess(anyString(), any(String[].class)))
        .thenThrow(new AssertionError("AccessService must not be consulted for these two handlers — "
            + "reaching it means a class-level @RequiresFunction now covers DashboardController, "
            + "which 403s mobile Replenish (pages/replenish.vue) and Picking (store/picking.js)"));
    when(dtoViewService.getOrderMonitorViewSummary()).thenReturn(List.of());
    when(dtoViewService.getReplenishMonitorViewSummary()).thenReturn(List.of());
    setupMockMvcWithGuard(new DashboardController(null, 100, dtoViewService, reportService,
            orderMonitorViewService, printerRepository), guard);

    for (String p : List.of("/v3/dashboard/orderMonitorViewSummary",
                            "/v3/dashboard/replenishMonitorViewSummary")) {
        mockMvc.perform(get(p)).andExpect(status().isOk());
    }
}
```
The `thenThrow` is deliberate and is the attributability requirement: a bare `isOk()` failure reports "expected 200 but was 403", which does not name the cause; the throwing stub names it. Note this stub shape only works because the *correct* behaviour never calls `AccessService` at all — which is exactly the invariant T4 exists to pin.

**Do not use the `instantiate(...)`-with-nulls trick here.** In the null-collaborator lane the allow path throws, so you cannot assert a clean 200 — the very assertion T4 needs. `FunctionGuardMockMvcUnitTest` inverts that (a throw *is* the pass); T4 must not.

### 3.3 Missing scenarios

- **T7 — the data pin.** See F3.
- **T8 — the 5 `DashboardController` GET reads, not 2.** T4 covers the two with traced mobile callers. `DashboardController` declares five GETs (`/orderMonitorViewSummary`, `/orderMonitorViewBySectionName/{s}`, `/orderMonitorClientViewSummary`, `/orderMonitoClientrViewBySectionName/{c}/{s}` ⚠ *sic*, `/replenishMonitorViewSummary`). All five inherit a `ReportController` class-level annotation identically. Pinning all five costs three more loop entries and removes the "someone adds a mobile caller to a third one" hole. (`printToteLabels` is separately gated by SBDEV-3017 and is not in scope.)
- **T9 — a DB-presence assertion is not possible here, and the plan should say so.** Nothing in the H2 `@SpringBootTest` lane can check that the 12 `WEB_UI_VIEW_*` constants exist in `mywms_function` per tenant. The plan's §1.4 five-DB survey and the live probe are the only instruments. That is fine — but T6's slot should be spent saying it, since T6 as written says nothing.

---

## 4. Mutation-checking an annotation-only change

**PIT cannot see this change at all.** PIT operates on the bytecode of method bodies (conditionals, returns, increments, arithmetic, void-method calls). Annotations are class-file attributes, not instructions; PIT has no "remove annotation" operator and no mutable statement is being added by this ticket. A scoped PIT run would report either "no mutations generated" or a coverage figure entirely attributable to pre-existing code — and per this estate's prior measurement, a *scoped* PIT run also misattributes kills where duplicate test classes exist. **Recommendation: state in §6 that PIT is inapplicable to SBDEV-3142 and do not run it.** Leaving the floor's "mutation-check" clause unqualified is how a meaningless PIT number ends up quoted as evidence.

**The honest alternative is manual revert-and-run, one mutant per distinct mechanism — four, not nineteen.** Each must produce an *attributable* red (the message names the thing broken):

| # | mutant | must red | attributable message from |
|---|---|---|---|
| M1 | delete `@RequiresFunction` from **one** handler (use `ReportController.getDetailView`, the worst name/path mismatch) | T2 row for `/v3/report/parcelPickingView`; pin row `ReportController /v3/report/parcelPickingView` → `expected [WEB_UI_VIEW_PARCEL_PICKING] but was [UNGATED]`; and its `/v3/dashboard/...` twin row | pin's `wrong` map, keyed by declaringClass+path |
| M2 | change **one** annotation's constant to a different real `FunctionEnum` | pin → `expected [X] but was [Y]`. **T1/T2 must also red** — if they do not, T1/T2 are argument-blind and F3 is confirmed on your own tree | pin; and T1's captor per F3 |
| M3 | replace the 13 `ReportController` method annotations with **one class-level** annotation ("the cleanup") | T4 (403 ≠ 200) **and** ≥12 pin rows | T4's throwing stub names the mobile screens |
| M4 | **keep** the 19 and *add* a class-level annotation on `ReportController` (belt-and-braces) | **T4 only.** Pin green (no `M:`/`C:` prefix, no `DashboardController` rows), `FunctionGuardArchTest` green (`RequiresFunction` is not `@Inherited`) | T4 |
| M5 (optional) | delete `extends ReportController` | T3 → 404 ≠ 403 | T3's status assertion; add `.as("…the dual mapping is gone…")` |

M4 is the one to record in the plan, because it is the mutant three of four instruments miss.

---

## 5. Is a test the right instrument for AC-4 and AC-5?

### AC-4 (both prefixes covered) — **a test is the right instrument, and the plan's chosen one is not sufficient alone**

`SurfaceInventoryContextTest` has exactly **one** assertion, at its foot:

```java
assertThat(total).as("a context that registered nothing must not look like an empty surface").isGreaterThan(200);
```

Its own javadoc calls it *"an inventory generator, not a ratchet"* and records that a frozen allowlist was deliberately rejected. **So "verify AC-4 by re-running the inventory" is a human review of `target/surface-inventory.tsv`, not a test that can red.** It cannot regress-detect anything. It is also the *wrong axis*: it keys its class-level fallback on `hm.getBeanType()` with an `M:`/`C:` prefix, which the plan already documents (§3.3) as diverging from the interceptor precisely on this inheritance pair.

**A JUnit test can and should replace it as the AC-4 verifier**: 32 rows in `Sbdev3017TrancheGateContextTest` — that instrument already exists, already runs in the default lane, already keys on `declaringClass + path` (the interceptor's axis), already reports drift in both directions, and already carries an anti-shrink size test. Keep the inventory as a *cross-check artifact* for the human read, which is what the plan's updated instruments table now says. See F6 for the size-assertion bookkeeping.

### AC-5 (inventory re-derived) — **not replaceable by a test, and that is fine**

AC-5 asks for a re-derivation of the surface, i.e. an artifact a human reads to confirm nothing was missed. No assertion can express "nothing was missed" without becoming the frozen allowlist the estate deliberately rejected. Keep it as a generator run + a recorded `awk` reduction (the plan already gives the reduction, which is good practice). Do not promote it to an assertion.

### Is the `*ContextTest` lane reliable? — **yes, verified from the pom**

- `maven-surefire-plugin` 3.2.5 excludes **only** `**/*IntegrationTest.java` and `**/*E2ETest.java`. `*ContextTest.java` matches surefire's default include `**/*Test.java` ⇒ **it runs on every `mvn test`.**
- `maven-failsafe-plugin` 3.1.2 `<includes>` lists only `*IntegrationTest` and `*E2ETest`, which is why 28 `*IT.java` classes run in neither lane. Not relevant here as long as nothing is named `*IT`.
- The base class `BaseRollbackIntegrationTest` is `@SpringBootTest(classes = StartApplication.class)` `@ActiveProfiles("integration")` on **H2** for both landlord and tenant, with `spring.flyway.enabled=false`, `app.cron=false` and `app.cron.cleanup-rest-idempotency=-` (the one cron placeholder that otherwise blocks this context). No live DB needed.
- ⚠️ **Naming is load-bearing and fragile.** `FunctionGateEnforcementPointContextTest`'s javadoc says **DO NOT RENAME THIS CLASS** — renaming to `*IntegrationTest` moves it to `mvn verify` only, to `*IT` moves it to neither lane, and either silently removes authorization coverage. Any new class this ticket adds must end in `ContextTest` (context lane) or `UnitTest` (standalone lane) and nothing else.

---

## 6. Findings

**F1 — T6 is a row that cannot fail. (Medium)** `FunctionGuardStartupAssertion` scopes itself to `GUARDED`; none of the three controllers is a member, and §3.6 explicitly declines to add any. Replace T6 with the T9 statement (§3.3): no test lane can verify function-constant presence in `mywms_function`; the five-DB survey and the live probe are the instruments. Leaving T6 in place is the "green row that proves nothing" shape.

**F2 — T4 names a nonexistent method. (Medium, blocking for the gate phase)** `DashboardController.orderMonitorViewSummary` is a **path**; the method is `orderMonitorViewOverview`. Fix the plan text and key T4 on the path. Same class of trap the plan flags in §1.2 for `floowbinMonitorView` / `getDetailView`.

**F3 — T1/T2 as written pin the mechanism, not the per-endpoint function. (High)** The mechanism is already covered by `FunctionGuardMockMvcUnitTest`; AC-2's function↔handler assignment is the *content* of this ticket and no T row asserts it. Two fixes, use both:
   1. Give T1 a captor so it asserts the exact value:
      ```java
      ArgumentCaptor<String[]> fns = ArgumentCaptor.forClass(String[].class);
      verify(accessService).checkAnyAccess(eq("sbtest"), fns.capture());
      assertThat(fns.getValue()).containsExactly(WmsConstants.FunctionEnum.WEB_UI_VIEW_INVENTORY_RECORD);
      ```
      Without it, a stub of `checkAnyAccess(anyString(), any(String[].class))` makes T1 green for *any* function, including a wrong one.
   2. Promote the instruments table's `Sbdev3017TrancheGateContextTest` rows into the scenario table as **T7**, with the row count and the new size number (F6).

**F4 — add 5 reflection rows so M4 has a second detector. (Medium)** Add to `Sbdev3017TrancheGateContextTest`, expecting **no gate**:
```java
for (String p : new String[]{"/v3/dashboard/orderMonitorViewSummary",
        "/v3/dashboard/orderMonitorViewBySectionName/{sectionName}",
        "/v3/dashboard/orderMonitorClientViewSummary",
        "/v3/dashboard/orderMonitoClientrViewBySectionName/{clientName}/{sectionName}",
        "/v3/dashboard/replenishMonitorViewSummary"}) {
    row("DashboardController", p);      // deliberately UNGATED — mobile Replenish + Picking
}
```
These red on **both** class-level directions and cost nothing. ⚠️ One caveat to handle: the pin's `want.getValue().isEmpty()` branch emits an **"§0.C OMS carve-out"** message, which is the wrong explanation for these rows. Either widen that message or give these rows their own loop with a mobile-specific `as(...)`. Alternatively/additionally, add the `M:`/`C:` prefix to `resolve()` — but that re-baselines all 85 existing rows, so F4's five rows are the cheaper change.

**F5 — do not build T4 with the null-collaborator `instantiate(...)` trick. (Medium)** In that lane the allow path throws and a clean 200 is unassertable; T4's whole content is a clean 200. Construct `DashboardController` with mocks (§3.2).

**F6 — bookkeeping the plan does not mention. (Low, but it will red the suite)** Adding 32 rows takes `Sbdev3017TrancheGateContextTest`'s anti-shrink assertion from `hasSize(85)` to `hasSize(117)`, and its javadoc arithmetic (`85 = 71 + 1 + 2 + 8 + 3`) must be extended, or the next reader re-baselines without auditing — the exact behaviour that javadoc exists to prevent. Conversely, **good news the plan can rely on**: `ReportController`, `ClubLineController` and `TransfersController` are **not** in `FunctionGuardArchTest.SHARED_CONTROLLERS`, and `AC-3`/`AC-4b` are scoped to `GOLDEN_MAP` / `GUARDED`, so **no existing allow-list needs an entry** for the 19. I checked all four rails (`FunctionGuardArchTest`, `ActionGuardAnnotationContractUnitTest`, `FunctionGuardWiringUnitTest`, `PublicHandlerContractArchTest` by name only).

**F7 — §6's two tables disagree. (Low)** The instruments table cites `Sbdev3017TrancheGateContextTest` + 32 rows; the T1–T6 scenario table does not mention it. Reconcile before the gate phase, or the TDD lane will write T1–T6 and stop.

**F8 — a scope hole, reported not filed. (Medium — Nam's call, and it undercuts the gate being added)** `TransfersController.getSkuView` — `GET /v3/transfers/skus?orderBatchId=`, returning `List<ClubLineSkuDto>` via `transferOrderService.getSKUOverview(orderBatchId)` — is an ungated read on one of the three in-scope controllers and is **excluded from the 19 by the plan's own `$2=="POST"` awk filter**, while its direct twin `ClubLineController.getSkuView` (`POST /v3/clubLine/skus` → `customerorderBatchService.getClubLineSKUOverview`) **is** row 14. Post-fix, the club SKU view is gated on `WEB_UI_VIEW_CLUB_LINE` and the transfer SKU view of the same shape stays open. It is also **not** in §7.1's six proposed. Neither are the other same-controller ungated GET reads (`ClubLineController`: `getOpenClubRun`, `getClosedClubRun`, `getActiveClubRun` ×2 overloads, `getAvailableStagingLanes`; `TransfersController`: `getOpenTransfer`, `getAllOpenTransfer`, `getActiveTransfer`, `getClosedTransfer`, `getInactiveTransfer`). AC-2 says "a recorded per-endpoint decision"; today there is no recorded decision for these. Minimum fix: one paragraph in §3.6 or §7.1 saying the GET reads on `ClubLineController` / `TransfersController` are deliberately out of scope and why — the ReportController half took its 3 GETs by Nam's decision, so the asymmetry needs a sentence.

**F9 — arity/name collisions on the in-scope controllers. (Low, preventive)** `ClubLineController` declares **two** methods named `getActiveClubRun` (different arities), and `getSkuView` / `getParcelView` each exist on **both** `ClubLineController` and `TransfersController`. Any test keyed on a bare method name will resolve the wrong one — the measured failure that made an earlier reflection test in this repo vacuous. The `declaringClass + path` key used by `Sbdev3017TrancheGateContextTest` is immune; a hand-rolled `Class#getDeclaredMethods` lookup is not. If a new arch-style rail is written, key it `Controller#method/arity`.

---

## 7. What I could not settle

1. **Whether `standaloneSetup` reproduces the dual mapping — not measured.** I could not run `mvn` (lane constraint). The derivation in §3.1 is from the shared `detectHandlerMethods` code path and is corroborated by production evidence, and I give a five-line confirmation probe to run first in the gate phase. I rate it high confidence, not verified.
2. **Whether adding 32 rows keeps `Sbdev3017TrancheGateContextTest` green in every other respect** — e.g. whether all 32 paths appear in the deployed mapping with the exact pattern strings I would write (`{sectionName}` vs `{s}` templating). The pin reports `ROUTE NOT DEPLOYED` for a wrong pattern string, so this is self-diagnosing, but it will cost one iteration.
3. **Whether the full suite is green at `d434a3e5`.** I did not run it. Memory records develop as green post-SBDEV-3089 with a baseline of 148 raw / 142 distinct; confirm against that, and quote totals only from a `mvn clean test` (a bare `mvn test` runs stale deleted test classes).
4. **`PublicHandlerContractArchTest`** — I identified it by name as a rail over `@PublicHandler` sites and did not read it. Nothing in this ticket adds a marker, so I judged it out of scope; if the implementation ever reaches for `@PublicHandler` (it should not), read that file first.
