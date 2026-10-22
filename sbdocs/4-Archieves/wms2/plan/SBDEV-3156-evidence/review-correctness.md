# SBDEV-3156 — adversarial correctness review (lane 1 of 3)

- **Commit under review:** `3594108a` on `chore/SBDEV-3156-method-security-enablement-pin`
- **Base:** `origin/develop` = `452d3ed4`
- **Review worktree:** `/tmp/claude-1000/review-3156-correctness` (detached at `3594108a`, my own tree — no sibling shared it)
- **Toolchain:** Java 21 via sdkman, `mvn -o`; ArchUnit **1.3.0** (`pom.xml`, `<artifactId>archunit-junit5</artifactId>`); Spring Boot **3.5.9** → spring-security **6.5.7**
- **Verdict:** the change is **correct and behaviour-preserving**. No High findings. Two Medium findings, both about the *ban rule's* reach and an enumeration gap, not about the flag flip. Several Low findings, mostly false citations in prose.

Every result below is marked **CONFIRMED** (I ran something and the output is quoted) or **REASONED** (argument only).

---

## 0. Summary table

| # | Severity | Finding | Status |
|---|---|---|---|
| F1 | **Medium** | The ban rule uses `isAnnotatedWith` (direct-only) and so **misses a meta-annotation whose annotation type lives outside `net.aim_ai.wms`** — I planted one and the build stayed GREEN | CONFIRMED |
| F2 | **Medium** | `METHOD_SECURITY_GATES` keeps three now-inert annotations "for defence in depth" but omits `@PreFilter` / `@PostFilter`, which `prePostEnabled=true` leaves **LIVE** | CONFIRMED (0 current uses) |
| F3 | Low | Three FALSE citations in the new test's class javadoc: `FunctionGuardArchTest:355-357`, `FunctionGuardArchTest:395`, and treating `FunctionGuardArchTest` as an ArchUnit test at all | CONFIRMED |
| F4 | Low | Javadoc claims `javax.annotation.security.*` is "resolvable on a Spring Boot 3 classpath". It is **not** on this classpath — a `javax.*` mutant does not compile, so 3 of the 7 `BANNED` entries are structurally unreachable | CONFIRMED |
| F5 | Low | The `DisplayName` and javadoc claim constructor coverage. `@Target` of all four annotations is `{TYPE, METHOD}` — the `getConstructors()` loop is **dead code** and advertises coverage that cannot exist | CONFIRMED |
| F6 | Low | The stated intent "written explicitly rather than omitted so a reader sees a decision" is **not pinned** — the new values are exactly Spring Security 6.5.7's defaults, so omitting all three attributes keeps the contract test green | CONFIRMED |
| F7 | Low | The commit message's "13 source files vs 4 bytecode carriers … the other 9 mentioning it only in javadoc" does not reproduce: the real numbers are **16 mentioning files** (15 on develop) vs **4 real annotation-use files** | CONFIRMED |
| F8 | Low | The ArchUnit scan reads `target/classes`, and `mvn test` does not purge deleted classes — a stale `.class` file makes the ban red against source that no longer exists | CONFIRMED (it bit my own harness) |
| F9 | Info | `hasSizeGreaterThan(400)` is **sound and better than the convention it cites** — it is the only numeric vacuity guard in the repo; every sibling uses `isNotEmpty()`, which would not catch a subpackage root | CONFIRMED |
| F10 | Info | `origin/main` still carries `securedEnabled = true, jsr250Enabled = true`. This change is develop-only; prd is unaffected until a release | CONFIRMED |

---

## 1. (a) IS THE PREMISE TRUE? — YES, three independent instruments agree

The premise is "nothing in `src/main` uses `@Secured` / `@RolesAllowed` / `@DenyAll` / `@PermitAll`". I re-derived it with a method the commit did not use.

### Instrument A — comment/string-stripped annotation-position scan (CONFIRMED, mine)

I exported `src/main` from the git object store (`git archive 3594108a src/main`) so the mutating worktree could not contaminate it, then ran a Python pass that **removes `//` comments, `/* */` blocks, string literals, text blocks and char literals** before searching for `@`-position matches, accepting both simple and fully-qualified spellings (`@\s*([A-Za-z_$][\w$.]*)`, comparing the last dot-segment).

