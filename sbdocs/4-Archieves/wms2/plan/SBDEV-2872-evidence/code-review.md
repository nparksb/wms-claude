# SBDEV-2872 code review (independent lane)

Reviewer: code-reviewer lane, separate from the authoring context. Read-only. No Maven run (another build was active in the worktree).
Snapshot: working tree of `.claude/worktrees/wms2-api/SBDEV-2872` vs `origin/develop` (`64fbbb07`), read 2026-10-14 ~14:51 EDT.
**The author was still editing during the review.** `Authority.java` changed at 14:50:55, and `UserAdministrationController.java` joined the diff partway through. Findings cite the state at 14:51.

Files reviewed: 9. That is the 8 in `git diff origin/develop --stat` plus the untracked `MethodSecurityExpressionsResolveArchTest.java`.

## How the evidence was gathered (no Maven)
- **javap on `spring-security-core` 6.5.7 and 6.1.0** (the version at `bd330a3a`):
  - `DefaultMethodSecurityExpressionHandler` has `private ... createSecurityExpressionRoot(Supplier, MethodInvocation)`.
  - All four interceptors in 6.5.7, and `PreAuthorizeAuthorizationManager` in 6.1.0, call `createEvaluationContext(Supplier, Object)`.
  - That private method builds `new MethodSecurityExpressionRoot(Supplier)` and calls `setDefaultRolePrefix(getDefaultRolePrefix())`.
  - **Conclusion: the author's core finding is confirmed.**
- **`git show bd330a3a`:**
  - It switched `@EnableGlobalMethodSecurity` + `GlobalMethodSecurityConfiguration.createExpressionHandler()` to `@EnableMethodSecurity` + `@Bean`, on Boot 3.1.0.
  - **Conclusion: the new `Authority` javadoc claim ("HTTP 500 ... since 2025-09-20, not since the rename") is confirmed.**
- **A standalone probe in my scratchpad**, compiled with `javac` against `spring-expression` 6.2.15 and `spring-security-core` 6.5.7 from `~/.m2`:
  - It copies `walk()` and `rootMembersMissing()` verbatim.
  - It runs them against the real `MethodSecurityExpressionRoot` type on 21 expressions.
  - Separately, it checks SpEL scope and null semantics at runtime.
- **The author's surefire reports** at `target/surefire-reports/` (14:51:48) show 12/12 green:
  - The outer `everyMainExpressionResolves` is filed under the `$SbAdminOnProductionRoot` XML. That is the known nested-report trap, and the test did run.
  - **This is the author's evidence, not mine.** I did not execute the suite.
- **lsp_diagnostics was not run.** It needs a compile, and Maven was off-limits. The surefire run above shows that the files compiled at 14:51.

---

## Stage 1: spec compliance

| AC | Verdict | Evidence |
|---|---|---|
| Every @Pre/PostAuthorize/@Pre/PostFilter in src/main parses and evaluates without SpelEvaluationException against a production-wired root | **MET, with false-positive caveats (M1)** | `scan()` goes through `new MethodSecurityConfig().methodSecurityExpressionHandler()` and the `Supplier` overload, then derives `rootType` from what that returns (`MethodSecurityExpressionsResolveArchTest.java:292-294`) |
| Covers literal-valued annotations, not just constants | **MET** | The scan is reflective, so a literal and a constant look the same at runtime. Literal fixtures are at `:510-547` |
| Reverting `IS_SB_ADMIN` to `"isSbAdmin()"` turns it red | **MET** | Three things would go red: `everyMainExpressionResolves`, which finds 13 sites and both instruments fire; `grantsAdminDeniesUser`; and `MethodSecurityEnablementContractTest.sbAdminRoleConstantHasNotDrifted`'s literal pin. The author's caveat about constant inlining is real: CI runs `clean verify` |
| Decide the fate of `getExp*` and `hasDetail` | **MET** | Both were deleted. `git grep` over `src` finds no caller and no remaining reference outside historical prose |
| Nothing extra | **MET** | The `UserAdministrationController` javadoc date correction follows directly from the new history finding |

Stage 1 passes.

---

## Stage 2: findings

### Counts by severity

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 4 |
| LOW | 9 |

### M1. The evaluation instrument false-flags the canonical, correct idiom of 3 of the 4 annotations it covers
**Severity:** MEDIUM. **Confidence:** HIGH (reproduced).

**File:** `MethodSecurityExpressionsResolveArchTest.java:343-349`

```java
Object[] args = defaultArgs(method);
...
handler.setReturnObject(null, ctx);
expression.getValue(ctx, Boolean.class);
```

**Issue:** Arguments are null, `returnObject` is null and `filterObject` is never set. SpEL property access on null throws.

The probe confirms it: `#dto.clientId == 1` with `#dto = null` throws `SpelEvaluationException: EL1007E: Property or field 'clientId' cannot be found on null`.

