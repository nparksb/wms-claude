# SBDEV-2872 — Independent Security Review

**Scope:** `git diff origin/develop` in worktree `.claude/worktrees/wms2-api/SBDEV-2872` (HEAD = origin/develop `64fbbb07`, all changes uncommitted):
`MethodSecurityConfig.java` (handler swap), `Authority.java` (getExp* helpers + javadoc), `PutawayConfigService.java` (javadoc), deleted `CustomMethodSecurityExpressionHandler/Root` + `CustomMethodSecurityExpressionRootUnitTest`, modified `MethodSecurityEnablementContractTest`, untracked `MethodSecurityExpressionsResolveArchTest`.
**Risk Level:** LOW (production change is authorization-neutral; findings are guard-test gaps, two of them in the grant-widening direction).
**Reviewer:** security-reviewer lane, 2026-10-14. No mvn run, no files modified.

## Summary
- Critical: 0
- High: 0
- Medium: 2 (both test-guard gaps, grant-widening direction, no live site affected today)
- Low: 3
- Info: 3

## Q1 — Does ANY authorization outcome change for any principal? **No.**

I tried to break the architect consult rather than restate it. Each claim, its method, and its blind spot:

| Claim | Method (instrument) | Result | Blind spot |
|---|---|---|---|
| All four @EnableMethodSecurity interceptors call the **Supplier** overload | `javap -c -p` on the **binary** `spring-security-core-6.5.7.jar` (not the sources jar the consult read): `PreAuthorizeAuthorizationManager.check`, `PostAuthorizeAuthorizationManager`, `PreFilterAuthorizationMethodInterceptor`, `PostFilterAuthorizationMethodInterceptor` | every call site is `MethodSecurityExpressionHandler.createEvaluationContext:(Ljava/util/function/Supplier;Ljava/lang/Object;)` | closes the consult's sources-vs-binary blind spot |
| Supplier overload never reaches the subclass override | `javap` `DefaultMethodSecurityExpressionHandler` | Supplier overload -> `private createSecurityExpressionRoot(Supplier, MI)` -> `new MethodSecurityExpressionRoot(supplier)` then sets this / permissionEvaluator / trustResolver / roleHierarchy / defaultRolePrefix **from handler fields** | none material; the old Custom class never set any handler field (it set them on its own dead root) and never overrode the Supplier overload (`git show origin/develop:...CustomMethodSecurityExpressionHandler.java`) |
| Spring config does not special-case the handler's class | `javap` `PrePostMethodSecurityConfiguration` (config 6.5.7) | `setExpressionHandler(MethodSecurityExpressionHandler)` passes the bean straight to the 4 interceptors, no `instanceof`/`checkcast`. `setRoleHierarchy`/`setGrantedAuthorityDefaults` mutate only its INTERNAL handler field | none: old and new beans share the declared type `MethodSecurityExpressionHandler` and bean name, so any by-type or by-name injection resolves identically before and after |
| No src/main consumer of the handler or of the 2-arg path | (a) `git grep` src/main for `SecurityExpressionHandler|ExpressionRoot|createEvaluationContext|ExpressionUtils|RoleHierarchy|GrantedAuthorityDefaults|*TemplateDefaults|EnableGlobalMethodSecurity|EnableReactiveMethodSecurity|*AuthorizationManager|.access(|getBean(`; (b) **constant-pool scan** of all 699 `target/classes` files (`grep -a -l -F`, compiled 14:49 today from this tree — `MethodSecurityConfig.class` references `DefaultMethodSecurityExpressionHandler`, no `Custom*Expression*` class present) | (a) only MethodSecurityConfig + javadoc; `getBean` hits are `TaskScheduler` only. (b) `SecurityExpressionHandler`: **only** `MethodSecurityConfig.class`; `createEvaluationContext`, `ExpressionUtils`, `RoleHierarchy`, `GrantedAuthorityDefaults`, `SecurityExpressionRoot`, `MethodSecurityExpressionOperations`, `EnableGlobalMethodSecurity`: **0**; `AuthorizationManager`: only `SecurityConfiguration.class` | Positive controls: `MethodSecurityConfig.class` hits `SecurityExpressionHandler`; the `PreAuthorize;` descriptor hits exactly the 4 known classes. Blind spot: reflection by string built at runtime (no `getBean(String)` found), code outside `net.aim_ai.wms`. |
| Set of live expressions | source `git grep '^[[:space:]]*@(Pre|Post)(Authorize|Filter)\('` AND `javap -v` Utf8 constants of the 4 classes | 13 sites, all `@PreAuthorize(Authority.IS_SB_ADMIN)` = `hasAuthority('sb_admin')` (AdminController 9, AdminActionController 1, ReplenishmentReconciliationController 1, PutawayConfigService 2); 0 `@PostAuthorize/@PreFilter/@PostFilter`; 0 `hasPermission` in any expression | two instruments agree. `hasAuthority` uses a null prefix and the handler's role hierarchy (default `NullRoleHierarchy` in both versions) — outcome is identical |
| HTTP rules (`SecurityConfiguration`) | read lines 144-181 | `authorizeHttpRequests` + `hasAnyAuthority/permitAll/authenticated` only — `AuthorityAuthorizationManager`, no SpEL, no expression handler; file not in diff | — |
| FunctionGuard / `@RequiresFunction` / SDR MappedInterceptor | constant-pool scan above (`src/main/java/net/aim_ai/wms/security` included) | none references any expression handler; they read authorities directly | — |
| No library on the classpath consults a `MethodSecurityExpressionHandler` via the 2-arg path | scanned `BOOT-INF/lib` (246 jars) of `v2/wms2-api/target/wms-api-0.1.0.jar` for `SecurityExpressionHandler` | only spring-security-{core,config,web}. In -web the callers (`WebExpressionAuthorizationManager`, `WebExpressionVoter`, `DefaultHttpSecurityExpressionHandler`) are typed on `RequestAuthorizationContext`/`FilterInvocation` and only reached via `.access(String)` (unused). -config's 2-arg caller is the WebSocket **XML** parser (no XML config). spring-data-rest-*: 0 hits. No spring-security-messaging/-data/-acl/-aspects jar | that jar is the MAIN checkout's, dated 2026-08-10 — an approximation. The diff touches no pom, so before==after on classpath regardless. |

Additional deltas checked and found irrelevant: the dead Custom root's `getThis()` returned the root itself (Default returns the target) — no expression reads `this`; Custom root's `hasDetail` `LOG.info` of claim values is gone (minor improvement).

**Verdict Q1:** no grant-widening and no deny-narrowing for any principal. The architect consult's verdict holds, now on binary evidence plus a compiled-class scan.

## Q2 — Can the new guard ship a broken or OVER-PERMISSIVE expression green? **Yes, in two ways.**

### M1. Guard accepts a null-valued expression that production treats as GRANT
**Severity:** MEDIUM · **Category:** A01 Broken Access Control (test-guard gap) · **Direction:** grant-widening
**Location:** `src/test/java/net/aim_ai/wms/unit/security/MethodSecurityExpressionsResolveArchTest.java:349`
```java
handler.setReturnObject(null, ctx);
expression.getValue(ctx, Boolean.class);
```
Production does not evaluate like this. `javap` of 6.5.7:
- `authorization.method.ExpressionUtils.evaluate` calls `expr.getValue(ctx)` (untyped); `Boolean` -> decision; **`null` -> returns `null`**; anything else -> `IllegalArgumentException("SpEL expression must return either a Boolean or an AuthorizationDecision")`.
- `AuthorizationManagerBeforeMethodInterceptor.attemptAuthorization`: `if (result != null && !result.isGranted()) -> deny`; a **null result falls through to `proceed()`**.