```
java files scanned: 565
  Secured                 0
  RolesAllowed            0
  DenyAll                 0
  PermitAll               0
  RunAs                   0
  DeclareRoles            0
  PostAuthorize           0
  PreFilter               0
  PostFilter              0
  PreAuthorize           13   (4 distinct files)
  RequiresFunction      131
```
Plus: **zero** `import` statements matching `annotation.security` or `access.annotation` anywhere in `src/main`.

This instrument is strictly stronger than a grep for the premise: it cannot be fooled by a javadoc mention (which is why the `@PreAuthorize` count differs from the commit's — see F7), and it catches a fully-qualified use. **Blind spots:** it is regex-over-stripped-text, not a real parser, so a `@` split across a line by a comment in the middle of an annotation name would evade it; and it says nothing about annotations that arrive by inheritance or meta-annotation.

### Instrument B — the rule's own bytecode scan, on a pristine tree (CONFIRMED)

```
### R1 BASELINE (pristine) => GREEN
```
and ArchUnit's own import size matched the filesystem exactly: `PROBE size(net.aim_ai.wms, DO_NOT_INCLUDE_TESTS) = 650` against `find target/classes -name "*.class" | wc -l` = **650**. So the scan really covers the whole compiled main tree, including **85 nested classes, 136 interfaces, 11 enums, 4 annotation types, 30 records** (measured by a throwaway probe, since deleted).

### Instrument C — 304-jar classpath descriptor scan (CONFIRMED, mine, independent of the commit's)

I resolved the classpath with `mvn dependency:build-classpath` and scanned **every `.class` entry in all 304 jars** for the seven annotation descriptors:

```
jars on the resolved classpath: 304
Secured: 2   -> spring-security-core-6.5.7.jar
                 .../SecuredAnnotationSecurityMetadataSource$SecuredAnnotationMetadataExtractor.class
                 .../authorization/method/SecuredAuthorizationManager.class
jakarta.RolesAllowed: 3 -> resteasy-core-6.2.9.Final.jar
                            org/jboss/resteasy/plugins/interceptors/RoleBasedSecurityFeature.class
                          spring-security-core-6.5.7.jar
                            .../access/annotation/Jsr250MethodSecurityMetadataSource.class
                            .../authorization/method/Jsr250AuthorizationManager$Jsr250AuthorizationManagerRegistry.class
DenyAll / PermitAll / all javax.* : 0 candidates in any jar
```

This **independently reproduces the commit's third-party claim exactly** — 304 jars, four spring-security processor classes, plus resteasy's `RoleBasedSecurityFeature`. It also closes the "inherited from a library superclass" escape the brief asked about: **no class in any of the 304 jars carries one of these annotations**, so no `src/main` class can inherit one. (Note `@Secured` *is* `@Inherited` — `javap -v` on `spring-security-core-6.5.7.jar` shows `java.lang.annotation.Inherited` on it — so that escape would have been real had a carrier existed.)
**Blind spots of instrument C:** descriptor-string presence in the constant pool is a *superset* of actual carriers (it also matches classes that merely reference the type), so 0 is trustworthy but a nonzero would need `javap -v` follow-up; and it covers the jars `dependency:build-classpath` resolves, not JDK modules.

### Things the brief asked about, individually closed

- **`src/main/resources`:** contains no `.class`, `.jar`, `.kt`, `.groovy` or `.aj` files, and `grep -rlE "RolesAllowed|DenyAll|PermitAll|Secured" src/main/resources/` returns nothing. CONFIRMED.
- **Kotlin / Lombok-generated members:** `grep -c lombok pom.xml` = **0**; no Kotlin/Groovy sources exist. There is no annotation processor that could emit these. CONFIRMED.
- **`landlord/` subpackage:** covered by the whole-tree root, and I proved it by planting there — see R4b below. CONFIRMED.
- **JAX-RS resources that resteasy's `RoleBasedSecurityFeature` would read:** `src/main` uses `jakarta.ws.rs` only as *client/exception* types (`KeycloakService` imports `ProcessingException`/`WebApplicationException`/`core.Response`; `SsoException extends WebApplicationException`). The only `@Path` in `src/main` is **commented out** (`AdviceRestController`, `//@Path("/reopen")`). So there is no JAX-RS resource class for that feature to gate. CONFIRMED — this is a *stronger* statement than the commit's "is not a Spring bean".

**Premise verdict: TRUE.** No real use of the four annotations exists in `src/main`. The change is not wrong.

---

## 2. (b) DOES THE BAN RULE CATCH WHAT IT CLAIMS? — mostly yes; one confirmed escape

All results from `mvn -o -B test -Dtest=MethodSecurityAnnotationSurfaceArchTest` in my own worktree. **Harness note:** my first attempt was invalid because `mvn test` (no `clean`) does not delete a `.class` file whose source I had removed, so a stale `ProbeGateInTree.class` reported itself as a violation on a pristine tree. I rewrote the harness to purge `target/classes/probe` and `find target/classes -iname "*ProbeGate*" -delete` between mutants. That is F8, and it is the same trap as the repo's recorded "`mvn test` runs DELETED test classes".

### CAUGHT — five shapes, all in one run, each named precisely (CONFIRMED)

```
### R4b => RED
"net.aim_ai.wms.util.OptimisticLockRetry$OptimisticLockRetryException (class level) carries @DenyAll"
"net.aim_ai.wms.repo.projection.OrderReleaseInfoView#getCoId carries @RolesAllowed"
"net.aim_ai.wms.util.PickPathDirection#probeIsHorizontal carries @DenyAll"
"net.aim_ai.wms.landlord.controller.TenantDiscoveryController#probeHelper carries @Secured"
"net.aim_ai.wms.landlord.controller.TenantDiscoveryController#probeProtected carries @PermitAll"
```
That covers, in one shot: **nested static class at class level**, **interface method**, **enum method**, **`private static` method inside `landlord/`** (the whole-tree-root claim), and **`protected final` method**. Every message names the exact site. The brief's candidate escapes "nested/inner class", "enum or interface method", and "a fully-qualified annotation" are all **closed**.

### CAUGHT — meta-annotation whose annotation type is *inside* the scan root (CONFIRMED)

```
### R3 META-ANNOTATION, annotation type INSIDE net.aim_ai.wms => RED
"net.aim_ai.wms.util.ProbeGateInTree (class level) carries @DenyAll"
```
It is caught, but note *where*: at the **annotation type's own declaration**, not at the use sites. A composed `@AdminOnly` applied to 40 methods produces exactly one violation line naming the annotation. Acceptable — the build still fails.

### **ESCAPED — F1: meta-annotation whose annotation type lives outside `net.aim_ai.wms`** (CONFIRMED)

I added `src/main/java/probe/ProbeGateOutOfTree.java`:

```java
package probe;
@DenyAll
@Retention(RetentionPolicy.RUNTIME)
@Target({ElementType.METHOD, ElementType.TYPE})
public @interface ProbeGateOutOfTree {}
```
and applied `@ProbeGateOutOfTree` to `TenantDiscoveryController#getAuthConfig`. Result:

```
### R2 META-ANNOTATION, annotation type OUTSIDE net.aim_ai.wms (package 'probe') => GREEN
```

**Does it MATTER given the flags are off?** Yes — for the exact reason the rule exists. The rule's own javadoc says its purpose is that *"a future `@RolesAllowed("sb_admin")` written in good faith would be INERT while looking exactly like a gate"*. A composed annotation is the **most** gate-looking spelling of all, and Spring Security honours meta-annotations here — `Jsr250AuthorizationManager` resolves via merged-annotation search, and the repo's own `Sbdev3017TrancheGateContextTest` uses `AnnotatedElementUtils.findMergedAnnotation(...)` thirty lines from the list it edits in this very diff. So the diff contains the correct instrument and the ban rule uses the weaker one.

**How much does it matter in practice?** Less than the mechanism suggests: today there is no `src/main` package outside `net.aim_ai.wms` (`find src/main/java -name "*.java" ! -path "src/main/java/net/aim_ai/wms/*"` → empty, CONFIRMED), so an escaping composed annotation would have to be added in a new root package or come from a jar — and instrument C showed no jar carries one. That is why this is **Medium, not High**.

**Fix (one line, no new files):** in `noDeArmedMethodSecurityAnnotationsInMain`, change both loops from
`isAnnotatedWith(banned)` to `isAnnotatedWith(banned) || isMetaAnnotatedWith(banned)`, and add the meta case to the "What this does NOT cover" paragraph either way. `isMetaAnnotatedWith` is transitive and is a sibling method on the same `CanBeAnnotated` interface — no API risk.

### Shapes that are NOT gaps because javac rejects them (CONFIRMED)

`javap -v` on `jakarta.annotation-api-2.1.1.jar` and `spring-security-core-6.5.7.jar`:

- `jakarta.annotation.security.RolesAllowed` → `Target(value=[TYPE, METHOD])`
- `jakarta.annotation.security.DenyAll` → `Target(value=[TYPE, METHOD])`
- `jakarta.annotation.security.PermitAll` → `Target(value=[TYPE, METHOD])`
- `org.springframework.security.access.annotation.Secured` → `Target(value=[METHOD, TYPE])`, plus `Inherited`

So the brief's candidates **field**, **record component**, **parameter** and **constructor** cannot be written at all. Not gaps — but see F5: the test *claims* constructor coverage.

---

## 3. (c) ArchUnit 1.3.0 semantics — the assumptions, checked against the jar

`javap -classpath archunit-1.3.0.jar com.tngtech.archunit.core.domain.JavaClass` (CONFIRMED):

```
public boolean isAnnotatedWith(java.lang.String);
public boolean isMetaAnnotatedWith(java.lang.String);
public java.util.Set<JavaMethod> getMethods();
public java.util.Set<JavaMethod> getAllMethods();
public java.util.Set<JavaConstructor> getConstructors();
public java.util.Optional<JavaStaticInitializer> getStaticInitializer();
```

- **`isAnnotatedWith(String)` is DIRECTLY-present only.** The existence of a separate `isMetaAnnotatedWith` on the same `CanBeAnnotated` interface settles it, and R2 vs R3 confirms it behaviourally. → F1.
- **`getMethods()` is declared-only** (`getAllMethods()` is the inherited-inclusive variant). This is *not* a real gap here: an inherited annotated method must be declared on some supertype, and every `src/main` supertype is itself scanned (there is no `src/main` class outside `net.aim_ai.wms`), and no library type carries one (instrument C). So the root is always caught — with a caveat: the violation names the **superclass**, not the 43 subclasses that inherit it. Given `AdminController` is a base class for 43 controllers, that is the right message anyway.
- **Constructors** are iterated but unreachable (F5). **Static initializers** are not iterated and cannot carry these annotations.
- **The repo's recorded "ArchUnit call-site rules have 5 blind spots: ctors, static init, `x::ref`, subtypes, field"** — those are about *call-site* (`accessesTarget`) rules. This is an *annotation-presence* rule, so `x::ref` and call-sites are irrelevant; `field`, `ctor` and `static init` are excluded by `@Target`; **`subtypes` is the one that transfers**, and it is closed empirically as above. CONFIRMED.

---

## 4. (d) Is `hasSizeGreaterThan(400)` a sound vacuity guard? — YES, and it is the strongest one in the repo

Measured class counts under `target/classes` (CONFIRMED):

```
total under net/aim_ai/wms : 650      (ArchUnit import size: 650 — exact match)
largest subpackage         : service 184
next                       : repo 123, model 76, json 68, controller 68, landlord 34
with tests included        : 2531     (so DO_NOT_INCLUDE_TESTS really is load-bearing)
```

- **Not too loose.** No single subpackage reaches 400; even `service + repo + model` = 383 < 400. A root that half-resolves cannot pass. **CONFIRMED behaviourally:** narrowing the root to `net.aim_ai.wms.service` (184) turns the test RED (see M3 in §5).
- **Not too tight.** 650 vs 400 is 38 % headroom. A legitimate refactor would have to delete a third of the main tree to trip it, and the failure message says exactly what to do.
- **It catches a half-broken scan that `isNotEmpty()` would not.** This is the only `hasSizeGreaterThan` in the repo — `PublicHandlerContractArchTest` and the other seven `ClassFileImporter` users all use `isNotEmpty()` (CONFIRMED by grepping all nine files). So the javadoc's "Same placement as … `PublicHandlerContractArchTest`" is true about *placement* and understates the *form*: this guard is stronger than the convention it cites. Keep it. (Minor caveat: it will need a bump if the tree ever shrinks a lot, and the message does not say the current count — adding "currently 650" to the `.as(...)` would make the next maintainer's decision trivial.)