So each of these correct expressions would be reported as a violation:
- `@PostAuthorize("returnObject.owner == authentication.name")`
- `@PreFilter("filterObject.owner == authentication.name")`
- `@PostFilter(...)` written the same way
- `@PreAuthorize("#dto.clientId == ...")`

The first three are the Spring reference-doc idioms for exactly the annotations this ticket extended coverage to.

In production, values are never null in these positions:
- `PostAuthorizeAuthorizationManager` sets the real return value.
- The filter interceptors call `handler.filter(...)`, which sets `filterObject` per element and never evaluates on an empty collection.

None of these idioms exists in src/main today (`git grep` finds only 13 `@PreAuthorize(Authority.IS_SB_ADMIN)`). The guard therefore passes now, but it will fail the first person who writes correct code with these idioms. The usual "fix" is to sprinkle `?.`, which changes the gate's semantics (a null then compares unequal and denies). The other usual "fix" is to weaken the rail.

`GoodFixtures` hides this. Its `@PostAuthorize` fixture is `returnObject == null or ...` (`:563`), which deliberately avoids dereferencing.

The class javadoc's blind-spot bullet (`:84-86`) also has it backwards. It describes null arguments as causing missed checks, but they cause **false violations**.

**Fix:**
- Option (a): when evaluation throws `SpelEvaluationException` with message code `PROPERTY_OR_FIELD_NOT_READABLE_ON_NULL` or `METHOD_CALL_ON_NULL_OBJECT_NOT_ALLOWED`, record it as "inconclusive" rather than a violation, and rely on the AST walk for root members.
- Option (b): for `@PreFilter`/`@PostFilter`, call `ctx.getRootObject()`'s `setFilterObject(new Object())`. For `@PostAuthorize`, set a non-null sentinel `returnObject`. Neither changes what is reported for root-member typos.
- Either way, add the three canonical idioms to `GoodFixtures`, and correct `:84-86`.

### M2. The AST scope rules in `walk()` are wrong in two places, and none of the three non-default rules is pinned by a self-test
**Severity:** MEDIUM. **Confidence:** HIGH (each case reproduced by the probe).

**File:** `MethodSecurityExpressionsResolveArchTest.java:396-406`

```java
} else if (node instanceof MethodReference) {
    childOnRoot = true; // arguments
} else if (node instanceof Selection || node instanceof Projection) {
    childOnRoot = false;
```

**(a) False positive: method arguments inside a selection or projection.** SpEL evaluates a `MethodReference`'s arguments against the **scope root**, not the evaluation root (`state.getScopeRootContextObject()`). `Selection` and `Projection` call `enterScope()` per element, so inside `.?[...]` and `.![...]` the scope root is the element.
- Runtime check: with root `Rec("root")`, `{'xyz'}.![concat(toUpperCase())]` evaluates to `[xyzXYZ]`. That means `toUpperCase()` ran on the element.
- The walk instead forces `childOnRoot = true` for every method's arguments. `{1,2}.?[hasAuthority(name)]` is reported as `[name]` missing on the root.

**(b) Missed check: indexer keys.** The javadoc at `:362-364` says "an indexer's key [is] evaluated against the root", but no branch implements it. `Indexer` falls into `else` and inherits the parent's scope, which is always off-root because an indexer is never child 0 of a compound.
- Runtime check: `{1,2,3}[name.length() - 4]` resolves `name` on the root.
- The probe shows `principal.claims[typoKey]` and `#m[typoKey2]` both produce `[]`.
- Caveat: when the target is a `Map`, SpEL treats a bare identifier key as a string literal. So the correct rule is "root scope, unless the key is a bare `PropertyOrFieldReference`". That is why the current skip is accidentally right for map access.

**(c) The scope rules have no self-test.**
- Changing the `CompoundExpression` rule to `childOnRoot = false` (never check the head of `a.b`) survives every self-test. No fixture has a typo at the head of a compound, such as `typoHead.name != null`.
- Changing the `MethodReference` rule to `childOnRoot = onRoot` survives. No fixture has a typo in an argument, such as `hasAuthority(typoArg)`.
- Changing the `Selection`/`Projection` rule survives. No fixture uses either.
- Removing the `isX` branch of property derivation survives. No good fixture reads an `is`-property such as `authenticated`.

The positive control proves the checker finds *something*. It does not prove that these four rules hold.

**Fix:**
- Track two flags, `onRoot` and `scopeIsRoot`.
  - `MethodReference` args: `childOnRoot = scopeIsRoot`.
  - `Selection`/`Projection` body: `scopeIsRoot = false`, `onRoot = false`.
  - `Indexer` key: `childOnRoot = scopeIsRoot && !(child instanceof PropertyOrFieldReference)`.
- Add bad fixtures `"typoHead.name != null"` and `"hasAuthority(typoArg)"`.
- Add good fixtures `"authenticated and principal.claims.?[value != null] != null"` and `"{'a'}.![concat(toString())] != null"`.

Treatment of the other node types, all verified on the probe AST dumps:

| Node type | Result |
|---|---|
| `Ternary`, `Elvis`, `OpAnd`/`OpOr`, `OperatorNot`, `InlineList`, `FunctionReference` (`#fn(typo)` → flagged, and correct because function args use the active context), safe-navigation `?.` (same `CompoundExpression` shape) | Correct |
| `TypeReference` `T(a.b.C)` | Correct. The path is `Identifier` nodes, not `PropertyOrFieldReference`, so no false positive |
| `ConstructorReference` | Correct. The path is a `QualifiedIdentifier` |
| `BeanReference` | Leaf, correctly ignored |

### M3. A silent catch can drop a whole class's method-level annotations without reporting it
**Severity:** MEDIUM. **Confidence:** MEDIUM.

**File:** `MethodSecurityExpressionsResolveArchTest.java:491-496`

```java
try {
    all.addAll(Arrays.asList(clazz.getMethods()));
    all.addAll(Arrays.asList(clazz.getDeclaredMethods()));
} catch (Throwable ignoredMissingSignatureDependency) {
    // A method whose signature references an absent optional type; the class-level check still ran.
}
```

**Issue:**
- `Class.forName(name, false, loader)` at `:131` does not resolve method signatures. So the "unloadable must be empty" assertion at `:142-145` cannot see a class whose `getMethods()` throws `NoClassDefFoundError`.
- If `getMethods()` throws, `getDeclaredMethods()` is never attempted, so that class's method-level gates are skipped and nothing records it.
- The surrounding code is careful to fail closed elsewhere. `ArchUnitImportReleaseRuleTest:66-70` does ("Fail closed: a class the rail cannot load is a class it cannot grade").
- Probably zero affected classes today, because the test classpath is complete. That is why this is rated MEDIUM and not higher.

**Fix:** collect `clazz.getName() + " (" + t + ")"` into a list returned via `Scan`, and assert that the list is empty next to `unloadable`. Try `getDeclaredMethods()` in its own try block.

### M4. The `Authority` javadoc ships a new history claim while the author is still editing it, and the root-cause narrative disagrees with the active SBDEV-2643 and SBDEV-3017-B1 plan docs
**Severity:** MEDIUM. **Confidence:** HIGH that the docs disagree; LOW-impact for code.

**Files:**
- `src/main/java/net/aim_ai/wms/Authority.java:32-40` ("SBDEV-2863, as corrected by SBDEV-2872 ... since 2025-09-20, not since the rename")
- `sbdocs/1-Projects/wms2/plan/SBDEV-3017-B1-mvc-write-surface-gating.md:3192-3194`, which proposes extending `CustomMethodSecurityExpressionRoot` so that `@PreAuthorize("hasFunction('X')")` becomes available

**Issue:**
- The javadoc claim is **correct**. I verified it independently: `bd330a3a` switched to `@EnableMethodSecurity` on Boot 3.1.0, and Spring Security 6.1.0's `PreAuthorizeAuthorizationManager` already used the `Supplier` overload.
- `sbdocs/3-Resources/architecture/wms2-keycloak-role-matrix.md:270-297` has already been updated to match.
- The SBDEV-3017-B1 plan, however, still presents "extend `CustomMethodSecurityExpressionRoot`" as a design option. That class is now deleted, and that override route is exactly the dead path this ticket proved never runs.
- Someone reviving that option would re-create the bug. The `MethodSecurityEnablementContractTest:208-214` comment and the `isEqualTo(DefaultMethodSecurityExpressionHandler.class)` pin would catch a subclass. That is good, but the plan doc still sends people the wrong way.

**Fix:**
- Add a one-line superseded note at `SBDEV-3017-B1...md:3192` pointing to `MethodSecurityConfig`'s javadoc ("override `createEvaluationContext(Supplier, MethodInvocation)`").
- SBDEV-2643's plan and verify script are historical (the verify script defines `F_EXPR_ROOT`/`T_EXPR_ROOT` at `:209`/`:221` but no live row reads them), so leave them.

### L1. False positive on inline-map keys
**Severity:** LOW. **Confidence:** HIGH (reproduced).

**File:** `MethodSecurityExpressionsResolveArchTest.java:393`

**Issue:** `{a: 1}.size() > 0` is reported as `[a]`. `InlineMap` uses a bare `PropertyOrFieldReference` key as a literal name.

**Fix:** skip even-indexed `PropertyOrFieldReference` children of `InlineMap`.

### L2. `#root.x()` and `#this.x()` are not checked by the AST walk
**Severity:** LOW. **Confidence:** HIGH (reproduced).

**File:** `MethodSecurityExpressionsResolveArchTest.java:398-399`

**Issue:** `#root.typoRoot()` produces `[]`. `#root` is literally the root, so this is a cheap gap to close.

**Fix:** in a `CompoundExpression` whose child 0 is a `VariableReference` named `root` (or `this` at top scope), treat child 1 as on-root.

