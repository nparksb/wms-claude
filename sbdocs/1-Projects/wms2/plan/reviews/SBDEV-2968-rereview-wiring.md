# SBDEV-2968 re-review — the wiring pin (commit `dde7953`)

status: complete
reviewer: independent lane (rereview-wiring)
date: 2026-08-21
worktree: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-2968`
scope: commit `dde7953` "pin the gate's WIRING, not just its internals" + what it touches

## Method

1. Read the new test + the five production files it claims to pin.
2. Apply each of the 5 claimed-killed mutants by hand, run the test, revert.
3. Hunt for vacuous assertions and for a remaining single-line disable-with-green-suite.
4. Audit verify rows A20, A20a–A20d.

Findings appended below as established.

---

## Findings

(none yet — in progress)
### Baseline (established by running)

- `mvn -o clean test -Dtest=FunctionGuardWiringUnitTest` → **6/6 green** on `dde7953`.
- Gate-wide set (`FunctionGuardWiringUnitTest, FunctionGuardInterceptorUnitTest,
  FunctionGuardStartupAssertionUnitTest, FunctionGuardArchTest, FunctionGuardMockMvcUnitTest,
  AccessServiceUnitTest, AccessAuditServiceUnitTest, SecurityConfigurationTest,
  ReplenishControllerUnitTest, AdminActionControllerUnitTest, UtilRestControllerUnitTest`)
  → **157 tests, 0 failures**. This is the reference for every mutant below.

### Mutation results — the 5 mutants the commit claims to kill

| # | Mutant | Claim | Measured |
|---|--------|-------|----------|
| M1 | `WebConfig:35` registration line removed | killed | **KILLED** — 3 failures (`guardIsRegistered`, `guardMatchesAGuardedPath`, `guardMatchesAnArbitraryPath`) |
| M2 | pattern → `/__mutant_never_matches__` | killed | **KILLED** — 2 failures (both path tests); `guardIsRegistered` correctly still passes |
| M3 | pattern → `/v3/**` | killed | **KILLED** — 1 failure (`guardMatchesAnArbitraryPath:117`) |

(M4, M5 below.)

#### METHODOLOGY HAZARD (not a defect in the code under review) — Low

On my **first** attempt, M3 (`/v3/**`) reported **BUILD SUCCESS, 6/6 green** under
`mvn -o test` (no `clean`). Three subsequent attempts — one with `clean`, two without —
all killed it correctly, and `strings target/classes/.../WebConfig.class` confirmed the
mutant pattern was in the bytecode on those runs. I could not reproduce the green run, so
the most likely cause is the `maven-compiler-plugin` incremental staleness check comparing
an mtime that landed inside the same-second window as the previous compile, leaving the
prior `/**` class in place.

**Why it matters for this ticket specifically:** the same failure mode makes a mutation
run report *killed* when the mutant never reached the bytecode, i.e. it can manufacture
false confidence in exactly the direction this whole review exists to check. Any future
mutation pass on this repo should use `mvn -o clean test`, or verify the mutant is in the
compiled class (`strings target/classes/…`), before recording a verdict.

| # | Mutant | Claim | Measured |
|---|--------|-------|----------|
| M4 | `GUARDED` → `Set.of()` | killed | **KILLED** — 2 failures, both in the new test; no pre-existing test caught it |
| M5 | empty-annotation branch → `allow()` | killed | **KILLED** — 1 failure, `emptyFunctionListDenies:202`; no pre-existing test caught it |

**All 5 claimed mutants are genuinely killed. Verified by running, not reasoned.** The new
test earns its place: for M4 and M5 it is the *only* thing in the 157-test gate set that goes red.

---

## F1 — HIGH · dropping `@Configuration` from `WebConfig` disables the entire gate, suite stays green

`WebConfig.java:7` (`@Configuration`) — **proved by running.**

```
mutant: delete line 7 `@Configuration` from WebConfig
result: 157 tests, 0 failures, BUILD SUCCESS
```

`WebConfig` is registered **only** by `@Configuration` + component scan. I grepped the whole
tree: nothing `@Import`s it, nothing autowires it, there is no `META-INF/spring.factories`,
and the only other reference to the type anywhere is the new test's own
`new WebConfig(newInterceptor())`. So without the stereotype it is not a bean, Spring never
collects it as a `WebMvcConfigurer`, `addInterceptors` is never invoked, and **no
`@RequiresFunction` is enforced on any endpoint**.

Boot still succeeds: `FunctionGuardInterceptor` remains a `@Component` (just unused), and
`FunctionGuardStartupAssertion` still passes because all eleven controllers do carry their
annotation — it audits annotation presence, never interceptor registration. So the failure is
silent in exactly the way the headline defect was.

**This is the same blind spot, moved up two lines.** The fix pinned `WebConfig:35` behaviourally
but the new test reaches that line by calling `new WebConfig(...).addInterceptors(registry)`
directly — a hand-constructed instance can never observe whether Spring would have constructed
one. Line 35 is now asserted; the class's bean-ness is not.

**Concrete failure scenario.** `net.aim_ai.wms` contains a second, pre-existing
`WebConfigurer implements WebMvcConfigurer` (`WebConfigurer.java:41`) which *also* declares
`addResourceHandlers`, duplicating `WebConfig`'s only pre-SBDEV-2968 method. Someone tidying that
genuine duplication — folding `WebConfig` into `WebConfigurer`, or de-annotating the one that
"looks redundant" — turns off all mobile authorization, and CI is green. (The duplication predates
this ticket; the new consequence is that `WebConfig` is now load-bearing for authorization.)

**Fix (cheap, no production change):** add to `FunctionGuardWiringUnitTest.Registration`

```java
assertThat(WebConfig.class.isAnnotationPresent(Configuration.class)).isTrue();
assertThat(WebMvcConfigurer.class).isAssignableFrom(WebConfig.class);   // or the reverse arg order
assertThat(WebConfig.class.getPackageName()).startsWith("net.aim_ai.wms");  // inside the scan root
```

---

## F2 — MEDIUM · `excludePathPatterns` un-gates any guarded controller you name, suite stays green

`WebConfig.java:35` — **proved by running.**

```
mutant: .addPathPatterns("/**").excludePathPatterns("/v3/putaway/**", "/v3/lookup/**")
result: 157 tests, 0 failures, BUILD SUCCESS
```

`/v3/putaway` and `/v3/lookup` are the real `@RequestMapping` prefixes of `PutawayController:24`
and `LookupController:27`, two of the eleven guarded controllers. Excluding them makes every one
of their endpoints publicly reachable — `MappedInterceptor.matches` applies excludes before
includes, so the interceptor is registered, matches the test's probe path, and is bypassed for
those two controllers.

The new test cannot see this: `guardMatchesAGuardedPath` probes exactly one path,
`/v3/picking/pickTimeOutValue`, and the test comment argues that one path per controller "would
be redundant: the registration is one pattern for all of them". That reasoning holds for the
*include* pattern and fails for *excludes*, which are per-prefix by construction. Excluding
`/v3/picking/**` **is** caught; excluding any of the other ten is not.

**Fix:** parameterise `guardMatchesAGuardedPath` over one representative path per guarded
controller (`@ParameterizedTest` + eleven prefixes), or derive the prefixes from each guarded
class's `@RequestMapping` by reflection so the list cannot drift from `GUARDED`.

---

## F3 — LOW/MEDIUM · the *startup assertion's* wiring is unasserted, two ways

Both **proved by running** (157 tests, 0 failures, BUILD SUCCESS on each):

| mutant | effect |
|---|---|
| delete `@Component` from `FunctionGuardStartupAssertion.java:35` | the boot check never runs |
| `findUnannotatedGuardedHandlers(handlers)` → pass `java.util.Set.of()` instead of `FunctionGuardInterceptor.GUARDED` (`FunctionGuardStartupAssertion.java:70`) | the boot check becomes permanently vacuous |

The second is the review's own **M9**, which the commit message says survives — **confirmed, it does.**
Impact is bounded: the interceptor still fail-closes at runtime, so this only removes the
defence-in-depth "failed deploy instead of production 403". Hence Low/Medium, not High.

**But the commit's justification for leaving M9 open is wrong.** It says M9 "needs an input where
the guarded set matters … no such class can exist" and therefore "a production design change
(item 5)". The *behavioural* argument is correct; the conclusion that no test can close it is not.
ArchUnit is already on this test classpath (`FunctionGuardArchTest`), and a field-access rule kills
M9 with no production change:

> assert that `FunctionGuardStartupAssertion` accesses the field
> `FunctionGuardInterceptor.GUARDED` — swapping in `Set.of()` removes that access.

Same for the `@Component` mutant: `assertThat(FunctionGuardStartupAssertion.class
.isAnnotationPresent(Component.class)).isTrue()` is one line. Deferring both to a design change
overstates the cost.

---

## F4 — LOW · `guardMatchesAGuardedPath` / `guardMatchesAnArbitraryPath` FALSE-RED on a correct refactor

**Proved by running.** Mutant: `registry.addInterceptor(functionGuardInterceptor);` — i.e. drop
`.addPathPatterns("/**")` entirely.

```
result: 157 tests, 2 failures — guardMatchesAGuardedPath:107, guardMatchesAnArbitraryPath:117
```

In production this variant is **correct and equivalent** (an interceptor registered with no path
patterns applies to every request). The test fails because `matchingGuards`
(`FunctionGuardWiringUnitTest.java:120-131`) does
`.filter(MappedInterceptor.class::isInstance)`, and `InterceptorRegistration.getInterceptor()`
returns the **raw** interceptor rather than a `MappedInterceptor` when neither include nor exclude
patterns are set.

The failure messages then assert the opposite of the truth — *"the gate is installed and inert,
which is indistinguishable from absent at runtime"* — for a configuration in which the gate is
maximally enabled. This repo has been burned by reds that read as honest work-not-done; this is the
mirror image, a red that reads as an honest security failure. Fix: in `matchingGuards`, count a
bare `FunctionGuardInterceptor` in the registry as matching every path.

---

## F5 — MEDIUM · a one-line method-level `@RequiresFunction` re-gates an endpoint, suite green

**Proved by running.** Mutant: insert
`@RequiresFunction(WmsConstants.FunctionEnum.MOBILE_UI_VIEW_INFO)` above
`PickingController#pickTimeOutValue`.

```
result: 157 tests, 0 failures, BUILD SUCCESS
```

Per `RequiresFunction`'s own javadoc (lines 13-15) a method-level annotation **replaces** the class
default rather than adding to it, so that one line moves an endpoint out of `MOBILE_UI_VIEW_PICKING`
onto an unrelated function with nothing red.

The golden map (`FunctionGuardArchTest` AC-2) is **class-level only** — it reads
`functionsOn(c)` for the eleven classes. Method-level overrides are pinned exhaustively for exactly
one controller (AC-28: `ReplenishController`, `getDeclaredMethods()` +
`containsExactlyInAnyOrder("requestLocation", "requestAmount")` — a correct, non-vacuous pin) and
for exactly one named method on a second (AC-14: `LookupController#locationByLocationName`). The
other **nine** guarded controllers, and every other method on `LookupController`, have no
"no method-level override" assertion.

This matters more than it looks because AC-14 makes the pattern legitimate and unremarkable in
review: a method-level override on a guarded mobile controller is a thing this codebase does on
purpose, so a reviewer has no signal that a new one is unreviewed.

**Fix:** one exhaustive assertion — for each of the eleven, the set of methods carrying a
method-level `@RequiresFunction` must equal a declared allow-list (empty for nine of them).

---

## Ruled out — mutants I applied that are NOT defects

- **`@Component` off `FunctionGuardInterceptor`** — survives the suite (157/0) but is **fail-loud**
  in production: `WebConfig`'s constructor requires the bean, so boot dies with an unsatisfied
  dependency. Not a silent disable.
- **`excludePathPatterns("/v3/picking/**")`** (the path the test probes) — correctly **KILLED**,
  1 failure at `guardMatchesAGuardedPath:107`. This is the control that establishes F2 precisely:
  the probed prefix is covered, the other ten are not.
- **Vacuous-assertion sweep.** I checked the new test for the shapes this repo has burned on:
  no `for`-each over a possibly-empty collection; `containsExactlyInAnyOrderElementsOf` (not
  `containsAnyOf`) on the guarded set; `EXPECTED_GUARDED` is a hard-coded literal set of eleven
  `Class` objects, so it cannot silently shrink with production. `AC-28`'s
  `getDeclaredMethods()` filter does feed `containsExactlyInAnyOrder`, so it is not the
  empty-list-vacuous shape either. One genuinely vacuous assertion exists — see F6.

---

## F6 — MEDIUM · claim (e) is not delivered: `interceptorAndStartupAssertionShareOneGuardedSet` asserts nothing about the boot assertion

`FunctionGuardWiringUnitTest.java:163-186`. §14.20's fix table lists *"the boot assertion reads that same
set"* among the six delivered pins. The test body is:

```java
assertThat(FunctionGuardStartupAssertion.findUnannotatedGuardedHandlers(List.of(), guarded)).isEmpty();
assertThat(guarded).containsExactlyInAnyOrderElementsOf(EXPECTED_GUARDED);
```

- assertion 1 passes an **empty handler list**, so it holds for any `guarded` whatsoever. The test's own
  comment says so: *"an empty handler list can never yield a violation, whichever set is used"*. It is the
  vacuous shape the brief asked me to hunt for — it just happens to be a knowingly vacuous one.
- assertion 2 is a **verbatim duplicate** of `guardedSetIsExactlyTheEleven` twelve lines above.

So the test asserts nothing the previous test did not. **Measured confirmation, two ways:** under M4
(`GUARDED` emptied) this test failed *only* on its duplicate second assertion, at line 182; and under E4
(the 1-arg overload rewired to `Set.of()`) it passed. There is no coupling assertion here.

The **test file** is scrupulously honest about this — the inline ⚠️ block spells out that M9 survives. The
**plan is not**: §14.20's table presents the pin as delivered, with the M9 caveat displaced into a separate
"Still open" line about the *interceptor seam*. A gatekeeper reading the table gets a stronger claim than the
code supports. §14.19's fix list item 1 explicitly required *"boot assertion's production overload"* to be
pinned; it is not. Either deliver it (see F3 — one ArchUnit field-access rule) or amend §14.20's row 1 and
strike the clause.

---

## F7 — MEDIUM · verify rows `A20`–`A20d` are all token greps; two of them pass against a test file with zero assertions

**All measured.** Verify script:
`/home/nampark/dev/wms-claude/sbdocs/9-System/scripts/verify-SBDEV-2968-mobile-ui-function-gating-enforcement.sh:115-121`.
Run against the correct shadow root (`v2/wms2-api` → the api worktree, `v2/wms2-mobile-ui` → the
**mobile worktree**, not the main checkout) the script reads **129 pass / 0 fail / 2 skip**, matching the plan.
No permanent reds, no wrong-file rows, and no unbounded-`.*?`-under-`/s` row in this group — `A20a` uses a
fixed-string `grep -q` and correctly guards `[ -f ... ] || exit 1` first.

What they do and do not detect:

| row | assertion | verdict |
|---|---|---|
| `A20` | `grep -E 'FunctionGuardInterceptor|addInterceptor'` on `WebConfig.java` | unchanged from the pre-review row; the original never-matching mutant retains both tokens |
| `A20a` | `grep -q 'addPathPatterns("/**")'` — a fixed-string token grep | catches the never-matching and `/v3/**` mutants. **Blind to F1 and F2** — see below |
| `A20b` | `file_exists FunctionGuardWiringUnitTest.java` | existence only |
| `A20c` | `grep -E 'MappedInterceptor'` on the test file | **satisfied by the javadoc and by the import line** |
| `A20d` | `grep -E 'containsExactlyInAnyOrderElementsOf'` on the test file | **satisfied by a comment naming the method** |

Negative tests I ran:

1. **Test file deleted** (pre-fix replay) → `A20b/c/d` correctly go **FAIL**. The rows do have signal.
2. **Test file gutted** — class body replaced with a single comment, javadoc and imports kept, **zero
   assertions left** → `A20b` **PASS**, `A20c` **PASS**, `A20d` FAIL. Two of the three "the test pins it"
   rows are green against a test that pins nothing. `A20c` is green off `{@link MappedInterceptor}` in prose
   and `import …MappedInterceptor;`.
3. **Assertion weakened, token preserved in a comment** — both
   `containsExactlyInAnyOrderElementsOf(EXPECTED_GUARDED)` calls changed to
   `containsAnyElementsOf(EXPECTED_GUARDED); // NOTE: containsExactlyInAnyOrderElementsOf was here`
   → verify **129/0/2, `A20d` PASS**; then `GUARDED` trimmed from eleven to ten (dropping
   `OrderCancellationController`) → `FunctionGuardWiringUnitTest` **6/6 green**. That is precisely the
   §3.1-A8 / Critic-F1 regression the pin exists to prevent, green in both the suite and the verify script.
   (M4 established that these two assertions are the *only* coverage of `GUARDED` anywhere in the 157-test
   gate set, so weakening them removes it entirely.)
4. **F1 + F2 applied together** — `@Configuration` deleted **and**
   `excludePathPatterns("/v3/putaway/**")` added → verify reports **129 pass, 0 fail, 2 skip**, with
   `A20`–`A20d` all PASS, on a tree where mobile authorization is entirely off and `PutawayController` is
   additionally un-gated.

**Result 4 is the headline.** The property the review's original finding was about — *"the entire gate can be
switched off and the verify script stays green"* — is still true of the verify script after the fix. `A20a`
closed the one specific token the reported mutant happened to change.

**Structural cause, worth recording separately:** the script has **111 `run` rows and not one of them
executes a test.** `grep -niE 'mvn|maven|gradle|yarn|npm|jest|surefire'` over all 484 lines returns nothing
but a section *heading* ("Tests — the controls that make the above provable"). Every row under that heading
greps for the presence of test files and identifiers. That is a defensible choice given
`verify-plan-template`'s `mvn_test_passes` is known to be permanently red in this repo — but it means a
verify count on this ticket can never be evidence that any test passes, only that certain strings exist.
Fix for the rows themselves: assert *code*, not tokens — strip comments (the script already has
`file_not_contains_code` for exactly this) and require the AssertJ call to appear on a line containing
`assertThat`/`.contains`, or better, replace `A20b`–`A20d` with a single row that runs
`mvn -o test -Dtest=FunctionGuardWiringUnitTest` when `mvn` resolves and `skip`s (not FAILs) when it does not.

---

## Verdict

**The fix under review does what its commit message says on the narrow point, and I confirmed it by
execution: all 5 claimed mutants are genuinely killed** (registration removed · never-matching pattern ·
narrowed to `/v3/**` · `GUARDED` emptied · empty annotation allows), and for `GUARDED` and the
empty-annotation policy the new test is the *only* thing in the 157-test gate set that goes red. That is real
work and it closes the specific defect that was reported.

**But the blind spot has been narrowed, not closed. I found four further one-line edits that switch off some
or all of the enforcement with the suite green — three of them with the verify script green too:**

| | finding | one-line edit | blast radius | suite | verify |
|---|---|---|---|---|---|
| **F1** | High | delete `@Configuration` from `WebConfig:7` | **all** mobile authz, silently | 157/0 green | 129/0 green |
| **F2** | Medium | append `excludePathPatterns("/v3/<any>/**")` | any of 10 guarded controllers | 157/0 green | 129/0 green |
| **F5** | Medium | add a method-level `@RequiresFunction` on 9 of the 11 | one endpoint re-gated | 157/0 green | 129/0 green |
| **F3** | Low/Med | delete `@Component` from `FunctionGuardStartupAssertion`, or M9 | the boot check only | 157/0 green | not graded |

Plus **F6** (a delivered-pin claim the code does not support, and which §14.19 item 1 required),
**F7** (the verify rows are token greps; two pass against a zero-assertion test file), and **F4**
(a false red that reads as a security failure on a correct refactor).

**Recommendation: NOT clear as-is.** F1 is the same shape, the same blast radius and the same silence as the
defect this commit was written to fix, and it costs three lines of test to close. F1, F2 and F6 should land
before the PR; F5 and F7 are cheap and I would take them in the same pass; F3 and F4 are fine to defer with a
note. None of this requires the production design change (the injectable guarded set) that §14.19 item 5 is
holding — every fix above is test-side or verify-side.

*status: COMPLETE*