---

## 5. (e) Is turning the flags off behaviour-preserving? — YES. Confirmed from Spring Security 6.5.7 source

I unpacked `spring-security-config-6.5.7-sources.jar` and read the actual wiring (CONFIRMED, quoted):

**`MethodSecuritySelector.selectImports`** — the flags do exactly one thing each:
```java
if (annotation.prePostEnabled()) imports.add(PrePostMethodSecurityConfiguration.class.getName());
if (annotation.securedEnabled()) imports.add(SecuredMethodSecurityConfiguration.class.getName());
if (annotation.jsr250Enabled())  imports.add(Jsr250MethodSecurityConfiguration.class.getName());
imports.add(AuthorizationProxyConfiguration.class.getName());
```
`AutoProxyRegistrar`, `MethodSecurityAdvisorRegistrar`, `AuthorizationProxyConfiguration`, and the web/observability configs are added **unconditionally**. So `false` omits two `@Configuration` classes and nothing else.

**Nothing breaks from the two beans being absent.** `MethodSecurityAdvisorRegistrar.registerAsAdvisor` explicitly tolerates it:
```java
String interceptorName = prefix + "MethodInterceptor";
if (!registry.containsBeanDefinition(interceptorName)) {
    return;
}
```
So `securedAuthorizationAdvisor` / `jsr250AuthorizationAdvisor` are simply not registered. No missing-bean failure, no `NoSuchBeanDefinitionException`.