### L3. Property derivation does not match SpEL's `ReflectivePropertyAccessor`
**Severity:** LOW. **Confidence:** HIGH.

**File:** `MethodSecurityExpressionsResolveArchTest.java:372-379`

**Issue:** SpEL 6.2.15 differs from the test's derivation in three ways:
1. It also resolves **record-style** `name()` accessors. The probe shows `name` on a record root evaluates to `n`.
2. It only accepts `isX` when the return type is `boolean`/`Boolean`.
3. It capitalises rather than decapitalises: `URL` → `getURL`, whereas the test derives `uRL`.

On `MethodSecurityExpressionRoot` today this means:
- Possible false positives only for absurd names (`hashCode` as a property).
- Possible missed checks only for a non-boolean `isX`. None exists.

**Fix:** derive the property set by asking SpEL itself: `new ReflectivePropertyAccessor().canRead(ctx, rootInstance, name)` per `PropertyOrFieldReference`. For methods, use a `ReflectiveMethodResolver`. This removes the hand-rolled approximation entirely.

### L4. A misspelled `#param` is never reported
**Severity:** LOW. **Confidence:** HIGH.

**File:** `MethodSecurityExpressionsResolveArchTest.java:82-94` (blind-spot list) and `:388-409`

**Issue:**
- An unknown SpEL variable evaluates to null, with no exception. `#id > 0` with null gives `false` (probe).
- So `@PreAuthorize("#clientld == principal.claims['client']")`, a typo of `clientId`, passes both instruments.
- In production it silently denies. `#x == null or ...` would silently **grant**.
- This is outside the ticket's "SpelEvaluationException" wording, but it is the next sibling of the same defect class, and the blind-spot list omits it.

**Fix:** collect `VariableReference` names from the AST. Compare them against `DefaultSecurityParameterNameDiscoverer.getParameterNames(method)` plus `{root, this}`, and report the unknown ones. At minimum, add the bullet to the blind-spot list.

### L5. The dedupe key is sound but unpinned and only partly explained
**Severity:** LOW. **Confidence:** MEDIUM.

**File:** `MethodSecurityExpressionsResolveArchTest.java:298-315`

**Issue:**
- For method-level lookup, `findMergedAnnotation(m, kind)` on an inherited `Method` searches from that method's declaring class. The result therefore cannot differ per subclass, and deduping by `declaringClass#name+params` loses nothing.
- **Production differs in one way.** Spring Security 6.5 also applies the *target* class's class-level annotation to inherited methods. The test covers that expression separately, once per class and without dedupe (`:303-307`), so no expression goes unchecked. It is evaluated only with `Object.toString()` and no arguments, which is fine for class-level expressions.
- `UniqueSecurityAnnotationScanner` throws `AnnotationConfigurationException` (a 500) when two *different* `@PreAuthorize` sit on an interface method and its implementation. `findMergedAnnotation` silently picks one, so that defect class is invisible here. No case exists today.
- Removing `seen` entirely survives every test. Its only effect is duplicate `sites`.

**Fix:**
- Optionally, assert that `scan.sites` has no duplicates and contains at least one `net.aim_ai.wms.controller.AdminController#` site. That positive control is specific to the inherited path the dedupe exists for.
- Optionally, use Spring Security's own scanner, `SecurityAnnotationScanners.requireUnique(PreAuthorize.class)`, so the test resolves annotations exactly as production does.

### L6. The `sbAdminRoleConstantHasNotDrifted` comment understates the new test
**Severity:** LOW. **Confidence:** HIGH.

**File:** `MethodSecurityEnablementContractTest.java:181-182`

> "MethodSecurityExpressionsResolveArchTest grants its admin fixture Authority.SB_ADMIN_ROLE, so both move together with the constant. Editing Authority.java's constant to "wms_user" would leave all 13 pins green"

**Issue:**
- For the specific example given (`"wms_user"`), the new test **does** go red. `plainUser()` hard-codes `"wms_user"` (`MethodSecurityExpressionsResolveArchTest.java:440`), so `IS_SB_ADMIN` evaluates TRUE for the plain user and `grantsAdminDeniesUser` fails.
- The general point still stands: any value other than `wms_user` moves together and stays green.
- Line 182 is also about 185 characters, from a reflow that was not finished.

**Fix:** pick a neutral example (`"anything_else"`) and rewrap.

### L7. The class javadoc's scope description overstates the implementation
**Severity:** LOW. **Confidence:** HIGH.

**File:** `MethodSecurityExpressionsResolveArchTest.java:361-364`

**Issue:** the javadoc says "a method's arguments and an indexer's key are evaluated against the root". Two problems:
- Both are evaluated against the *scope* root.
- The indexer half is not implemented (M2b).

A reader will trust the stated rule over the code.

**Fix:** correct it together with M2.

### L8. Self-test fixtures and sibling rails: no collision found
**Severity:** LOW (informational). **Confidence:** HIGH.