So `@PreAuthorize("#enabled")` with a `Boolean` arg, or `@PreAuthorize("principal.claims['x']")`, evaluates to null -> production lets the call through (fail-OPEN), and the guard passes it silently, because `getValue(ctx, Boolean.class)` returns null without throwing. The inverse also misgrades: a String-valued `"'true'"` is coerced to TRUE in the test but throws (500) in production.
**Exploitability today:** none — all 13 live sites return a primitive boolean. This is about what the guard lets through next.
**Remediation:** grade with production's own rule:
```java
Object v = expression.getValue(ctx);
if (!(v instanceof Boolean) && !(v instanceof org.springframework.security.authorization.AuthorizationResult)) {
    violations.add(where + "evaluating as " + who.getAuthorities() + " returned "
            + (v == null ? "null (production treats this as GRANTED)" : v.getClass().getSimpleName()));
    return;
}
```
Add a self-test fixture `@PreAuthorize("#flag") void nullGrant(Boolean flag)` that must be reported.

### M2. Nothing pins MEANING for any site beyond the 13 named ones, but the javadoc says something does
**Severity:** MEDIUM · **Category:** A01 (test-guard gap) · **Direction:** grant-widening
**Location:** `MethodSecurityExpressionsResolveArchTest.java:92-93`
```java
 *   <li>It proves an expression RESOLVES, not that it grants the right people. That is
 *       {@code MethodSecurityEnablementContractTest}'s job.</li>
```
The blind spot is stated, but the delegation is false in general. `MethodSecurityEnablementContractTest` pins 13 **named** methods (`assertCarriesSbAdmin(X.class.getMethod(...))`) and the constant literal. A 14th site, or a class-level annotation, with `"isAuthenticated()"`, `"permitAll"`, `"true"` or `"hasAuthority('wms_user')"` passes both tests. Under the Keycloak-coarse decision everyone holds `wms_user`, so any of those means "everyone". The guard's own `GoodFixtures.rootProperties` (`"principal != null and authentication.name != null and permitAll"`) shows a grant-everyone expression grading green. `MethodSecurityAnnotationSurfaceArchTest` bans the JSR-250/@Secured family only, and no rail constrains the `@PreAuthorize` value set (`git grep IS_SB_ADMIN src/test` gives only named-site pins). This gap predates the ticket. The new javadoc overstates the coverage.
**Remediation:** the scan already enumerates every site, so assert a deny invariant over it. Every current site is a staff-only carve-out:
```java
// in check(), after the evaluation loop
Boolean asUser = (Boolean) expression.getValue(userCtx);
if (!Boolean.FALSE.equals(asUser) && !ALLOWED_NON_STAFF_SITES.contains(site)) {
    violations.add(where + "GRANTS a plain wms_user; every @PreAuthorize here is a staff-only carve-out. "
            + "Add it to ALLOWED_NON_STAFF_SITES with a reason if intended.");
}
```
At minimum, reword :92-93 to "MethodSecurityEnablementContractTest pins the 13 named carve-outs only; a new site's meaning is unguarded."

### L1. Guard evaluates a hand-built handler, not the context bean
**Severity:** LOW · `MethodSecurityExpressionsResolveArchTest.java:248,292` — `new MethodSecurityConfig().methodSecurityExpressionHandler()`. It cannot see post-construction mutation in the context, such as a `BeanPostProcessor` or an autowired `setRoleHierarchy` on the bean. Today the scan finds 0 `RoleHierarchy`/`GrantedAuthorityDefaults` in compiled classes, so no such mutation exists. A reversed hierarchy (`wms_user > sb_admin`) set in the factory method WOULD be caught by `grantsAdminDeniesUser`; one set elsewhere would not. State it as a blind spot.

### L2. Positive control is 2 of 13 sites, with no count floor
**Severity:** LOW · `:148-152` checks only the two `PutawayConfigService` sites. If AdminController's 9 inherited sites stopped being found (dedup/merged-lookup regression), the guard would grade 4 sites and stay green. Add `assertThat(scan.sites).hasSizeGreaterThanOrEqualTo(13)` (or pin the 4 declaring classes).

### L3. The no-authority / anonymous principal case was dropped
**Severity:** LOW · The deleted `isAimAdmin.noAuthorities_returnsFalse` had no counterpart. `SbAdminOnProductionRoot` checks sb_admin and wms_user only. Add an `AnonymousAuthenticationToken` / empty-authorities row asserting `IS_SB_ADMIN` is FALSE.