**No interaction with `CustomMethodSecurityExpressionHandler`.** Only `PrePostMethodSecurityConfiguration` consumes it:
```java
@Autowired(required = false)
void setExpressionHandler(MethodSecurityExpressionHandler expressionHandler) { ... }
```
`SecuredMethodSecurityConfiguration` and `Jsr250MethodSecurityConfiguration` have no expression-handler setter at all — they wire `SecuredAuthorizationManager` / `Jsr250AuthorizationManager`, which are role-list matchers, not SpEL. So the `@Bean` in the same class is untouched. CONFIRMED by reading all three classes.

**No bean-ordering change.** Each config applies `annotation.offset()` to *its own* interceptor (`this.methodInterceptor.setOrder(this.methodInterceptor.getOrder() + annotation.offset())`). Removing two interceptors does not shift the order value of the four prePost ones.

**Nothing in the app depends on those advisors existing.** `grep -rn "Jsr250|SecuredAuthorizationManager|AuthorizationManagerBeforeMethodInterceptor|GrantedAuthorityDefaults" src/main src/test` returns **zero** hits outside the two SBDEV-3156 test files' prose. `SdrFunctionRules`, `FunctionGuardInterceptor` and `SecurityConfiguration` do not reference them. CONFIRMED.

**The clincher:** `EnableMethodSecurity` in 6.5.7 declares
```java
boolean prePostEnabled() default true;
boolean securedEnabled() default false;
boolean jsr250Enabled() default false;
```
The new values **are the framework defaults**. The app is moving *onto* the default configuration, not off it. That is about as low-risk as a security-config change gets.