The fixtures carrying `@PreAuthorize` (`Fixtures`, `ClassLevelFixture`, `GoodFixtures`, `@BrokenComposedGate`) are compiled to test-classes. I checked every rail that imports or reflects test classes, and every rail that could see `@PreAuthorize`:

| Rail | Why the fixtures don't trip it |
|---|---|
| `FunctionGuardArchTest:1043-1060` (AC-26, bans `@PreAuthorize` on mobile controllers) | Iterates `productionGuardedSet()` (production classes by name), so the fixtures are invisible to it |
| `PublicHandlerContractArchTest:131-133` | `.withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)   // ← LOAD-BEARING, pin #17` |
| `MethodSecurityAnnotationSurfaceArchTest:134-136` | `DO_NOT_INCLUDE_TESTS`. It also bans only `@Secured`/`@RolesAllowed`/`@DenyAll`/`@PermitAll` |
| `SingletonTenantStateArchTest:183`, `PutawayConfigActionGuardUnitTest:624-626` | `DO_NOT_INCLUDE_TESTS` |
| `ArchUnitImportReleaseRuleTest:58-60`, which does import test classes | Its rule needs static ArchUnit fields released in `@AfterAll`. The new test's `static JavaClasses mainClasses` is released at `:111-114` (`mainClasses = null;`) |
| `CommentOnlyTestBodyArchTest:117-124` | Grades only `@Test`-family methods. Fixture methods carry no `@Test`, so their empty bodies are not graded |
| `JUnitTagWiringArchTest`, `TestClassTransactionManagerArchTest` | No `@Tag` or `@Transactional` in the new file |
| `TestIdentifierCountArchTest` (`(the\|exactly\|all) N <word>` in `@DisplayName`) | No new `@DisplayName` carries a count of 2 or more |
| Context tests (`SurfaceInventoryContextTest`, `Sbdev3017TrancheGateContextTest`) | Component scan. The fixtures are not `@Component`s |

No action needed.

### L9. Stale references: essentially clean
**Severity:** LOW. **Confidence:** HIGH.

- **Code:** `git grep` over `src` for `CustomMethodSecurityExpression|isAimAdmin|hasDetail|getExpForRole|getExpApp|hasAuthorityIsPrefixIndependent|CustomMethodSecurityExpressionRootUnitTest` finds only deliberate historical prose. That prose is in `Authority.java:24,33-35`, `MethodSecurityConfig.java:56-57`, `MethodSecurityEnablementContractTest.java:211`, and the new test's fixtures.
- **Old false claims:** nothing remaining still asserts "prefix nulled" or "custom root used".
- **`docs/plan/completed/*.md`:** these mention the deleted class in completed plans. Historical; leave them.
- **Line-number citations:** the one that shifted, `MethodSecurityEnablementContractTest:64-67`, is quoted in `Sbdev3017TrancheGateContextTest:904`. That paragraph is already marked historical ("The cited line range had also drifted").
- **Pre-existing staleness, not introduced here:** `PutawayConfigService:258/:288` in `MethodSecurityEnablementContractTest:230` and `PutawayConfigActionGuardUnitTest:76`. The methods now sit at `:325`/`:355`. The PutawayConfigService change in this diff has an equal line count (+2/−2), so it did not shift them.
- **Style:** new over-long lines at `MethodSecurityEnablementContractTest.java:44` and `:182`. Rewrap.

---

## Open questions (low confidence, not blocking)
- **[MEDIUM] Is calling the `@Bean` method directly "production-wired"?**
  - **Confidence:** LOW.
  - **Context:**
    - `scan()` calls `new MethodSecurityConfig().methodSecurityExpressionHandler()` directly. Container post-processing therefore never runs, including `ApplicationContextAware`, which installs the `BeanFactoryResolver`.
    - Today this changes nothing. No `GrantedAuthorityDefaults` or `RoleHierarchy` bean exists in src/main (`git grep` finds none), and no `@bean` reference exists either.
    - If either is ever added, the test's root would differ from production's. The prefix could change, and `hasRoleIsNotEquivalent` would then be the canary.
  - **Fix if wanted:** state this assumption in the class javadoc next to the bean-reference bullet.

## Positive observations
- **The root-cause finding is correct and well evidenced.** I confirmed it by bytecode on both 6.1.0 and 6.5.7. The history correction (`bd330a3a`, not `ded4d644`) is also right, and the author propagated it to `Authority`, `UserAdministrationController` and the role-matrix doc.
- **The new guard derives the root TYPE from the production bean** instead of naming a class. That is exactly the defence against this bug coming back.
- **Using two instruments is correct, and the self-tests enforce it.** `assertReportedByBothInstruments` requires one AST report and one evaluation report, so losing either instrument turns a self-test red.
- **The non-vacuity guards are good:**
  - `loaded > 400`
  - empty `unloadable`
  - the named `PutawayConfigService` positive control
  - an exact `hasSize(5)` on the good fixtures
  - the four-member family check, and the composed and class-level checks