### What the guard does well (verified, not assumed)
- It goes through the production bean and the **Supplier** overload, which is the exact path the binary uses. The contract test pins `handler.getClass()` `isEqualTo(DefaultMethodSecurityExpressionHandler.class)`, so a re-introduced dead subclass fails the build.
- `hasRoleIsNotEquivalent` correctly flips the old (false) claim. The surefire XML shows all 12 tests ran, and `everyMainExpressionResolves` is filed under `$SbAdminOnProductionRoot.xml` (CLAUDE.md trap #3), so the outer `Tests run: 0` is not a skip.
- Unresolvable `@bean` refs and `T()` failures are fail-loud (no bean resolver), not silent passes.

## Q3 — Secrets / PII / unsafe patterns
- Secrets scan of every added diff line and the new test (`password|secret|api_key|token|bearer|PRIVATE KEY|client_secret`): **none**. `Jwt.withTokenValue("sbdev-2872").header("alg","none")` is an in-memory test object that is never decoded and never reaches a `JwtDecoder`. Not a risk.
- PII: removing `CustomMethodSecurityExpressionRoot` removes a `LOG.info("Checking usermap for key {} value(s): {}", ...)` of user-detail values (Info, an improvement).
- **Info (pre-existing, out of diff):** `CustomPermissionEvaluator.hasPrivilege` matches with `startsWith(targetType)` + `contains(permission)`, so it is a substring match (`ITEM_READWRITE` satisfies `READ`). It has 0 callers in any expression today. Flag it before anyone writes `hasPermission(...)`.
- Dependency audit: the diff touches no `pom.xml`. `mvn`/OWASP dependency-check was not run (forbidden in this worktree).

## OWASP coverage
A01 evaluated (Q1 neutral; M1/M2 guard gaps). A02 n/a (no crypto touched). A03: SpEL expressions are compile-time constants, with no user-controlled expression strings. A04: M2 is a design-level gap in the guard. A05: method-security flags unchanged and pinned. A06: no dependency change. A07: no authn path touched (`JwtAccessTokenCustomizer`, `MultiTenantJwtDecoder` untouched). A08/A09/A10: not touched (one INFO log of claim values removed).

## Security Checklist
- [x] No hardcoded secrets introduced
- [x] Injection: no runtime-built SpEL (the `getExp*` string builders are deleted, and they had 0 callers)
- [x] Authorization outcome unchanged for every principal (binary + constant-pool + source, positive controls)
- [ ] Guard is production-faithful on result type (M1: null = GRANT not detected)
- [ ] Guard pins expression meaning for unnamed sites (M2)
- [x] Dependencies: unchanged by the diff (audit not run, no mvn)

**Recommendation:** ship the production change. Fix M1 and M2 in the same change, since both are a few lines in the new test. Fix the L items in the same pass too (repo policy: address Lows).

---

## Re-review (2026-10-14, after the M1/M2/L1–L3 fixes)

Read-only, no mvn. Instruments: a source read of `MethodSecurityExpressionsResolveArchTest.java` (875 lines), `git diff origin/develop`, and a **standalone SpEL probe** compiled with `javac` against the packaged jar's libs in the scratchpad (no Maven, no Docker). The probe evaluates real expressions on Spring Security 6.5.7's `DefaultMethodSecurityExpressionHandler`.

**Production delta since the first review:** `UserAdministrationController.java` (new in the diff) and the further `Authority.java` edits are **comment/javadoc only**. I filtered the diff for non-comment `+/-` lines. The only code lines are the already-reviewed `getExp*` deletions. Q1 verdict unchanged: **no authorization outcome changes.**

**Test evidence caveat:** the surefire reports on disk (15:16, after the 15:15 source edit) are from a **mutant run** (`IS_SB_ADMIN` set to `"isSbAdmin()"`): `CheckerSelfTest` 18 run / 1 fail, `everyMainExpressionResolves` red, `grantsAdminDeniesUser` error. That is a good sign, since the guard catches SBDEV-2863's exact defect. But it means the "22 green" claim is **not on disk**. `Authority.IS_SB_ADMIN` is restored (`"hasAuthority('" + SB_ADMIN_ROLE + "')"`, :42), so the restored-tree green run still has to be shown.

### Status of first-review findings

| # | Status | Evidence |
|---|---|---|
| M1 null/non-Boolean result | **FIXED** | `:503 value = expression.getValue(ctx);` then `:517-526` accept `Boolean` / `AuthorizationResult`; otherwise `"returned null, which Spring treats as NO decision and so GRANTS the call"` / `"which is not a Boolean"`. Fixtures `@PreAuthorize("#flag") nullResult(Boolean)` and `@PreAuthorize("'true'") stringResult()`, with the self-test asserting `contains("returned null").contains("GRANTS")`. |
| M2 meaning of unnamed sites | **PARTIAL** (see N1, N2) | `:532 if (authorizes && Boolean.TRUE.equals(grantsPlainUser) && !GRANTS_PLAIN_USER_ON_PURPOSE.contains(owner))` plus `GRANTS_PLAIN_USER_ON_PURPOSE = Set.of()`. Fixtures `isAuthenticated()` and `hasAuthority('wms_user')`. `GoodFixtures` now all AND in `hasAuthority('sb_admin')`. The depth limit is stated (`:111` "cannot tell sb_admin from any other elevated authority"). The check is **skipped** when the plain-user read is inconclusive (N1), and the principal set has no anonymous caller (N2). |
| L1 context bean | **FIXED** | `:169 new AnnotationConfigApplicationContext(MethodSecurityConfig.class)` with `getBean(MethodSecurityExpressionHandler.class)`. Residual stated at `:115-117` ("a RoleHierarchy, GrantedAuthorityDefaults or post-processor declared elsewhere in the app would not be seen"). |
| L2 count floor | **FIXED** | `:208 .hasSizeGreaterThanOrEqualTo(13)` |
| L3 no-authority principal | **FIXED for the constant** | `:398 assertThat(evaluate(Authority.IS_SB_ADMIN, jwtWith())) ... .isEqualTo(Boolean.FALSE)`. The scan itself still evaluates only admin and wms_user (see N2). |

### New findings

#### N1. An over-granting disjunct can hide behind an INCONCLUSIVE read: real, and the residual is understated
**Severity:** MEDIUM (guard gap, grant-widening; no live site affected, since all 13 are `hasAuthority('sb_admin')` and evaluate conclusively)
**Location:** `MethodSecurityExpressionsResolveArchTest.java:504-507`
```java
} catch (SpelEvaluationException e) {
    if (READ_THROUGH_NULL.contains(e.getMessageCode())) {
        continue; // read through a null placeholder: inconclusive, see the class javadoc
```
Probe results (`DefaultMethodSecurityExpressionHandler`, principal `wms_user`, method `m(Dto dto)`):
```
#dto.owner == authentication.name                        | dto=null    -> THROWS PROPERTY_OR_FIELD_NOT_READABLE_ON_NULL
#dto.owner == authentication.name                        | dto=mallory -> false
#dto.owner == authentication.name                        | dto=alice   -> true
#dto.owner == authentication.name or isAuthenticated()   | dto=null    -> THROWS PROPERTY_OR_FIELD_NOT_READABLE_ON_NULL
#dto.owner == authentication.name or isAuthenticated()   | dto=mallory -> true
authentication.details.class != null or isAuthenticated()| any dto     -> THROWS PROPERTY_OR_FIELD_NOT_READABLE_ON_NULL
#p0.owner != 'zz' or hasAuthority('sb_admin')            | dto=null    -> THROWS ... | dto=mallory -> true
```
The coordinator's question has three parts:

1. **`#dto.owner == authentication.name` on its own** is *not* a null-path grant in production. With a null `dto`, `ExpressionUtils.evaluate` turns the `EvaluationException` into an `IllegalArgumentException` (shown by javap in the first review), so the call fails closed with a 500. Its real risk is **meaning**: ownership asserted by the caller, i.e. an IDOR (any user sending `owner=<self>` passes). No placeholder-based evaluation can judge that. The javadoc's "check 4 is skipped for that principal" is honest here.
2. **Disjunct hiding (not stated).** In `<read-through-null> or isAuthenticated()`, the left side throws first, so **both** principals are inconclusive. Check 3 never sees a value, check 4 is skipped, and the AST walk passes (every member exists). In production, `dto` is non-null on every real request, so the expression grants **every wms_user**. Any always-true right-hand side (`isAuthenticated()`, `hasAuthority('wms_user')`, `#p0.x != 'zz'`) hides the same way. The javadoc frames the residual as "a typo on the far side of the null is not seen". It does not say that **a grant-everyone branch after the null read is not seen**.
3. **The exemption is keyed on the SpEL error code, not on where the null came from.** The javadoc says "a read THROUGH one [placeholder]", but any null mid-chain qualifies: `authentication.details.*` (the test's `JwtAuthenticationToken` has null details), `principal.claims['missing'].x`, and so on. Production may populate those (bearer-token `details`), so `authentication.details.class != null or isAuthenticated()` is inconclusive in the guard and grants in production. The claim is broader in code than in prose.

Also: an expression that is inconclusive for **both** principals gets **zero** evaluation evidence, and nothing counts or reports that. `GoodFixtures.readThroughNullArg` pins the exemption as "not a violation", and no self-test shows a hidden disjunct being caught (none can, today).

**Remediation (fail-closed, zero cost today since all 13 live sites are conclusive):** make an inconclusive plain-user evaluation a violation unless allow-listed, so a human has to read every ownership-style expression:
```java
private static final Set<String> INCONCLUSIVE_ON_PURPOSE = Set.of(); // "Class#method" + reason

} catch (SpelEvaluationException e) {
    if (READ_THROUGH_NULL.contains(e.getMessageCode())) {
        if (isPlainUser(who) && authorizes && !INCONCLUSIVE_ON_PURPOSE.contains(owner)) {
            violations.add(where + "cannot be judged for a plain wms_user (reads through null: "
                    + e.getMessageCode() + "); a branch after the null read could grant everyone. "
                    + "Review it and add '" + owner + "' to INCONCLUSIVE_ON_PURPOSE with the reason");
        }
        continue;
    }
```
Add a fixture `@PreAuthorize("#dto.length() > 0 or isAuthenticated()") hiddenDisjunct(String dto)` that must be reported. Move `readThroughNullArg` / `readThroughReturnObject` to an allow-listed fixture. Then reword the javadoc bullet: "a read through ANY null (placeholder or not) makes the expression unjudgeable for that principal; for @Pre/PostAuthorize this is a violation unless allow-listed." A weaker alternative is to re-evaluate with a null-safe rewrite (`.` to `?.`), but that changes semantics and is not recommended.

#### N2. Check 4's principal set has no anonymous caller, and a "good" fixture grants anonymous
**Severity:** LOW (no live site; reachable only if a gated bean is called from a `permitAll` route)
**Location:** `:344`-style loop `for (Authentication who : List.of(admin(), plainUser()))` and `GoodFixtures`:
```java
@PreAuthorize("hasAuthority('sb_admin') or isAnonymous()")
public void literal() {
```
That grades GOOD, yet it admits every unauthenticated caller. `SecurityConfiguration` has `permitAll` routes (`/actuator/health/**`, public authConfig), and those run with an `AnonymousAuthenticationToken`. **Remediation:** add `new AnonymousAuthenticationToken("k", "anonymousUser", AuthorityUtils.createAuthorityList("ROLE_ANONYMOUS"))` (and/or `jwtWith()`) to the evaluated principals, require deny for both, and replace `isAnonymous()` in the good fixture with `isAuthenticated()` under an `and`.

#### N3. Mutation evidence: positive
**Severity:** INFO. The on-disk mutant run (`"isSbAdmin()"`) turned `everyMainExpressionResolves`, `correctExpressionsPass` and `grantsAdminDeniesUser` red. The author's G/H mutants (deny check disabled, null-as-grant) target M2/M1 directly. **Missing:** a mutant for N1, i.e. a hidden disjunct in `src/main`. Today it would stay green, which is the finding.

### Re-review verdict
- Production: **ship**. Behaviour-neutral, and the newly added files are comment-only.
- Guard test: M1, L1, L2, L3 **FIXED**. M2 **PARTIAL**: the new inconclusive exemption (N1) re-opens a grant-widening hole that check 4 was meant to close, and the javadoc states the residual as "typo not seen" rather than "grant not seen".
- Before merge: fix N1 (fail-closed allow-list plus hidden-disjunct fixture) and N2 (anonymous principal), and attach a green run of the restored tree. The current on-disk reports are a mutant run.

### Re-review checklist
- [x] No hardcoded secrets (new fixtures are literals in src/test only)
- [x] Production authorization unchanged (new src/main edits are comment-only)
- [x] M1 null/non-Boolean is graded like production
- [ ] Inconclusive evaluations cannot hide a grant (N1)
- [ ] Anonymous principal held to the deny check (N2)
- [ ] Green run of the restored tree on disk (current reports = mutant run)

---

## Re-review 2 (2026-10-14, after the N1/N2 fixes)

Read-only, no mvn, and I did not trust reports in `target/` (they are being rebuilt). Instruments: a source read of the revised `MethodSecurityExpressionsResolveArchTest.java` (1015 lines), and a standalone `javac` probe in the scratchpad against the packaged jar's libs (Spring Security 6.5.7: core + web), with no Maven and no Docker. Production diff unchanged: `git diff origin/develop --stat` is still 8 files, +64/−673, and the src/main edits are comment-only apart from the reviewed `getExp*` deletions.

### Status

| # | Status | Evidence |
|---|---|---|
| N1 grant hidden behind an inconclusive read | **FIXED** | `if (usesPlaceholder && e instanceof SpelEvaluationException spel && READ_THROUGH_NULL.contains(spel.getMessageCode())) { continue; }`. Any other null read is now a violation (fixture `nullReadNoPlaceholder`, asserted `contains(" threw ")`). Then `if (inconclusive \|\| usesPlaceholder) { if (!DENY_JUDGED_ELSEWHERE.contains(owner)) { unjudged.add(...) } return; }` and the main test asserts `scan.unjudged` is empty. My `grantBehindNullRead` (`"#dto.length() > 0 or isAuthenticated()"`) is now required to be unjudged (`placeholderDependentGateIsUnjudged`, `hasSize(3)`). This is fail-closed: an expression that touches a placeholder can no longer pass silently. The javadoc states the residual honestly: "a typo OR A GRANT on the far side of that null is not seen, which is why an inconclusive gate is reported as unjudged". |
| N2 anonymous principal | **PARTIAL** (see R1) | `principals.put(anonymous(), "an ANONYMOUS caller, which is who permitAll routes run as")`. Grants are checked for it (`grantsAnonymous` fixture reported), and `GoodFixtures.literal` no longer uses `isAnonymous()`. But an exception for the anonymous principal is unconditionally counted as DENIED, and that is exploitable (R1). |

### (a) Is "anonymous exception = denied" a hole? **Yes, a narrow one. R1, MEDIUM-LOW.**
```java
} catch (RuntimeException e) {
    if (who instanceof AnonymousAuthenticationToken) {
        ...
        nonAdminGrants.put(entry.getValue(), false);
        continue;
    }
```
The comment's premise is that a throw in the test means a throw (fail closed) in production. That holds only if the test's anonymous principal has production's **shape**, and it does not:
- Test: `new AnonymousAuthenticationToken("sbdev-2872", "anonymousUser", ROLE_ANONYMOUS)` with **`details == null`**.
- Production: `AnonymousAuthenticationFilter` calls `authenticationDetailsSource.buildDetails(request)` then `AnonymousAuthenticationToken.setDetails(...)` (shown by javap on spring-security-web-6.5.7), so `details` is a non-null `WebAuthenticationDetails`.

Probe:
```
hasAuthority('sb_admin') or (isAnonymous() and authentication.details.remoteAddress != null)
   user=false   testAnon=THROWS PROPERTY_OR_FIELD_NOT_READABLE_ON_NULL   prodAnon(details set)=true
```
The guard sees admin TRUE and plain user FALSE (conclusive, since `isAnonymous()` short-circuits the `and`). The anonymous throw is booked as **denied**. The expression references no placeholder, so it is judged and passes green. In production it **grants every unauthenticated caller** that reaches the method. The "a null read without a placeholder is a violation" rule is bypassed for exactly this principal, because the anonymous catch runs **before** it. The javadoc's "a gate should not depend on [request-scoped details]" is advice, and nothing enforces it.
**Exploitability today:** none. All 13 sites are `hasAuthority('sb_admin')`, and the shape is contrived. It is still a gap in the one check that exists to stop grant-widening.
**Fix (either one; the first is a one-liner):**
```java
// 1. production-shaped anonymous principal: the throw then becomes a conclusive TRUE and is reported
AnonymousAuthenticationToken anon = new AnonymousAuthenticationToken("sbdev-2872", "anonymousUser",
        AuthorityUtils.createAuthorityList("ROLE_ANONYMOUS"));
anon.setDetails(new WebAuthenticationDetails("127.0.0.1", null));
// 2. and/or: only String-principal resolution failures count as denied; a READ_THROUGH_NULL for the
//    anonymous caller goes through the same rule as the other principals (violation unless placeholder)
if (who instanceof AnonymousAuthenticationToken
        && !(e instanceof SpelEvaluationException s && READ_THROUGH_NULL.contains(s.getMessageCode()))) { ... }
```
Add a fixture with the probe's expression that must be reported. (Same shape-fidelity point, lower stakes: `jwtWith(...)` also has null `details`. That only produces false violations for the JWT principals, which is fail-loud, so no change is needed there.)

### (b) Is "every placeholder-referencing @Pre/PostAuthorize is unjudged" too strict? **Acceptable as a security posture. Recommend one sound refinement and one wiring fix.**
- **Security-wise it is right.** It fails closed: a human must name the site, so no argument-dependent gate can slip through.
- **Cost:** the obvious next real gate, `IS_SB_ADMIN + " and #id != null"`, is forced into `DENY_JUDGED_ELSEWHERE` even though its deny verdict is **sound**. Probe: `user=false testAnon=false prodAnon=false`. The left conjunct is FALSE for every non-admin, and `and` short-circuits before the placeholder is read. The verdict cannot depend on `#id`, and if the right side ever threw in production that is still a deny.
- **Refinement (sound, small):** if the expression's top node is `OpAnd` and some conjunct references no placeholder, evaluate that conjunct alone for the non-admin principals. If it is conclusively FALSE for each, the whole gate is judged as denying, whatever the placeholder conjuncts do. (`A and B` with A=false is false, or throws, which is also a deny.) That covers "staff gate plus argument sanity check" without the allow-list, and leaves `or`-shaped and pure-ownership expressions (`#dto.owner == authentication.name`, the IDOR class) unjudged, which is where a human belongs.
- **Wiring gap:** the unjudged message says a new site must be "pinned by name in MethodSecurityEnablementContractTest". That test's only helper, `assertCarriesSbAdmin`, asserts `isEqualTo(Authority.IS_SB_ADMIN)`, so a composite expression **cannot** be pinned with it. The first allow-listed site will need a new helper (pin the exact expression string). Otherwise the instruction is unfollowable, and the path of least resistance is to add to the allow-list without a pin. Say so in the message, or add the helper now.

### (c) Other new observations
- **R2 (LOW, resolution-only, no grant risk):** code-lane N2's indexer skip (`else if (node instanceof Indexer && child instanceof PropertyOrFieldReference) continue;`) is correct only for **Map** targets. For a Map, SpEL's `Indexer` reads a bare name as a literal key. For a List, array or object target it evaluates the child against the **root**, so `authentication.authorities[typo]` is a real root read whose typo the AST walk no longer sees. Evaluation still catches it if reached, and in production it throws (deny). Not a grant hole: state it in the blind-spot list, or skip only when the static target is known to be a Map.
- **N4 context lifecycle:** verified. `securityContext` is created lazily and closed in `@AfterAll` (`securityContext.close(); securityContext = null;`). Fine.
- `principals` is a `LinkedHashMap` keyed by `Authentication`. The three tokens differ in authorities and type, so there is no key collapse. Fine.
- `inconclusive = nonAdminGrants.size() < principals.size() - 1`: an inconclusive **admin** evaluation is not counted. That is fine for a deny check (admin must be granted, which is not the guard's question).
- The author's evidence (24 + 18 green, 13 named mutants with killers, IT baseline parity 842/0F/2E/23S equal to develop `64fbbb07`) is **not verifiable from disk** while `target/` is being rebuilt. I take it as reported. Mutants J/L (`noUnjudged`, `anonThrowIsViolation`) cover N1/N2's wiring. **No mutant covers R1**, and one would stay green today.

### Re-review 2 verdict
- Production change: **ship** (unchanged, behaviour-neutral).
- Guard: N1 **FIXED**. N2 **PARTIAL**, because R1 (the anonymous throw is booked as a deny with a principal that lacks production's `details`) re-opens anonymous grant-widening for request-detail-dependent expressions. The fix is one line (`setDetails(new WebAuthenticationDetails(...))`) plus a fixture.
- (b) strictness is acceptable. Recommend the `OpAnd` refinement and a contract-test helper that can pin a composite expression, so the first legitimate argument-checking gate has a followable path.
- R2 is a Low blind-spot note.

### Re-review 2 checklist
- [x] No secrets or production behaviour change in this round
- [x] N1: inconclusive placeholder gates are reported (unjudged), not passed; non-placeholder null reads are violations
- [ ] N2/R1: anonymous throw counted as deny only when production would also throw (principal shape)
- [ ] (b) a followable pin path for a legitimate composite gate (contract-test helper)
- [ ] Green run evidence on disk (pending the rebuild)

---

## Re-review 3 (b167d460)

Scope: commit `b167d460` on `feature/SBDEV-2872-preauthorize-expressions-resolve` (PR #516), on top of `64fbbb07` (= origin/develop). No file edited; `git status --short` is empty before and after.

Instruments:
1. A source read of the test (1111 lines).
2. `git show b167d460` filtered to non-comment src/main lines.
3. The permitted single run, `mvn -o -q test -Dtest=MethodSecurityExpressionsResolveArchTest ...` with JDK 21. Exit 0. **24 testcases** in the XML reports (CheckerSelfTest 20, SbAdminOnProductionRoot 3 + the outer `everyMainExpressionResolves` filed with it). 0 failures, 0 errors. `pgrep` showed no other Maven first.
4. Standalone `javac` probes against the packaged jar's libs (Spring 6.2.15 SpEL, Security 6.5.7).

### (d) Production diff and commit-message claims
- **Production code is unchanged** from what Re-reviews 1 and 2 approved. The non-comment src/main lines in `b167d460` are exactly: the `getExp*` deletions, the deletion of both `Custom*` classes, and `new DefaultMethodSecurityExpressionHandler()` plus its import. Everything else in `Authority`, `UserAdministrationController`, `PutawayConfigService` and `MethodSecurityConfig` is javadoc.
- **"custom root was dead from bd330a3a (2025-09-20)": VERIFIED.** `git show bd330a3a -- MethodSecurityConfig.java` swaps `@EnableGlobalMethodSecurity` / `extends GlobalMethodSecurityConfiguration` / `createExpressionHandler()` (the legacy, 2-arg, custom-root-honouring path) for `@EnableMethodSecurity` plus a `@Bean`. That is the moment the override stopped being consulted.
- **"javap on 6.1.0 and 6.5.7":** 6.5.7 re-verified here. I did not re-run 6.1.0 (both jars are in `~/.m2`).
- **"AC3 -> 26 problems across 13":** not re-run, since it needs a source mutation and editing is forbidden. It is consistent with my Re-review 1 observation of the `isSbAdmin()` mutant going red on all 13 sites (AST + evaluation = 2 per site; 13×2 = 26).
- **"17 checker mutants each killed":** not re-derived (it needs edits). See (c) for one mutant the fixtures would NOT kill.

### R1 (from Re-review 2): **FIXED** (one residual, F2)
```java
token.setDetails(new WebAuthenticationDetails("127.0.0.1", null)); // as AnonymousAuthenticationFilter does
...
boolean nullRead = e instanceof SpelEvaluationException spel && READ_THROUGH_NULL.contains(spel.getMessageCode());
if (who instanceof AnonymousAuthenticationToken && !nullRead) { nonAdminGrants.put(entry.getValue(), false); continue; }
if (who instanceof AnonymousAuthenticationToken) { continue; } // inconclusive
```
My R1 probe is now fixture `grantsAnonymousViaDetails`, asserted `contains("GRANTS an ANONYMOUS caller")`, and it is green in the run above. The JWT principal's `setDetails` comment ("as BearerTokenAuthenticationFilter does") is accurate: javap of `JwtAuthenticationProvider` 6.5.7 shows `if token.getDetails()==null -> setDetails(bearer.getDetails())`, which applies to the token `JwtAccessTokenCustomizer.convert` builds.

### (a) Can the and-conjunct shortcut judge a gate that grants in production?

**Short-circuit order: sound.** For `A and C` with a placeholder-free `C` that is FALSE for a principal:
- A FALSE gives false.
- A TRUE runs C, which is false.
- A throwing makes production's `ExpressionUtils.evaluate` raise `IllegalArgumentException`, which is a 500 and therefore a deny.
- A returning null makes `OpAnd` reject the null operand (throws), also a deny.

The position of the placeholder conjunct cannot turn a FALSE `C` into a grant.

**Nested `or` inside a conjunct: sound.** `toStringAST` parenthesises every `BinaryOperator`, for example `(hasAuthority('wms_user') or hasAuthority('x'))`, so the conjunct re-parses as one unit and is graded as a whole.

**Early return: sound in itself.** The static AST problems and evaluation violations are recorded before the shortcut, and the only step it skips is the grant report. That step cannot fire legitimately when some conjunct is FALSE for that principal, except through F1 below.

#### F1. The shortcut re-parses `toStringAST()`, which is not value-faithful, and can silence a conclusive grant (LOW)
**Location:** `deniedByAPlaceholderFreeConjunct`
```java
Expression part = handler.getExpressionParser().parseExpression(conjunct.toStringAST());
```
I probed 40 shapes: quotes (`'it''s'`, `"it's"`, `'a"b'`), escapes, ternary, elvis, `?.`, selection, projection, inline list and map, `T(...)`, `instanceof`, `between`, `matches`, `^`, `%`, `#root`/`#this`. All round-trip to the same value **except literal suffixes**: `10L` prints as `10`, `1.0f` as `1.0`, `0x10` as `16`. That changes the boxed type. Probe:
```
DIFF T(java.util.Objects).equals(T(java.lang.Long).parseLong('7'), 7L)
  =>  T(java.util.Objects).equals(T(java.lang.Long).parseLong('7'),7)   orig=true rt=false
```
**How it reaches a grant:** the shortcut runs whenever `usesPlaceholder` is true, **even if the full expression was conclusively TRUE for the plain user or the anonymous caller.** Take `T(java.util.Objects).equals(T(java.lang.Long).parseLong('7'), 7L) and #id != null`:
- In the test, the plain user gets FALSE (`#id` is null), and the re-parsed conjunct is FALSE for both must-deny principals, so the gate is judged and nothing is reported.
- In production, `#id` is non-null and the gate grants every `wms_user`.
- Before this commit the same site went to `unjudged` (reported). Now it passes silently.

Other unsound inputs to the same rule:
- Non-deterministic conjuncts that reference no placeholder: `T(java.time.LocalTime).now().hour >= 12`, `T(System).getenv('X') == 'y'`, static mutable state. FALSE at test time does not mean FALSE in production.
- Contrived and author-written. No attacker controls an annotation string. Hence LOW.

**Fix** (all three are small):
```java
// 1. evaluate the conjunct node itself; no print/re-parse round trip
Expression part = new SpelExpression(conjunct.toStringAST(), (SpelNodeImpl) conjunct, new SpelParserConfiguration());
// 2. never let the shortcut overrule a conclusive grant already observed
if (nonAdminGrants.containsValue(Boolean.TRUE)) { /* skip shortcut; report the grant */ }
// 3. only accept a denying conjunct with no TypeReference / BeanReference (principal-determined only)
```
Also: `parseExpression` sits **outside** the try, so a print that fails to re-parse (e.g. `2147483648L` prints as `2147483648`, which is an int overflow) throws out of `check()` and errors the whole test. That is fail-loud, not a pass, but unfriendly.

### (b) Is "anonymous null read = inconclusive" + "anonymous structural error = denied" sound?

**Null read is inconclusive: sound.** It routes the site to `unjudged` (fixture `anonymousNullRead`) or to the shortcut. Fail-closed.

#### F2. "Structural error = denied" is really "any non-null-read RuntimeException = denied", including value-dependent ones (LOW)
```java
if (who instanceof AnonymousAuthenticationToken && !nullRead) {
    // ... throws in production too, and fails closed.
    nonAdminGrants.put(entry.getValue(), false);
```
The comment's premise ("throws in production too") holds for errors decided by the principal's **type** (`principal.claims` on the String `"anonymousUser"`, EL1008E/EL1004E). It does not hold for errors that depend on a request-scoped **value**, because the token now carries a fixed `127.0.0.1`. Probe:
```
hasAuthority('sb_admin') or (isAnonymous() and authentication.details.remoteAddress.substring(10).length() > 0)
  127.0.0.1      -> THROWS StringIndexOutOfBoundsException   (guard books: DENIED; plain user short-circuits FALSE -> judged, green)
  203.0.113.200  -> true                                      (production: GRANTS anonymous)
```
The same applies to `T(Integer).parseInt(...)`, index-out-of-bounds, arithmetic and conversion errors over `details` values.
**Fix:** count as denied only an allow-list of type-structural codes, and treat everything else (including non-Spel `RuntimeException`s) as inconclusive:
```java
private static final Set<SpelMessage> STRUCTURAL = Set.of(
        SpelMessage.PROPERTY_OR_FIELD_NOT_READABLE, SpelMessage.METHOD_NOT_FOUND);
boolean structural = e instanceof SpelEvaluationException s && STRUCTURAL.contains(s.getMessageCode());
if (who instanceof AnonymousAuthenticationToken) {
    if (structural) { nonAdminGrants.put(entry.getValue(), false); }
    continue; // anything value-dependent is inconclusive -> unjudged or shortcut
}
```
Add the probe as a fixture that must land in `unjudged`. LOW: it is contrived, depends on request details (which the javadoc already tells authors to avoid), and affects no live site.

### (c) Do the new fixtures prove what they claim?

| Fixture | Claim | Verdict |
|---|---|---|
| `grantsAnonymousViaDetails` | R1 probe reported as an anonymous grant | **Proves it** (anonymous evaluation is conclusive TRUE only because `details` is now set). Kills N (no-anon-details). |
| `nullReadNoPlaceholder` = `hasAuthority('sb_admin') and authentication.details.sessionId.length() > 0` | a null read without a placeholder is a violation, EL1011E | **Proves it.** Admin reaches the right side, and `sessionId` is null in the fixture details, so it gives METHOD_CALL_ON_NULL. Re-pointing it was necessary: the old `details.typo` became EL1008E once `details` was non-null. |
| `anonymousNullRead` | anonymous null read is inconclusive, not denied | **Proves it.** Top node is `OpOr`, so the shortcut cannot rescue it. Kills O. |
| `grantGatedOnlyByArgument` = `hasAuthority('wms_user') and #id != null` | the shortcut needs FALSE for **every** must-deny principal | **Partly.** It kills "any principal FALSE suffices" and "anonymous only", because the conjunct is TRUE for the plain user. It does **not** kill a mutant that evaluates the shortcut for the **plain user only**, since no fixture has a conjunct FALSE for the plain user but TRUE for anonymous. Add `@PreAuthorize("!hasAuthority('wms_user') and #id != null")`, which must be unjudged. |
| `adminAndArgument` = `IS_SB_ADMIN + " and #id != null"` | the shortcut judges the canonical staff+argument gate | **Proves it** (asserted `noneMatch` in unjudged). Two conjuncts only, so `flattenAnd`'s recursion (`a and b and c`, which is left-associative) is not exercised. A mutant that flattens one level would survive. Add a 3-conjunct good fixture. |

Unjudged-message change (item 3): verified that it now tells the author to pin the exact annotation value, which closes the "unfollowable instruction" point from Re-review 2(b). R2 (bare indexer key) is now stated in the javadoc blind-spot list: closed as documented.

### Findings summary (Re-review 3)
| ID | Severity | Status |
|---|---|---|
| R1 (Re-review 2) | — | **FIXED** |
| F1 shortcut re-parse is not value-faithful and can override a conclusive grant; non-deterministic conjuncts | LOW | new |
| F2 any non-null-read anonymous exception booked as DENIED, including value-dependent ones | LOW | new |
| F3 fixture gaps: no "FALSE for plain but TRUE for anonymous" conjunct; no 3-conjunct flatten case | LOW | new |

No Critical, High or Medium. Production remains behaviour-neutral, and the deleted code is replaced by what already ran.

### Re-review 3 verdict
- **Ship-ready from a security standpoint.** The production change is neutral. The guard is now fail-closed on every path I could find, except two contrived LOW shapes (F1, F2) that an author would have to write on purpose into an annotation.
- Per repo policy (address Lows): F1 fix 1+2 is about 3 lines, F2 is about 5 lines, F3 is 2 fixtures. Each needs a mutant to show the new fixture kills it.

### Re-review 3 checklist
- [x] No secrets or production behaviour change (non-comment src/main lines verified)
- [x] Commit-message dating claim (bd330a3a) verified in git history
- [x] Guard class green when run here: 24 testcases, 0F/0E, tree left clean
- [x] R1 fixed; `grantsAnonymousViaDetails` reported
- [ ] F1: shortcut evaluates the node in place and never overrides an observed grant
- [ ] F2: only type-structural anonymous errors count as denied
- [ ] F3: two fixtures to close the mutant gaps

---

## Re-review 4 (F1–F3)

Scope: the **uncommitted** diff to `MethodSecurityExpressionsResolveArchTest.java` on top of `b167d460` (`git diff`: 1 file, +78/−13; no src/main change). No mvn: a peer `mvn clean test` is running. I did not trust `target/`. Instruments: a read of the diff, plus a standalone `javac` probe (`Probe5.java`) in the scratchpad against the packaged jar's libs (SpEL 6.2.15, Security 6.5.7). The probe mirrors the test's exact calls: `new SpelExpression(node.toStringAST(), (SpelNodeImpl) node, new SpelParserConfiguration())`, tokens with `WebAuthenticationDetails("127.0.0.1", null)`, and a shared principal instance. The worktree was not touched: `git status --short` shows only the coordinator's own ` M` on the test file, unchanged by me.

### Status

| # | Status | Evidence |
|---|---|---|
| F1 shortcut fidelity | **PARTIAL** | In-place evaluation **FIXED**: `Expression part = new SpelExpression(conjunct.toStringAST(), (SpelNodeImpl) conjunct, new SpelParserConfiguration());`. Probe on the new good fixture: `(7L).equals(7)` prints as `7.equals(7)`; in place gives **false**, re-parsed gives **true**. So `literalSuffixConjunct` genuinely pins in-place evaluation, and mutant W is correctly killed. The non-determinism filter `readsOutsideThePrincipal` (`node instanceof TypeReference \|\| node instanceof BeanReference`) is **bypassable** (F1a). The `grantObserved` guard is **reachable**, contrary to its comment, and mutant V survives only for lack of a fixture (F1b). |
| F2 anonymous error = deny | **FIXED** (one Info residual) | `TYPE_STRUCTURAL = Set.of(PROPERTY_OR_FIELD_NOT_READABLE, METHOD_NOT_FOUND)`; `if (who instanceof AnonymousAuthenticationToken && structural) { ...false...; continue; }` and every other anonymous failure is inconclusive. My substring probe is now fixture `anonymousValueDependentError` and must be unjudged. |
| F3 fixture gaps | **FIXED** | `conjunctDeniesOnlyThePlainUser` = `"!hasAuthority('wms_user') and #id != null"` is FALSE for the plain user and TRUE for anonymous, so it kills S (plain-only shortcut). `deepConjunct` = `IS_SB_ADMIN + " and #id != null and #p0 != null"` puts the denying conjunct two levels down the left-nested `OpAnd`, so it kills T (one-level flatten). `typeReferenceConjunct` kills U. Counts updated: unjudged `hasSize(8)`, good sites `hasSize(18)`. |

### F1a. `readsOutsideThePrincipal` misses constructors and reflection (LOW)
Probe (AST node classes printed):
```
new java.util.Random().nextBoolean()
  CompoundExpression > ConstructorReference(new java.util.Random()) > MethodReference(nextBoolean())   value=false (random)
authentication.class.forName('java.lang.System').getProperty('user.name') != null
  OpNE > CompoundExpression > PropertyOrFieldReference(authentication), PropertyOrFieldReference(class),
         MethodReference(forName(..)), MethodReference(getProperty(..))                                value=true
''.class.forName('java.lang.Boolean').FALSE                                                           value=false
```
Neither contains a `TypeReference` or `BeanReference`. So `new java.util.Date().hours >= 12 and #id != null`, or a `.class.forName('java.lang.System').getenv(...)` conjunct, still reaches the shortcut. A FALSE at test time then judges a gate that can grant in production.
**Fix:** also reject `ConstructorReference`, and any `MethodReference` / `PropertyOrFieldReference` named `class` / `getClass` / `forName`. Better still, invert to an allow-list: accept a denying conjunct only if every node is a root `MethodReference` from `SecurityExpressionRoot` (`hasAuthority`, `hasAnyAuthority`, `hasRole`, `hasAnyRole`, `isAuthenticated`, `isAnonymous`, `isFullyAuthenticated`, `isRememberMe`, `denyAll`, `permitAll`), a literal, or `!`/`and`/`or`/parentheses. That is the only shape the shortcut needs (`IS_SB_ADMIN and ...`), and it is principal-determined by construction. Add a `new java.util.Random().nextBoolean() and #id != null` fixture that must be unjudged.

### F1b. Mutant V is reachable: "unreachable by construction" is false (LOW)
The claim depends on re-evaluation being a pure function of (node, principal, args). It is not: the shortcut re-uses the **same principal instances** (`principals.keySet()`) that the full evaluation just ran against, and SpEL can call mutators on them. Probe, with `user` shared between the two evaluations exactly as `check()` does:
```
expr: authentication.details != null and authentication.setDetails(null) == null and #id == null
full evaluation (plain user)                         = true    -> grantObserved
conjunct '(authentication.details != null)' in place = false   (details cleared by the full evaluation)
```
Without the `!grantObserved` guard (mutant V), the shortcut finds a placeholder-free conjunct FALSE for both must-deny principals, so it judges the gate. A conclusive grant then passes silently, where the guarded code puts it in `unjudged`. So the guard is **load-bearing**, and its comment should say so ("re-evaluation is not pure: SpEL can mutate the shared principal; this guard stops a grant the full evaluation already saw being overruled").
**Fix:**
- Add the expression above to `UnjudgedFixtures`. It kills V.
- Optionally, give the shortcut **fresh** principals (`admin()`/`plainUser()`/`anonymous()` again) instead of the evaluated instances. That removes cross-evaluation contamination entirely.

Short-circuiting and exceptions do not make V reachable. A full `and` that is TRUE evaluated every conjunct without throwing, and an exception in the shortcut sets `deniesAll = false`. Only side effects (above) and non-determinism (F1a) can.

### Q: does TYPE_STRUCTURAL wrongly book a production-reachable error as a deny?
- **Null argument causing METHOD_NOT_FOUND (null into a primitive parameter, e.g. `principal.charAt(#i)` with `Integer i`): harmless.** Such an expression references a placeholder, so `usesPlaceholder` is true. The site goes to `unjudged` (or the shortcut, which only re-evaluates **placeholder-free** conjuncts). The anonymous "denied" booking from the full evaluation never decides the verdict.
- **Without placeholders,** the anonymous principal's values are fixed by type in both test and production: principal is the String `"anonymousUser"`, authorities are `SimpleGrantedAuthority("ROLE_ANONYMOUS")`, and details is a `WebAuthenticationDetails` with String fields. EL1008E/EL1004E there is type-decided and recurs in production. **Sound.**
- **Info residual:** `SecurityConfiguration` sets no `sessionCreationPolicy` (`git grep` gives 0 hits), so the default `IF_REQUIRED` applies and production `details.sessionId` can be **non-null** when a session cookie exists. The test tokens fix it to null. A null-read through `sessionId` is inconclusive or a violation (fail-closed / fail-loud), so this is not a grant path. A METHOD_NOT_FOUND from null `sessionId` into a primitive parameter would be booked as an anonymous deny, while production's non-null value could resolve via String-to-int conversion. That is vanishingly contrived (needs a numeric session id), so I am noting it only. The same fact makes `nullReadNoPlaceholder`'s "production has nothing the test lacks" reasoning slightly optimistic for `sessionId`. Harmless, since the fixture's purpose is the EL1011E classification.

### Q: is `(SpelNodeImpl) conjunct` safe for every node type?
**Yes.** Every node that `InternalSpelExpressionParser` builds extends `SpelNodeImpl`, and `flattenAnd` only yields children of `OpAnd` (a `SpelNodeImpl`), so the cast cannot fail. Wrapping a subtree in a new `SpelExpression` is semantically equivalent to in-tree evaluation for a top-level conjunct: its scope is the root, the same as inside the `and`. `#this`/`#root` resolve to the root object in both. Node-level caches (`MethodReference.cachedExecutor`, the property accessor cache) are shared, but they are validated against the target type on every use. The default `SpelParserConfiguration` (compiler OFF) matches the handler's default `SpelExpressionParser`. The probe agrees (in-place `(7L).equals(7)` gives false, matching the in-tree value).

### Info
- A placeholder-referencing expression with an **observed** grant (e.g. `hasAuthority('wms_user') and #id == null`, TRUE for the plain user) is reported as `unjudged` with the message "outcome depends on a null placeholder", rather than as `GRANTS a plain wms_user`. It still fails the build, which is what matters. A clearer message would say a grant was observed.

### Re-review 4 verdict
- F2 **FIXED**. F3 **FIXED**. F1 **PARTIAL**: in-place evaluation and the grant guard are correct, but the non-determinism filter is bypassable (F1a), and the guard's "unreachable" comment is wrong and unpinned (F1b).
- All remaining items are LOW, contrived, author-written annotation shapes. No live site is affected (all 13 are `hasAuthority('sb_admin')`). Production is unchanged and behaviour-neutral.
- To close (address-Lows policy):
  - F1a: switch to an allow-list of principal-only node shapes, plus a `new java.util.Random()` fixture.
  - F1b: add the `setDetails(null)` side-effect fixture (kills V), correct the comment, and optionally use fresh principals for the shortcut.
  - Re-run the class after the peer build finishes, and confirm the testcase count moves by the number of added fixtures' self-test assertions. Since `hasSize` assertions grade the fixtures, the count of tests stays the same and the sizes move.

### Re-review 4 checklist
- [x] No src/main change in this round
- [x] In-place conjunct evaluation is faithful (probe: in-place false vs re-parse true)
- [x] Anonymous deny is limited to type-structural errors (sound for a production-shaped anonymous token)
- [x] F3 mutant gaps closed (S, T, U)
- [ ] F1a: shortcut rejects constructors and reflection (or uses an allow-list)
- [ ] F1b: V killed by a side-effect fixture; comment corrected
- [ ] Green run on disk after the peer build

---

## Re-review 5 (HEAD 2e966e44)

Scope: `git show HEAD` = `2e966e44` ("close review-round 3/4 gaps in the expression guard"). One file changed, `MethodSecurityExpressionsResolveArchTest.java`, +112/−17. It also folds in the round-4 F2/F3 changes reviewed in Re-review 4. **No src/main change.**

Instruments:
1. Read the HEAD diff.
2. Standalone `javac` probe `Probe6.java` in the scratchpad, against the packaged jar's libs. It uses production-shaped `JwtAuthenticationToken` and `AnonymousAuthenticationToken`, both with `WebAuthenticationDetails`.
3. The permitted run `mvn -o -q test -Dtest=MethodSecurityExpressionsResolveArchTest,MethodSecurityEnablementContractTest ...` (JDK 21; `pgrep` showed no other Maven). Exit 0. XML testcases: **24** in the guard class (CheckerSelfTest 20 + SbAdminOnProductionRoot 3 + the outer `everyMainExpressionResolves`) and **18** in the contract test. 0 failures, 0 errors. That matches the author's 24 + 18.

`git status --short` was empty before and after. Nothing edited.

### Status

| # | Status | Evidence |
|---|---|---|
| F1a non-determinism filter | **FIXED** | The reject-list is replaced by the allow-list `isPureAuthorityCheck`: `Literal`; `OperatorNot`/`OpAnd`/`OpOr` over pure children; `MethodReference` in `PURE_ROOT_CHECKS` whose children are all `Literal`. Constructors, `T(...)`, `@bean`, `.class.forName`, setters and property reads all fall outside it. The fixture `constructorConjunct` ("new java.util.Random().nextBoolean() and #id != null") is required to be unjudged (`hasSize(10)`). Green in the run above. |
| F1b guard reachability | **FIXED in effect; one comment still overstates (LOW)** | The shortcut now runs on fresh tokens: `List.of(plainUser(), anonymous())) { // fresh tokens: nothing earlier can have mutated them`. `sideEffectConjunct` is unjudged with "GRANTED". The guard is pinned through the wording it selects. **However**, the new comment's claim that "The allow-list and fresh principals below also close that path, so the shortcut-blocking role has no fixture of its own" is **false**. See F1c. |

#### F1c. The guard still blocks a reachable grant: the shortcut-blocking role is live and unpinned (LOW)
Fresh principals stop the *shortcut's* evaluation from seeing a mutated token. They do not make the shortcut agree with the *full* evaluation, which ran on tokens the expression itself mutated. The probe uses a pure (allow-listed) conjunct:
```
full  = authentication.setAuthenticated(false) == null and !(isAuthenticated() or isAnonymous()) and #id == null
full, plain user, id=null       = true      <- grantObserved
full, anonymous                 = false
conj  = !(isAuthenticated() or isAnonymous())        (OperatorNot over OpOr over PURE_ROOT_CHECKS: passes isPureAuthorityCheck)
conj, FRESH plain               = false
conj, FRESH anonymous           = false     <- deniesAll
```
`isAuthenticated()` reads `authentication.isAuthenticated()` via the trust resolver, so it is not purely "the principal's granted authorities", as `PURE_ROOT_CHECKS`' javadoc says. The expression flips that flag on the live token. Production evaluates the same way: the token is mutated, then the gate grants a plain user whenever `#id` is null.
- **With** `!grantObserved`: the shortcut is skipped, and the site is reported unjudged with the "GRANTED..." wording. Correct.
- **Mutant V′** (drop `!grantObserved` from the shortcut predicate only, keep the wording): `deniedByAPlaceholderFreeConjunct` returns true, `check()` returns early, and the grant passes **silently**. No current fixture kills V′. `sideEffectConjunct`'s conjuncts are not pure, so the shortcut would not judge it either way.

**Fix:**
- Add the probe expression to `UnjudgedFixtures`, asserting "GRANTED". That kills V′.
- Correct the comment: fresh principals isolate the shortcut, but the full evaluation's tokens can be mutated, so the guard is the only thing that stops a pure conjunct overruling an observed grant.
- Do not try to remove the guard by also giving the full evaluation fresh tokens: the grant it observes is real (production mutates its token the same way), so the guard is the right control and only needs its pin.

### W ("re-parse instead of in-place") is unreachable under the allow-list: claim **holds**
Every argument reaching the shortcut is a `Literal` passed to `hasAuthority`/`hasAnyAuthority`/`hasRole`/`hasAnyRole` (String parameters), so SpEL converts it to a String. Probe, principal holding authorities `10`, `it's`, `1.0`, `16`:
```
hasAuthority(10L)             print hasAuthority(10)             orig=true reparsed=true
hasAuthority('it''s')         print hasAuthority('it''s')        orig=true reparsed=true
hasAuthority(1.0f)            print hasAuthority(1.0)            orig=true reparsed=true
hasAuthority(0x10)            print hasAuthority(16)             orig=true reparsed=true
hasAnyAuthority("it's", 'x')  print hasAnyAuthority('it''s','x') orig=true reparsed=true
```
The suffix and radix are lost in print, but the String value after conversion is identical. The only divergence is a long literal beyond int range (`hasAuthority(9999999999L)` prints `9999999999`). That makes a re-parse **throw** (`parseExpression` sits outside the try), which errors the test loudly rather than misjudging. The comment's wording ("re-parses identically") is slightly loose: the *value* is identical, the literal type is not. Not a finding.

### Is the allow-list itself sound (test FALSE but production TRUE for a PURE_ROOT_CHECKS call with literal args)?
- **Role prefix / hierarchy: sound.** `hasRole`/`hasAnyRole` read `defaultRolePrefix` ("ROLE_") and `roleHierarchy` from the handler. The test takes the production bean from `AnnotationConfigApplicationContext(MethodSecurityConfig.class)`. Re-review 1 found no `RoleHierarchy`/`GrantedAuthorityDefaults` in compiled classes, and `PrePostMethodSecurityConfiguration` would not apply one to a user-supplied handler anyway. Identical.
- **`isRememberMe()`: sound for this app.** It is FALSE for both test principals, so a conjunct using it is judged as a deny. Production is FALSE too: `git grep -i rememberMe src/main` finds 0, so no `RememberMeAuthenticationToken` is ever created.
- **`isAuthenticated()` / `isFullyAuthenticated()` / `isAnonymous()`:** these depend on the token **type** and its `authenticated` flag, not only on authorities. With fresh tokens that is faithful to production's un-mutated principal. The mutation case is F1c, handled by the guard.
- **Sample-principal depth limit (INFO, already stated for check 4):** "FALSE for every must-deny principal" means FALSE for **`{wms_user}` and anonymous**, not for every non-admin in production. `hasAuthority('wms_admin') and #id != null` is judged by the shortcut and passes, yet grants every `wms_admin` holder with an id. Check 4 has exactly the same limit ("cannot tell sb_admin from any other elevated authority"). The shortcut inherits it rather than widening it, and `MethodSecurityEnablementContractTest`'s exact-value pins (now recommended in the unjudged message) are the control for named sites. The inline comment "the left conjunct alone denies every non-admin" should read "...denies the sampled non-admin principals (wms_user, anonymous)", to match the class javadoc.

### Mutant spot-check (reasoning only, not re-run)
- U (allow-list removed): `constructorConjunct`, `typeReferenceConjunct` and `sideEffectConjunct` would be judged instead of unjudged, so `hasSize(10)` goes red. **Killed: credible.**
- V (grantObserved forced false everywhere): `sideEffectConjunct` and `placeholderEquality` lose "GRANTED". **Killed: credible.** V′ (shortcut predicate only) survives: F1c.
- S/T/R/N/P: unchanged since Re-review 4 and still pinned by the same fixtures. **Credible.**

### Re-review 5 verdict
- F1a **FIXED**. F1b **FIXED in effect**: fresh principals and the wording pin are correct. One LOW remains (F1c): the guard's shortcut-blocking role is reachable through a pure conjunct over a token the full evaluation mutated, the comment says it is not, and no fixture pins it. Fix: one fixture (the probe above) plus a comment correction.
- Production: unchanged and behaviour-neutral across all five rounds. The 13 live sites are all `hasAuthority('sb_admin')`, are judged conclusively, and are pinned by name.
- **Merge-ready from a security standpoint.** F1c is a guard-robustness Low on a contrived, author-written annotation shape that no live site uses. Per the address-Lows policy, add the fixture before merge if convenient.

### Re-review 5 checklist
- [x] No src/main change; tree left clean (`git status --short` empty)
- [x] Guard class 24/24 and contract test 18/18 green, run here
- [x] Allow-list blocks constructors, `T(...)`, `@bean`, reflection, setters and property reads
- [x] W unreachable: literal args agree in value after conversion
- [x] Role prefix/hierarchy and remember-me identical between test and production
- [ ] F1c: fixture pinning the guard's shortcut-blocking role; comment corrected