---

## 6. (f) Everything else

### F2 — Medium: the enumeration keeps three DEAD annotations and omits two LIVE ones

`Sbdev3017TrancheGateContextTest` (the file this diff edits):
```java
private static final List<Class<? extends Annotation>> METHOD_SECURITY_GATES = List.of(
        PreAuthorize.class, PostAuthorize.class, Secured.class, RolesAllowed.class, DenyAll.class);
```
and its javadoc: *"Every method-security annotation that can deny the OMS principal."*

`prePostEnabled = true` arms **four** annotations, not two — `PrePostMethodSecurityConfiguration` constructs `preFilterMethodInterceptor`, `preAuthorizeMethodInterceptor`, `postAuthorizeMethodInterceptor` **and** `postFilterMethodInterceptor` (CONFIRMED, quoted from the 6.5.7 source). `@PreFilter` and `@PostFilter` are **live today** and are absent from the list.

The diff's new rationale is *"the three extra entries are therefore defence in depth, not current enforcement … they mean that re-enabling a family does not silently reopen the hole."* That argument applies **far more strongly** to `@PostFilter`, which needs no flag flip at all: a `@PostFilter` on an `§0.C` carve-out route would silently empty the OMS response and the carve-out assertion would not see it. So the list is now defended in the inert direction and undefended in the live one.