- **`hasRoleIsNotEquivalent` inverts the old test's false claim** and says why. This is the right way to retire a wrong assertion: it keeps the knowledge and flips the polarity.
- **`MethodSecurityEnablementContractTest` now pins `getClass() == DefaultMethodSecurityExpressionHandler.class`,** with a message that names the trap. A future custom subclass gets stopped with an explanation.
- **The `getExp*` and `hasDetail` removal is justified in the javadoc:** an annotation value must be a compile-time constant, so a runtime helper could never have served `@PreAuthorize`.

## Recommendation
**COMMENT**, which here means approve once the Medium items are addressed, or explicitly accepted by Nam.
- No CRITICAL or HIGH findings at HIGH confidence.
- The production change (handler swap plus deletions) is behaviour-neutral, as claimed. I confirmed that by bytecode.
- The guard does what the ticket asked today.
- M1 and M2 are both latent false positives in the guard, plus one missed-check path (M2b). They will bite the first correct `returnObject.x`, `filterObject.x`, `#dto.x` or selection-with-arguments expression, so fix them before the rail becomes something people learn to work around.
- Per the standing "fix Lows too" directive, L1–L7 are cheap and sit in the same 30 lines.

---

## Re-review (2026-10-14, after the author's fix round)

Read-only again, and again no Maven. I read the rewritten `MethodSecurityExpressionsResolveArchTest.java` in full (875 lines), plus the changed comment in `MethodSecurityEnablementContractTest.java:181-185` and the new note in the SBDEV-3017-B1 plan.

I re-ran my scratchpad probe (spring-expression 6.2.15) to get the SpEL message code each failure shape produces:

| Expression on a root object | Result |
|---|---|
| `typo` (missing property on the root) | `PROPERTY_OR_FIELD_NOT_READABLE` |
| `typo()` (missing method on the root) | `METHOD_NOT_FOUND` |
| `details.typo` (`details` is null) | `PROPERTY_OR_FIELD_NOT_READABLE_ON_NULL` |
| `details.typo()` (`details` is null) | `METHOD_CALL_ON_NULL_OBJECT_NOT_ALLOWED` |
| `claims['nope'].length()` (key absent) | `METHOD_CALL_ON_NULL_OBJECT_NOT_ALLOWED` |
| `claims[sub]` on a `Map` | `x`, because the bare key is treated as the literal `"sub"` |

The author's surefire evidence (22 + 18 tests green, 8 mutants killed) is their own; I did not re-run it.

### Status of the original 13 findings

