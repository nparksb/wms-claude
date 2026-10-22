# SBDEV-3154 — implementation review (independent lane)

- **Reviewed**: worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3154`, branch
  `bugfix/SBDEV-3154-admin-action-console-gating`, base `origin/develop` `2e757457`.
- **Mode**: read-only. No maven, no worktree creation, no file edits. `git diff` / `git show` / `sed` /
  `git grep` across `wms2-api`, `wms2-web-ui`, `wms2-mobile-ui`, `oms-laravel-api`, plus read-only SQL on
  `dev_wh01_om1`.
- **Diff surface**: 3 files — `AdminActionController.java` (+6), `Sbdev3017TrancheGateContextTest.java`
  (+49/-1), new untracked `AdminActionConsoleGateUnitTest.java`. No Flyway file, no `WmsConstants` change.
- **Verdict**: the change is correct and the function choice is right. No Critical or High. Two Mediums
  (one test-soundness, one scope/justification), eight Lows.

---

## Findings

### F1 · Medium — T3 cannot catch the widening its own comment says it catches

`src/test/java/net/aim_ai/wms/unit/controller/AdminActionConsoleGateUnitTest.java`, in
`denyEverythingAndRecord()`:

```java
if (all[1] instanceof String[] arr) {
    for (String f : arr) { requested.add(f); }
    first = arr.length == 0 ? null : arr[0];
} else {
    first = String.valueOf(all[1]);
    requested.add(first);          // <-- all[2..n] are dropped
}
```

`InvocationOnMock.getArguments()` is documented as *"Returns arguments passed to the method. Vararg are
expanded in this array."* — `InterceptedInvocation` stores `expandArgs(method, rawArguments)`. So for
`AccessService.checkAnyAccess(String username, String... functions)`
(`src/main/java/net/aim_ai/wms/service/AccessService.java:134`) the **else-branch is the live path** and the
`instanceof String[]` branch is dead. Only the first function is ever recorded.

Failure scenario: someone widens the gate to
`@RequiresFunction({WmsConstants.FunctionEnum.WEB_UI_VIEW_IMPORT_DATA, WmsConstants.FunctionEnum.WEB_UI_VIEW_MESSAGES})`.
`any(String[].class)` is `InstanceOf.VarArgAware`, so the stub still matches; `requested` becomes
`["WEB_UI_VIEW_IMPORT_DATA"]`; and

```java
assertThat(requested)
        .as("the gate on this route requires a single function; a widened set is a policy "
            + "change and must be made deliberately")
        .containsExactly(REQUIRED);
```

passes. The assertion is exactly the one the comment above it says makes widening "a deliberate decision
rather than a silent one", and it does not.

Mitigating, and why this is Medium not High: the widening **is** caught, one file over.
`Sbdev3017TrancheGateContextTest.resolve()` joins the whole `value()` array
(`String.join("+", new TreeSet<>(Set.of(r.value())))`), so the same mutant reports
`expected [WEB_UI_VIEW_IMPORT_DATA] but was [WEB_UI_VIEW_IMPORT_DATA+WEB_UI_VIEW_MESSAGES]` and reddens.
Coverage is not lost; the new class's assertion and its justification are.

The repo already has the correct idiom, in a sibling this file's own javadoc cites —
`src/test/java/net/aim_ai/wms/unit/controller/UnitLoadControllerActionGuardUnitTest.java:113-119`:

```java
if (all.length > 1 && all[1] instanceof String[] arr) { return arr; }
return java.util.Arrays.stream(all).skip(1).filter(java.util.Objects::nonNull)
        .map(String::valueOf).toArray(String[]::new);