Current exposure is nil — my instrument A puts `@PreFilter` and `@PostFilter` at **0** uses in `src/main` (CONFIRMED). This is a coverage/consistency finding, not a live bug.

**Fix:** add `PreFilter.class, PostFilter.class` to `METHOD_SECURITY_GATES` (making it seven) and adjust the javadoc's "five long" prose and the failure message's annotation list. Cheap, and it makes the list actually match "every annotation that can deny".

### F3 — Low: three false citations, in a paragraph that is itself about citation drift

`MethodSecurityAnnotationSurfaceArchTest` class javadoc:

> *"a source-text grep misses a fully-qualified annotation (`{@code FunctionGuardArchTest:355-357}` records the escape)"*

`FunctionGuardArchTest` lines 350–362 are about mobile replenishment gate paths (`"That class is gated CLASS-level with MOBILE_UI_VIEW_REPLENISHMENT (:38)"`). The fully-qualified-annotation escape is actually recorded at **`FunctionGuardArchTest:469`**: `"Resolved by REFLECTION, never by a source-text grep: a fully-qualified"`. CONFIRMED by `git grep -n -i "fully-qualified" 3594108a -- src/test`.

> *"Same placement as `{@code FunctionGuardArchTest:395}`"*

Line 388–400 there is a data-list entry, `"StockUnitController#bulkTransferStock"`. The vacuity guard is at **`FunctionGuardArchTest:481`**: `assertThat(scanned).as("an empty scan makes the assertion below vacuous").isNotEmpty();`. CONFIRMED.

> *"Every ArchUnit test in this repo sets it [`DO_NOT_INCLUDE_TESTS`]."*

`FunctionGuardArchTest` is **not an ArchUnit test** — 1030 lines, `extends BaseUnitTest`, and `git show 3594108a:… | grep -c tngtech` = **0**. It is a reflection test with a misleading name (pre-existing). The completeness claim is defensible for the nine files that actually use `ClassFileImporter` (all nine set the option at least once — CONFIRMED by per-file grep counts), but the diff cites `FunctionGuardArchTest` as an ArchUnit exemplar twice, so a reader will draw the wrong conclusion.

This is Low because nothing executes on it, but it is worth fixing given the repo's own citation-form rule (file + distinctive quoted snippet, not line numbers) — and the diff's other half literally says *"the ordinary fate of a line-number citation"* while introducing two more.

Related, smaller: the diff asserts that `"MethodSecurityEnablementContractTest:64-67"` was a range that *"had also drifted"*. On `452d3ed4` the `prePostEnabled` assertion block sits at lines **65–68** — off by one at most. Calling that "drifted" overstates it. CONFIRMED by `git show 452d3ed4:… | sed -n '52,72p'`.

### F4 — Low: the `javax.*` rationale is factually wrong on this classpath

```java
 * <p>Deliberately NOT {@code Class} literals: {@code jakarta.annotation.security.*} and its
 * {@code javax.*} predecessor are different types with identical simple names, both resolvable on a
 * Spring Boot 3 classpath, ...
```
`javax.annotation.security` is **not** on this classpath. My mutant `@javax.annotation.security.RolesAllowed("sb_admin")` failed to compile:
```
[ERROR] .../TenantDiscoveryController.java:[24,31] package javax.annotation.security does not exist
```
and the resolved classpath contains only `jakarta.annotation-api-2.1.1.jar` (CONFIRMED). So three of the seven `BANNED` entries can never fire, and cannot be mutation-tested.