| # | Status | Evidence |
|---|---|---|
| M1 | **FIXED** (but see N1) | `READ_THROUGH_NULL = Set.of(PROPERTY_OR_FIELD_NOT_READABLE_ON_NULL, METHOD_CALL_ON_NULL_OBJECT_NOT_ALLOWED, CANNOT_INDEX_INTO_NULL_VALUE)` (`:137-140`) leads to `continue; // read through a null placeholder: inconclusive` (`:505-506`). New good fixtures: `#dto.length()`, `returnObject.length()`, `filterObject.length()` (`:833-849`). The blind-spot javadoc was rewritten (`:106-109`). **A root typo cannot hide behind this.** On a non-null root it raises `PROPERTY_OR_FIELD_NOT_READABLE` or `METHOD_NOT_FOUND`, which the probe confirms; neither code is in the set, and the AST walk also reports it. |
| M2a | **FIXED** | The walk now tracks `scopeIsRoot` separately. `else if (node instanceof Selection \|\| node instanceof Projection) { childOnRoot = false; childScopeIsRoot = false; }` (`:592-594`), and argument/key children take `childOnRoot = scopeIsRoot;` (`:590-591`). Good fixture: `authorities.?[authority.startsWith(authority)]` (`:859`). |
| M2b | **PARTIAL** (see N2) | Indexer keys are now checked (`node instanceof MethodReference \|\| node instanceof Indexer`), with fixture `indexerKey` (`:760`). My suggested exclusion for a bare-identifier key was **not** applied, so the `map[bareKey]` idiom now gives a false violation. |
| M2c | **FIXED** | There is now one self-test per scope rule: `headOfCompoundIsChecked`, `argumentIsChecked`, `indexerKeyIsChecked`, `rootVariableIsChecked` (`:305-329`). The `isX` and `InlineMap` rules are pinned through `GoodFixtures` (`booleanIsProperty`, `inlineMapAndRootVariable`), and `correctExpressionsPass` asserts `hasSize(14)`. |
| M3 | **FIXED** | `catch (Throwable t) { unreflectable.add(clazz.getName() + ...) }` (`:700-701`) and `assertThat(scan.unreflectable)...isEmpty()` (`:200-203`). `getDeclaredMethods()` still sits in the same `try` as `getMethods()`, but because the failure is now recorded the test fails loudly, which is enough. |
| M4 | **FIXED** | `SBDEV-3017-B1-mvc-write-surface-gating.md:3196` reads: "⚠ **Superseded 2026-10-14 by SBDEV-2872. Option (iii) as written would not work.**" |
| L1 | **FIXED** | `else if (node instanceof InlineMap && i % 2 == 0) { continue; // a key is a name, not a read }` (`:595-596`). As a side effect, a computed key such as `{(typo()): 1}` is not checked either. That is negligible. |
| L2 | **FIXED** | `headIsRoot = head instanceof VariableReference && ("#root".equals(...) \|\| ("#this".equals(...) && scopeIsRoot))`, then `childOnRoot = i == 0 ? onRoot : (i == 1 && headIsRoot)` (`:587-589`). Self-test: `rootVariableTypo`. |
| L3 | **FIXED** | `isReadable` checks `"get" + cap`, then `bool && "is" + cap`, then `n.equals(name)` (record-style), then public fields (`:605-617`). This matches `ReflectivePropertyAccessor` for every name shape in use. Remaining gap: SpEL also accepts `getxVal` when the property's second character is uppercase; isReadable does not try that form. Negligible. |
| L4 | **FIXED** | Unknown `#variable` names are reported against `DefaultSecurityParameterNameDiscoverer`, `p<i>`/`a<i>`, `root` and `this` (`:545-553`, `:574-580`). Self-test: `unknownVariableIsReported`. It depends on `-parameters` being present in the compiled classes. `GoodFixtures.argReference` passing shows the names are available in the test build, and the Boot parent sets the flag for main too. |
| L5 | **FIXED** | Conflicts are detected with `MergedAnnotations.from(m, SearchStrategy.TYPE_HIERARCHY).stream(kind)...distinct()` (`:461-469`), which matches Spring Security's unique-annotation semantics. Deduplication is pinned by `inheritedMethodIsCheckedOnce` (`:345-350`). |
| L6 | **FIXED** | The contract test comment now reads: "MethodSecurityExpressionsResolveArchTest catches a change to "wms_user" (it grants a plain user) but not one to another elevated authority such as "wms_admin"". That is accurate. |
| L7 | **FIXED** | The class javadoc (`:91-94`) now says "method arguments and indexer keys are evaluated against the SCOPE ROOT ... inline-map keys are names, not reads", which matches the code. |
| L8 | **Still clear** | I re-checked against the new fixtures (`ConflictApi`/`ConflictImpl`, `InheritedBase`/`SubA`/`SubB`, all carrying `@PreAuthorize`). Every sibling rail cited earlier either uses `DO_NOT_INCLUDE_TESTS`, iterates `productionGuardedSet()`, or doesn't look at `@PreAuthorize`. The new static field `productionHandler` is not an ArchUnit domain type, and it is nulled in `@AfterAll` anyway (`:156`). No new `@DisplayName` carries a count of 2 or more; the "13" appears only in an `.as(...)` message. |
| L9 | **Unchanged / clear** | No new stale references. |

### New issues introduced by the rewrite

**N1. "Inconclusive" swallows null reads that do not come from a placeholder.**
- **Severity:** MEDIUM. **Confidence:** HIGH (codes probed).
- **Where:** `:504-507`
  ```java
  if (READ_THROUGH_NULL.contains(e.getMessageCode())) {
      continue; // read through a null placeholder: inconclusive
  ```
- **Problem:** the comment assumes every such exception comes from a placeholder (null argument, `returnObject` or `filterObject`), but the code never checks where the null came from. Two cases show it:
  - `authentication.details.typo`: `details` is null on the test's `JwtAuthenticationToken`, but in production `BearerTokenAuthenticationFilter` sets it, so it is non-null there. The test gives `PROPERTY_OR_FIELD_NOT_READABLE_ON_NULL` and therefore inconclusive. Production gives `PROPERTY_OR_FIELD_NOT_READABLE`, which is **HTTP 500 to every caller**.
  - `principal.claims['client_id'].length()`, when the claim is absent from the test JWT. The probe shows this case gives `METHOD_CALL_ON_NULL_OBJECT_NOT_ALLOWED`.
  - In both cases the AST walk cannot help, because these are reads off the root.
  - The first round reported both (by accident). They now pass silently.
- **Related:** if both principals come back inconclusive, the expression is never evaluated at all, and nothing records that.
- **Fix:**
  - Treat a null read as inconclusive only when the AST references a placeholder: a `VariableReference` naming a parameter (or `p<i>`/`a<i>`), `returnObject`, or `filterObject`. Otherwise report it as a violation.
  - Optionally, have the fixture JWT carry non-null `details`.
  - Record sites where every evaluation was inconclusive, and assert that the list is empty for src/main. Today that holds trivially, because all 13 sites are `hasAuthority('sb_admin')`.

**N2. The indexer-key rule falsely flags the `map[bareKey]` idiom.**
- **Severity:** LOW. **Confidence:** HIGH.
- **Where:** `:590-591`
  ```java
  } else if (node instanceof MethodReference || node instanceof Indexer) {
      childOnRoot = scopeIsRoot; // arguments and keys see the scope root
  ```