```

**Fix**: in the else-branch, loop `for (int i = 1; i < all.length; i++) requested.add(String.valueOf(all[i]));`
and keep `first = String.valueOf(all[1])`. Keep the array branch as the defensive path. Then T3 does what it
claims. (`ReportReadGateUnitTest.assertFunction` — `src/test/java/net/aim_ai/wms/unit/controller/ReportReadGateUnitTest.java:472-493`
— solves the same problem reflectively with `assertThat(annotation.value()).containsExactly(expected)`; that
is the other acceptable shape.)

### F2 · Medium — two mutating siblings stay open, and the plan's stated reason is a scoping note, not a risk assessment

Left ungated on the same controller, both writes, both reachable by any `wms_user`:

- `finishStuckPickingOrder/{number}` (`AdminActionController.java:184`) →
  `pickingorderBusinessService.finishPickingOrder(pickingOrder);` (:228) on an **arbitrary order number**
  from the path. Guarded only by `state == PICKED` and `stuckToteCount > 0`.
- `triggerReleaseExpiredPickingOrdersFromUser` (`:130`) →
  `releaseExpiredPickingOrdersFromUserJob.doCalculation(false);` — releases picking orders off users
  warehouse-wide.

`SecurityConfiguration.java:157-160` gates `/v3/adminAction/**` on `WMS_USER_ROLE` **only** (the block is
labelled "C. Admin-Only WMS Endpoints", which it is not):

```java
.requestMatchers(
    "/v3/adminAction/**", "/v3/sysprop/**", "/v3/systemProperty/**",
    "/v3/printer/**", "/userDetailsById/**", "/userGroup/**", "/user/**"
).hasAnyAuthority(Authority.WMS_USER_ROLE)
```

Measured on `dev_wh01_om1`: 100 rows in `mywms_user`, 37 holders of `WEB_UI_VIEW_IMPORT_DATA`. So after this
change five routes narrow 100 → 37 and these two stay at 100.

Plan §6 says only: *"`finishStuckPickingOrder` and `triggerReleaseExpiredPickingOrdersFromUser` stay ungated
(not in SBDEV-3017's §1 slice)."* That is a provenance statement. The **defensible** reason is not stated
anywhere: `git grep` on `origin/develop` of **both** wms2 UIs returns **zero** callers for either route
(unlike `triggerUpdateStock`, which does have a live button — `components/admin/systemManagement/actions.vue:16`
→ `actionConfirmation.vue:68` → `store/admin/mgmt/action.js:27`). With no screen, Option B ("take the function
that gates the screen you are dispatched from") has nothing to inherit.

Recommendation: either state that reason in plan §6, or fold both in — one annotation each, sub-T3, so per
the ticket policy they belong on **this** ticket rather than a new one. Note the trade-off honestly if you
fold them in: a route with no UI caller and no screen is being assigned a screen's function by fiat, which is
a small stretch of §9.16 rather than an application of it.

### F3 · Low — `Sbdev3017TrancheGateContextTest`'s size javadoc now contradicts its own assertion

The diff bumped the number and left the paragraph that explains it. Line 440 still reads:

> `<p>123 = the original 85 (71 tranche rows + …) + <b>38 from SBDEV-3142</b>: …`

while line 455 asserts `assertThat(EXPECTED).hasSize(131);`.

**131 is the correct number** — I counted it independently rather than trusting the arithmetic: 107 literal
`row(` calls plus four `for (String p : new String[]{…})` loops contributing 8 (`LabelPrintingController`),
9 (`FixLocationAssignmentController`), 4 (`FileImportController`) and 3 (`SystemPropertyController`) = 131,
with **zero duplicate `(class, path)` keys** (a duplicate would silently collapse under
`LinkedHashMap.put` and drop the count). The 8 new rows are 5 gated + 3 ungated siblings.

This javadoc is the only record of what the number means, and it is the thing a future editor reads before
changing it. Append: `+ 8 from SBDEV-3154 (5 gated console routes + 3 sibling rows asserted UNGATED)`.

### F4 · Low — plan says 128, code says 131

`sbdocs/1-Projects/wms2/plan/SBDEV-3154-admin-action-console-gating.md` in three places:

- §4.1 — *"bump `assertThat(EXPECTED).hasSize(123)` → `128` (five new rows)"*
- §4.3 mutant table — *"drop one `row(...)` from `EXPECTED` | `hasSize(128)` fails"*
- **AC-4** — *"Presence pin extended to 128 rows"*

The implementation is at 131 because the class-level mutant survived at 128 and the three sibling rows were
added to kill it — that is the mutation loop working, and it is a strict improvement over the plan. But AC-4
as written is now false against the code, and §4.3's mutant table does not mention the three rows that turned
out to be load-bearing. Update the plan (§4.1, §4.3, AC-4) as part of the end-of-implementation status flip.

### F5 · Low — two different line numbers for `accessAudit` inside the one new comment block

`Sbdev3017TrancheGateContextTest.java:296` — *"one of them accessAudit:342 which is already
`@PreAuthorize(IS_SB_ADMIN)`"* — versus `:317` — *"⚠ accessAudit:348 is NOT listed."*

Post-change truth in `AdminActionController.java`: `@PreAuthorize(Authority.IS_SB_ADMIN)` :347,
`@GetMapping(path = "/accessAudit", …)` :348, `public ResponseEntity<Object> accessAudit()` :349. `:342` is the
pre-change number (the diff inserts 6 lines above it: 1 import + 5 annotations), carried over from plan §3,
which cites `accessAudit (:342)` and the `@PreAuthorize` at `:341`. Pick one convention — post-change, since
that is what a reader will open.

### F6 · Low — `StockCountRestController:105-113` is the wrong range (the claim it supports is true)

Cited identically in the new pin comment (`:315-316`) and plan §6. Actual:
`src/main/java/net/aim_ai/wms/controller/rest/StockCountRestController.java:103` `@GetMapping(value = "triggerStockCount", …)`,
method body :104-108, `triggerSchedule()` :110-112.

The substance checks out on both instruments, which is why this is only a citation fix:

```java
@RequestMapping("/rest/stockcount")            // :26
@GetMapping(value = "triggerStockCount", …)    // :103
public Runnable triggerSchedule() {            // :110
    return () -> stockSummaryExportJob.doCalculation(false);
}
```

and `SecurityConfiguration.java:150-154` `permitAll()`s `"/rest/**"`. So gating only the `/v3/adminAction`
copy of `triggerUpdateStock` genuinely would be cosmetic.

### F7 · Low — the new javadoc's "servlet 500" is not what happens

`AdminActionConsoleGateUnitTest` javadoc, twice:

> *"…so in a unit test it is `null` and the handler NPEs into a servlet 500. A 500 there would look like a
> passing 'not 403'."*

`setupMockMvcWithGuard` (`BaseControllerUnitTest.java:95-103`) registers no `@ControllerAdvice`, and
`DefaultHandlerExceptionResolver` does not handle `NullPointerException`, so the NPE propagates out of
`mockMvc.perform` as a wrapped `ServletException` — the test **errors**, it does not produce a 500 response.
The conclusion (`isEqualTo(403)` rather than `isNotEqualTo(200)`) is right and the deny-path-only decision is
right; only the mechanism named is wrong. Same wording should be checked in the class javadoc's "Deny-path
only, deliberately" paragraph.

### F8 · Low — T0's second assertion is a tautology

```java
assertThat(GATED_GETS).as("the gated GET routes on the operator console").hasSize(4);
assertThat(GATED_GETS.size() + 1)
        .as("the scope this ticket claims: 5 routes (4 GETs + recoverStuckPallets)")
        .isEqualTo(5);
```

The second is entailed by the first — `4 + 1 == 5` cannot fail independently, and `GATED_POST` is a single
`String` constant with nothing to count. It reads as an anti-shrink pin but pins nothing beyond `hasSize(4)`.
Either drop it or make it pin something real, e.g. `assertThat(GATED_GETS).containsExactlyInAnyOrder(…)` with
the four literal paths.

### F9 · Low — the new test file is untracked

`git status --short` reports `?? src/test/java/net/aim_ai/wms/unit/controller/AdminActionConsoleGateUnitTest.java`.
It must be `git add`-ed. Nothing in the loop catches its omission: `mvn test` compiles and runs it from the
working tree whether or not it is staged, so a green suite is not evidence it is in the commit.

### F10 · Low — import inserted out of order

`AdminActionController.java:21`, `import net.aim_ai.wms.security.RequiresFunction;`, sits between
`net.aim_ai.wms.service.UnitloadBusinessService` (:20) and `net.aim_ai.wms.service.WmsConstants` (:22). The
file's import block is already unsorted (`org.springframework.security.access.prepost.PreAuthorize` at :15
precedes `net.aim_ai.wms.Authority` at :16), so no rail breaks. Nit.

### F11 · Low, out of scope — a cross-repo doc asserts the wrong authority for this surface

`v2/oms-laravel-api`, `origin/develop:docs/functional-specs/01-authentication-authorization.md:343`:

> `| /v3/adminAction/**`, `/v3/sysprop/**` | `wms_admin` or `ADMIN` |`

`SecurityConfiguration.java:157-160` requires `WMS_USER_ROLE`. Pre-existing, in another repo, and per the
v2-only rule not this ticket's to fix — recorded because it is the document that would convince a reader
these routes were already admin-only, i.e. that this ticket is unnecessary.

---

## What I verified as correct

### Q1 · The five annotation sites

Exactly five `@RequiresFunction` on the class, all method-level, all
`WmsConstants.FunctionEnum.WEB_UI_VIEW_IMPORT_DATA`:

| annotation | handler | route |
|---|---|---|
| :106 | :108 `triggerOrderReplenish` | `GET /v3/adminAction/triggerOrderReplenish` |
| :122 | :124 `triggerArchiveMessages` | `GET …/triggerArchiveMessages` |
| :137 | :139 `testCrmConnectivity` | `GET …/testCrmConnectivity` |
| :247 | :249 `listRecoverableStuckPallets` | `GET …/listRecoverableStuckPallets` |
| :261 | :263 `recoverStuckPallets` | `POST …/recoverStuckPallets` |

`grep -c RequiresFunction` on the file = 5, and `grep -rn WEB_UI_VIEW_IMPORT_DATA src/main` shows those five
plus `FileImportController:39` (pre-existing class-level) and the `WmsConstants:353` declaration.

No sibling was accidentally annotated: `triggerUpdateStock` (:116),
`triggerReleaseExpiredPickingOrdersFromUser` (:131), `finishStuckPickingOrder` (:185) and `accessAudit` (:349)
carry none. `accessAudit`'s `@PreAuthorize(Authority.IS_SB_ADMIN)` at :347 is untouched — and
`MethodSecurityEnablementContractTest.java:147-149` (*"§8.16.5 · AdminActionController.accessAudit stays on
sb_admin — it is the rollout instrument"*) still asserts it.

No class-level `@RequiresFunction` on `AdminActionController` (:38-41 are `@Tag`, `@RestController`,
`@RequestMapping`) and none on `AdminController` (:29-30). `FunctionGuardInterceptor.GUARDED` is unchanged at
14 entries. Nine mapped handlers are declared on `AdminActionController`, 5 gated + 4 not, so the new
comment's "four other handlers" is correct under the five-route scope — plan §8.5's *"'Four other handlers' →
five"* correction was against the earlier four-route scope and does not contradict it.

### Q2 · `WEB_UI_VIEW_IMPORT_DATA` is right for all five, including `listRecoverableStuckPallets`

Derived from `origin/develop` of both UIs, not from local checkouts.

Every caller of all five lives under `components/admin/systemManagement/`:

- `actionConfirmation.vue:65 / :71 / :76` → `admin/mgmt/action/{triggerOrderReplenishment, triggerArchiveMessages, testCrmConnectivity}`
- `recoverStuckPallets.vue:135` → `listRecoverableStuckPallets`; `:148` → `recoverStuckPallets`
- `store/admin/mgmt/action.js:17 / :37 / :47 / :63 / :74` — the five axios calls, and the **only** ones

`git grep -l "systemManagement/\|SystemManagement" origin/develop` returns exactly three files:
`exampleFiles.vue`, `systemManagementMain.vue`, `pages/admin.vue`. So the components mount only under the
System Management tab, and that tab is gated on the function in question:

- `pages/admin.vue` — `{ text: 'System Management', fn: 'WEB_UI_VIEW_IMPORT_DATA', component: 'SystemManagement', canonical: 0 }`,
  filtered by `visibleTabs()` → `ADMIN_TABS.filter((t) => held.includes(t.fn))`
- `util/appMenuList.js` — row 30's Admin ANY-of leads with `'WEB_UI_VIEW_IMPORT_DATA', // System Management`

**No second screen.** `git grep origin/develop` in `wms2-mobile-ui` for `adminAction`,
`triggerOrderReplenish`, `triggerArchiveMessages`, `testCrmConnectivity`, `listRecoverableStuckPallets`,
`recoverStuckPallets`: all empty. In `oms-laravel-api`: only the doc line in F11. So nothing else 403s.

`listRecoverableStuckPallets` specifically — one caller, `recoverStuckPallets.vue:135`, the modal opened by
`actions.vue:40` on that same tab, whose confirm is the already-in-scope `recoverStuckPallets`. Gating it is
coherent, and leaving it open would have been the split state the pin comment describes.

DB check on `dev_wh01_om1` (walking `mywms_group_mywms_user` → `mywms_group_mywms_role` →
`mywms_role_mywms_function` → `mywms_function`, counting **users** per AC-2′, not roles):

| function | users |
|---|---|
| `WEB_UI_VIEW_IMPORT_DATA` | 37 |
| `WEB_UI_VIEW_SYSTEM_PROPERTY` | 37 |
| `WEB_UI_VIEW_CLIENT` | 37 |
| `WEB_UI_VIEW_MESSAGES` | 38 |
| `WEB_UI_VIEW_RECEIVING` | 41 |
| (`mywms_user` total) | 100 |

37 matches the first figure in the plan's frontmatter (`37/35/7/15/23/9`). I did not re-measure the other
five tenants; the fact-check lane's numbers are unchallenged on the one I can reach.

### Q3 · The new test is sound apart from F1

- **Not vacuous.** With the annotations deleted, `preHandle` hits `annotation == null && !GUARDED.contains(declaring)`
  → `return true` → the handler runs. `triggerOrderReplenish` / `triggerArchiveMessages` return 200 (mocked
  jobs); `testCrmConnectivity` returns 200 with an `errors` entry; `listRecoverableStuckPallets` and
  `recoverStuckPallets` NPE on the null field-injected `unitloadBusinessService` and throw out of `perform`.
  Every one fails an `isEqualTo(403)`.
- **`anyString()` matches** because `FunctionGuardInterceptor.currentUsername()` returns
  `authentication.getName()` = `"truckloading"`, set in `@BeforeEach`. Worth knowing for the next editor:
  `anyString()` does **not** match `null`, so if the `SecurityContextHolder` setup were dropped the stub
  would fall through to Mockito's `null` default and `decision.allowed()` would NPE — a confusing red, not a
  silent green.
- **Per-test stub install is genuinely required.** `BaseControllerUnitTest` → `BaseUnitTest` is
  `@ExtendWith(MockitoExtension.class)` (`BaseUnitTest.java:18`), i.e. `STRICT_STUBS`, and T0 issues no
  request. Putting `denyEverythingAndRecord()` in `@BeforeEach` would fail T0 with `UnnecessaryStubbing`.
  The comment's account of this is accurate.
- **T3's `containsExactly` is stable w.r.t. call count.** `preHandle` calls `checkAnyAccess` exactly once
  (`FunctionGuardInterceptor.java:256`), and `deny()` writes status + body + header directly and returns
  `false` — no ERROR dispatch, so the interceptor is not re-entered. One request → one recorded entry. (The
  weakness is the *content* of that entry — F1.)
- **No assertion is satisfied by a wrong status.** All are `isEqualTo(403)`. A typo'd path 404s (standalone
  MockMvc finds no handler, so the interceptor never runs) and fails.
- **Constructor call matches.** The 15-arg `AdminActionController` signature (:74-89) is passed in order:
  `keycloakService, 5000, replenishJob, cleanUpOldMessagesJob, orderReleaseJob,
  releaseExpiredPickingOrdersFromUserJob, stockSummaryExportJob, messageService, syspropRepository,
  httpRestService, syspropService, pickingorderRepository, pickingorderUnitloadRepository,
  pickingorderBusinessService, accessAuditService`.
- **`SdrTestGuards.inert()` is the right harness** — mode `OFF`, short-circuits before reading a request
  attribute, and `SdrFunctionGuard.isSpringDataRestHandler(AdminActionController.class)` is `false` anyway.
- **No existing test breaks.** `AdminActionControllerUnitTest` builds its MockMvc with the guardless
  `setupMockMvc(...)` (`BaseControllerUnitTest.java:66-76`), so its 200-asserting tests at :121/:141/:161/:181/:207/:235
  are unaffected by the annotations. Surefire excludes only `**/*IntegrationTest.java` and `**/*E2ETest.java`
  (`pom.xml`), so both the new `*UnitTest` and the `*ContextTest` pin do run in the `mvn test` lane.

### Q4 · The pin edit

- **The three "ungated" rows are genuinely free of both mechanisms.** `resolve()` and
  `hasMethodSecurityGate()` both search the **declaring class** with `AnnotatedElementUtils.findMergedAnnotation`
  (`TYPE_HIERARCHY`), so a class-level gate on `AdminActionController` *or inherited from `AdminController`*
  would be seen. `AdminActionController` carries none; `AdminController`'s `@PreAuthorize`s are all
  method-level (:79, :107, :120, :133, :142, :154, :175, :237, :247). So `triggerUpdateStock`,
  `triggerReleaseExpiredPickingOrdersFromUser` and `finishStuckPickingOrder/{number}` all resolve to `""`
  today and carry no method-security annotation. Correct.
- **`hasSize(131)` is right** — counted independently, see F3.
- **Excluding `accessAudit` is correctly reasoned.** `row(class, path)` with no functions stores `""`
  (`String.join("+", new TreeSet<>(Set.of()))`), and the drift test adds a *second* condition for such rows —
  `want.getValue().isEmpty() && methodSecurityGated.contains(want.getKey())` → wrong. `accessAudit` carries
  `@PreAuthorize`, so an empty-value row for it would fail today. The comment says exactly this, and the
  stated consequence also holds: the class-level mutant is caught by the three sibling rows (each flips
  `""` → `WEB_UI_VIEW_IMPORT_DATA`), not by an `accessAudit` row.
- **Bonus the comment undersells.** Because both `resolve()` and the interceptor
  (`AnnotationUtils.findAnnotation(declaring, …)`, `FunctionGuardInterceptor.java:238-240`) walk superclasses,
  those same three rows also catch a `@RequiresFunction` placed on **`AdminController`** — the other
  prohibition in plan §3. The comment claims only the `AdminActionController` case.
- **Sequencing is right**: the drift test and `thePinHasNotBeenQuietlyShrunk` are separate `@Test`s, so a
  row deletion cannot be hidden behind the drift assertion throwing first.

### Q5 · Plan claims vs. what the diff delivers

Delivered as claimed: all five §2 rows (C30-C34); zero new constants; no Flyway file; no `WmsConstants`
change; §3's three prohibitions all honoured.

§2.1's mechanism claims spot-checked and true:
- `WebConfig.java:86-87` is literally `public MappedInterceptor functionGuardMappedInterceptor() { return new MappedInterceptor(new String[] {"/**"}, functionGuardInterceptor); }`
- the `annotation == null` / `GUARDED` fall-through is at `FunctionGuardInterceptor.java:237-253`, and
  `checkAnyAccess` at :256 — the plan's "around :238-260" is close enough
- `SecurityConfiguration.java:157-160` does admit an authenticated `wms_user` to `/v3/adminAction/**`

§4.4's "no arch rail inspects these five sites" — verified. `FunctionGuardArchTest` AC-1/AC-2/AC-3 all
iterate `GOLDEN_MAP` / `guardedController(...)`, i.e. the 14 `GUARDED` classes; its `SBDEV-2967-C G-1/G-2`
rails are scoped to the `controller/rest` package; `ActionGuardAnnotationContractUnitTest` pins a fixed list
of 13 handlers (`assertThat(EXPECTED).hasSize(13)`). `AdminActionController` appears in none of them, so
nothing breaks and nothing covers the new sites except the two tests in this diff.

§7's "`orderReleaseJob.doCalculation(` appears at exactly two sites" — verified:
`AdminActionController.java:110` and `SchedulingConfiguration.java:204`. (The plan's `:108` is the
pre-change number.)

Deviations from the plan: F4 (128 vs 131) and §4.3's mutant table not recording the three sibling rows the
implementation had to add to kill the class-level mutant.

---

## Not verified (bounds of this lane)

- No build, no test run — the maven suite was already running in this worktree. Every claim above about test
  *outcomes* is derived from reading the code paths, not from a green/red run.
- The five non-`dev_wh01_om1` tenant populations (`35/7/15/23/9`) were not re-measured.
- Whether `triggerOrderReplenish`'s two jobs (`orderReleaseJob` **and** `replenishJob`, :110-111) matter to
  the gate choice — they do not, but I did not audit their side effects.
- Runtime behaviour on a real deployment (no live probe against dev).