The **string-not-`Class`-literal decision is still right** (it is what lets the rule name types it cannot import), and keeping the `javax` entries as cheap future-proofing is fine. Only the stated reason needs correcting — e.g. "the `javax.*` predecessor is not on this classpath today; the entries are kept in case a transitive dependency reintroduces it, and cost nothing."

### F5 — Low: advertised constructor coverage cannot exist

```java
@DisplayName("no src/main class, method or constructor carries @Secured, @RolesAllowed, @DenyAll or @PermitAll")
```
and *"It sees annotations on classes, methods and constructors under `net.aim_ai.wms`"*.

All four annotations are `@Target({TYPE, METHOD})` (CONFIRMED by `javap -v`), so the `type.getConstructors().forEach(...)` block is unreachable. Harmless, but it inflates the perceived surface and the "What this does NOT cover" paragraph would be more honest listing **meta-annotations** (F1) than listing constructors as covered.

### F6 — Low: the "explicit, not omitted" intent is unpinned

`MethodSecurityConfig`'s comment: *"Written explicitly, not omitted, for two reasons: a reader of this file sees a DECISION rather than an absence, and the intent survives a Spring Security major version changing its defaults."* The second reason is real. But the new values equal 6.5.7's defaults, so a future maintainer who deletes the attributes to "clean up" keeps the contract test green. If the explicit spelling matters, the pin has to read the annotation's *declared* attributes (e.g. via `MethodSecurityConfig.class.getDeclaredAnnotation(...)` plus `AnnotationUtils.getAnnotationAttributes(..., false, false)` and check `defaultValue` membership) — or, more cheaply, accept that only the value is pinned and say so in the comment. I would take the cheap option; over-pinning the spelling buys little.

### F7 — Low: the `@PreAuthorize` 13/9/4 arithmetic does not reproduce

Commit message and test comment: *"The `@PreAuthorize` divergence (13 source files vs 4 bytecode carriers) is the other 9 mentioning it only in javadoc, checked individually."*

Measured (CONFIRMED):
```
git grep -l PreAuthorize 452d3ed4 -- 'src/main/**/*.java'  -> 15 files
git grep -l PreAuthorize 3594108a -- 'src/main/**/*.java'  -> 16 files
real @PreAuthorize annotation uses (instrument A)          ->  4 files, 13 use-sites
    AdminActionController, AdminController,
    ReplenishmentReconciliationController, PutawayConfigService
```
The "13" is the count of **use-sites**, not files; the file count is 15/16, so the mention-only remainder is 11/12, not 9. The conclusion (4 bytecode carriers = 4 source files with real uses) is **exactly right** — only the narrative arithmetic is wrong. Worth fixing because the sentence is offered as evidence that the zeros are trustworthy.

### F8 — Low: the rule grades `target/classes`, and `mvn test` does not purge deletions

My own harness produced a false RED on a pristine tree because a `ProbeGateInTree.class` from a killed earlier run survived source deletion:
```
### BASELINE => RED
"net.aim_ai.wms.util.ProbeGateInTree (class level) carries @DenyAll"
```
with `git status --porcelain src/main/` clean. CONFIRMED. Direction of failure is fail-*loud* (a red naming a class that no longer exists), which is the safe direction, and CI presumably runs `clean`. Worth one sentence in the javadoc next to the `DO_NOT_INCLUDE_TESTS` warning, since a maintainer who hits this will suspect the rule rather than `target/`.

### F10 — Info: develop-only

`git show origin/main:src/main/java/net/aim_ai/wms/MethodSecurityConfig.java` still reads
`@EnableMethodSecurity(prePostEnabled = true, securedEnabled = true, jsr250Enabled = true)`, and `origin/develop` is 22 commits ahead of `origin/main`. CONFIRMED. Nothing to fix — just do not describe the narrowing as live on prd.

### Things I checked and found FINE