- **Problem:** SpEL treats a bare identifier inside `[...]` on a `Map` target as a literal key (probe: `claims[sub]` returns `x`). With this rule, `principal.claims[sub] != null` is reported as `'sub' is read on the root but MethodSecurityExpressionRoot has no such property`. That is a false violation on correct code. Nothing in src/main uses it today.
- **Fix:** for an `Indexer`, use `childOnRoot = scopeIsRoot && !(child instanceof PropertyOrFieldReference)`. Add `principal.claims[sub] != null` to `GoodFixtures`, ANDed with `hasAuthority('sb_admin')` so it still passes the deny rule.

**N3. The "must deny a plain wms_user" rule can give false violations, and can be skipped.**
- **Severity:** LOW. **Confidence:** MEDIUM.
- **Where:** `:527-536`
- **Does it falsely flag anything in src/main today? No.** All 13 sites are `hasAuthority('sb_admin')` and evaluate FALSE for `[wms_user]`, and the author's AC3 mutant run covers all 13.
- **Future false violations** come from the null placeholders:
  - `@PreAuthorize("#clientId == principal.claims['client']")`: both sides are null in the test, `null == null` is TRUE, so it is reported as granting a plain user. It is a correct ownership check.
  - `@PostAuthorize("returnObject == null or returnObject.owner == authentication.name")`: the null `returnObject` makes it TRUE, so it is reported. This is a correct "404 rather than 403" pattern.
- **The rule can also be skipped.** If the plain user's evaluation is inconclusive, `grantsPlainUser` stays null and no deny check runs. Example: `#dto.x == 1 or isAuthenticated()` throws on the null read before `isAuthenticated()` is reached.
- The allow-list (`GRANTS_PLAIN_USER_ON_PURPOSE`) gives an escape hatch, so this fails loudly rather than silently. Two smaller gaps:
  - For class-level sites, the allow-list key is the bare class name (`owner = clazz.getName()`), not `Class#method`. The javadoc doesn't say so.
  - The rule uses a fixed `[wms_user]` principal and cannot see a gate that grants some other ordinary authority.
- **Fix:**
  - Apply the deny check only when the expression references no placeholder, or report such sites as "deny check not applicable".
  - Document the class-level key format.

**N4. The handler bean is taken from a context that has already been closed.**
- **Severity:** LOW. **Confidence:** MEDIUM.
- **Where:** `:169-172`. The `try (AnnotationConfigApplicationContext ctx = ...)` block closes the context before `productionHandler` is used.
- **Problem:** today this is harmless. Any future `@bean` reference would go through a `BeanFactoryResolver` attached to a closed factory, and fail for that reason instead of the documented "no bean factory here".
- **Fix:** keep the context open in a static field and close it in `@AfterAll`. Alternatively, keep the current code and add a comment saying it closes the context on purpose.

**N5. The two-principal loop still stops at the first evaluation failure.**
- **Severity:** LOW (informational). **Confidence:** HIGH.
- **Where:** `:508-510`, the `return` after the first non-null-read failure.
- **Problem:** this is intended, because `assertReportedByBothInstruments` needs exactly one evaluation report. Mentioned only so the "evaluated twice" claim in the javadoc (`:95-96`) is read as "at most twice".

### Positive changes from the fix round
- **Null and non-Boolean results are now reported** (`:521-525`). This is a real improvement found by the security lane: `@PreAuthorize("#flag")` with a null flag grants in Spring Security 6, and the first round would not have caught it.
- **The handler now comes from a Spring context** (`AnnotationConfigApplicationContext(MethodSecurityConfig.class)`), which closes my first-round open question.
- **There is now a count-based check on the scan size:** `hasSizeGreaterThanOrEqualTo(13)` (`:205-208`).
- **Every scope rule has a self-test that fails when the rule is mutated,** and the author reports 8 checker mutants killed with each failure attributed.

### Re-review counts
| Severity | Original findings still open | New findings |
|---|---|---|
| CRITICAL | 0 | 0 |
| HIGH | 0 | 0 |
| MEDIUM | 0 | 1 (N1) |
| LOW | 1 (M2b, now reduced to N2) | 4 (N2–N5) |

### Re-review recommendation
**COMMENT, leaning APPROVE.**
- No CRITICAL or HIGH findings at HIGH confidence. All four original Mediums are FIXED, and 12 of the 13 original findings are FIXED or still clear. The exception is M2b, which is PARTIAL: indexer keys are checked now, but N2 remains.
- N1 is the one worth fixing before merge. The fix for M1 made the rail more lenient than it says it is: a typo behind a null that came from the principal or authentication, not from a placeholder, now passes silently. Any of the three remedies under N1 closes it.
- N2 is a one-line change. N3 and N4 are cheap. Under the "fix Lows too" directive, all of them belong in the same pass.
- Nothing in the rewrite falsely flags the 13 sites in src/main.