- The three files' mutual cross-references (`MethodSecurityConfig` ↔ `MethodSecurityEnablementContractTest` ↔ `MethodSecurityAnnotationSurfaceArchTest`) all name real, existing symbols. CONFIRMED.
- The `PublicHandlerContractArchTest` citation is **accurate** — its javadoc really does record the landlord escape: `"over \"the controller tree\" is the wrong scan: TenantDiscoveryController lives in net/aim_ai/wms/landlord/controller/, so a marker there would escape every rail in silence"`. CONFIRMED.
- "650 compiled class files" and "304 dependency jars" both reproduce exactly. CONFIRMED.
- `MethodSecurityConfig` uses `/* */`, not `/** */`. That is correct, not sloppy: the block contains bare `@PreAuthorize`, `@DenyAll` etc., which javadoc would try to parse as block tags.
- The two new pins are separate `@Test`s with their own `assertThat(enabled).isNotNull()` — the stated reason (a null-annotation run still reports the others) holds.
- Comment placement: the `MethodSecurityConfig` block sits above `@Configuration`, which is where a reader looks. Fine.

---

## 7. Mutation results (all CONFIRMED by running)

| Mutant | Applied to | Expected | Result |
|---|---|---|---|
| B1 baseline | pristine `3594108a` | GREEN | **GREEN** — `MethodSecurityAnnotationSurfaceArchTest` 2/2, `MethodSecurityEnablementContractTest` 18/18 |
| R2 | `@DenyAll`-meta-annotated `@interface` in package `probe`, applied to a `src/main` method | RED | **GREEN — ESCAPE (F1)** |
| R3 | same, `@interface` inside `net.aim_ai.wms` | RED | **RED**, names `ProbeGateInTree` |
| R4b | 5 shapes at once (nested class · interface method · enum method · private-static in `landlord/` · protected-final) | RED ×5 | **RED**, all five named individually |
| M4 | `securedEnabled = true` | RED | **RED** — `securedEnabledStaysOff` |
| M5 | `jsr250Enabled = true` | RED | **RED** — `jsr250EnabledStaysOff` |
| M6 | `prePostEnabled = false` | RED | **RED** — `methodSecurityIsEnabledWithPrePostProcessing` |
| M7 | all three attributes omitted (`@EnableMethodSecurity`) | (defaults match) | **GREEN — F6** |
| M3 | scan root → `net.aim_ai.wms.service` (184 classes) | RED via vacuity guard | **RED** — killed by `scanIsNotVacuous:97`, i.e. the guard, not the ban |
| M3b | root → `.service` **and** guard loosened to `>100` | GREEN (guard defeated) | **GREEN** — confirms the 400 threshold, not the guard's mere presence, is what bites |
| — | `@javax.annotation.security.RolesAllowed` on a `src/main` method | RED | **does not compile** (F4) |

Every mutant was reverted; final `git status --porcelain src/` in the review worktree is clean, and my throwaway probe test (`net/aim_ai/wms/zzprobe/`) plus its compiled classes are deleted. (`git checkout --` silently no-ops on untracked files, so the probe directory and `target/classes/probe` were removed with `rm -rf` explicitly.)

---

## 8. What I did NOT check

- **The full 5900-test suite.** I ran only `MethodSecurityAnnotationSurfaceArchTest` and `MethodSecurityEnablementContractTest` (20 tests) plus a full `test-compile`. `Sbdev3017TrancheGateContextTest` — the third file the diff touches — I did **not** execute; its changes are javadoc/comment-only, so compilation is the whole risk surface and `test-compile` passed. Someone must still run the full suite against the known baseline.
- **Any Spring context boot.** I never started the application or a `@SpringBootTest`, so I did not observe the advisor chain at runtime; the §5 conclusion is from reading 6.5.7 source plus grepping for dependents, not from an actual context.
- **Runtime behaviour of the `/rest/**` SDR surface** and `SecurityConfiguration.authorizeHttpRequests` — unchanged by this diff and unobservable in a unit lane.
- **PIT mutation testing.** My mutants are hand-planted; per the repo's own guidance a hand-rolled harness can lie, and mine did once (F8) before I fixed it.
- **AOT / native-image hints.** `AuthorizationProxyConfiguration` and the AOT hint registrars are imported unconditionally, so I judged this out of scope; not verified.
- **Whether the four real `@PreAuthorize` expressions are correct.** Explicitly out of scope for this diff, and the test says so.
- **`main`-branch impact beyond confirming the flags differ there.**
