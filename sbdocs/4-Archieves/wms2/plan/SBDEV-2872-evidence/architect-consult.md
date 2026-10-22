# SBDEV-2872 — architect consult: swap CustomMethodSecurityExpressionHandler -> DefaultMethodSecurityExpressionHandler

## Verdict: SAFE-WITH-CAVEAT (production is behaviour-neutral; caveat is in TESTS and javadoc)

## 1. Production never reaches the 2-arg path
Every caller of `createEvaluationContext` that @EnableMethodSecurity wires (spring-security-core 6.5.7 sources):
- `PreAuthorizeAuthorizationManager.java:95,100` — `check(Supplier<Authentication> authentication, MethodInvocation mi)` -> `createEvaluationContext(authentication, mi)` (Supplier overload)
- `PostAuthorizeAuthorizationManager.java:103,109` — same, Supplier
- `PreFilterAuthorizationMethodInterceptor.java:150` / `PostFilterAuthorizationMethodInterceptor.java:150` — `createEvaluationContext(this::getAuthentication, mi)` (Supplier)
- `DefaultMethodSecurityExpressionHandler.java:84-85` Supplier overload -> PRIVATE `createSecurityExpressionRoot(Supplier, MI)` at :101-110, `new MethodSecurityExpressionRoot(authentication)` — unreachable from the subclass override.
Only remaining 2-arg callers in core: `AbstractSecurityExpressionHandler.java:71` (final, called by legacy `ExpressionBasedPre/PostInvocationAdvice` = @EnableGlobalMethodSecurity only), the Reactive* managers/interceptors (@EnableReactiveMethodSecurity only), `MethodExpressionAuthorizationManager.java:77` (only if user code constructs one), WebSocket XML parser.
App config: `MethodSecurityConfig.java` — `@EnableMethodSecurity(prePostEnabled = true, securedEnabled = false, jsr250Enabled = false)`.
- grep src/main for `EnableGlobalMethodSecurity|EnableReactiveMethodSecurity|GlobalMethodSecurityConfiguration|MethodSecurityExpressionHandler|SecurityExpressionHandler|createEvaluationContext|ExpressionUtils|AuthorizationManager|MethodInterceptor|Mono<|Flux<` -> hits ONLY in MethodSecurityConfig, CustomMethodSecurityExpressionHandler, Authority (javadoc). No bean injects the handler; no custom AuthorizationManager / MethodExpressionAuthorizationManager.
- Resolved classpath (`mvn -o dependency:list`): spring-security-{core,config,web,crypto,oauth2-*} only. NO spring-security-messaging, -acl, -data, -rsocket. (`spring-messaging` is present but is not security.) So no websocket/ACL/SDR-security path can pick the handler up.
- Spring Data REST: repository @PreAuthorize (if any) goes through the same AuthorizationManagerBeforeMethodInterceptor -> Supplier path. SDR itself never consults a MethodSecurityExpressionHandler.
- Web tier: a MethodSecurityExpressionHandler is `SecurityExpressionHandler<MethodInvocation>`; web authz needs `<RequestAuthorizationContext>`/FilterInvocation, and SecurityConfiguration uses `hasAnyAuthority(...)` not `.access(...)` (Authority.java:11-13 javadoc).

## 2. Evaluator / roleHierarchy / prefix / trustResolver on the Supplier path — identical before and after
Supplier root reads HANDLER fields (`DefaultMethodSecurityExpressionHandler.java:104-108`): `getPermissionEvaluator()`, `getTrustResolver()`, `getRoleHierarchy()`, `getDefaultRolePrefix()`.
- permissionEvaluator: both set `new CustomPermissionEvaluator()` — same.
- defaultRolePrefix: handler field `= "ROLE_"` (:69). Custom subclass never calls `setDefaultRolePrefix` on the HANDLER — its `root.setDefaultRolePrefix(null)` (CustomMethodSecurityExpressionHandler.java:19) is on the dead root. Before = after = "ROLE_".
- trustResolver: handler field `new AuthenticationTrustResolverImpl()` (:63). The subclass's own `private final AuthenticationTrustResolver trustResolver` is read only inside the dead override. Same.
- roleHierarchy: `PrePostMethodSecurityConfiguration.java:120-122` `@Autowired(required=false) setRoleHierarchy` applies to its INTERNAL handler (:89), not to a user bean; `setExpressionHandler` (:141-146) just swaps in the user bean. src/main declares no RoleHierarchy / GrantedAuthorityDefaults bean (grep: only the Custom handler mentions RoleHierarchy). Both default to the handler's built-in default. Same.
- beanResolver / ApplicationContext: both are beans subclassing AbstractSecurityExpressionHandler (ApplicationContextAware) — same.
- Only root-level delta that could matter: the default root also gets `setThis(...)` (:103) — already true today.
- Expressions in use: 22 sites, all `@PreAuthorize(Authority.IS_SB_ADMIN)` / `@PreAuthorize(IS_SB_ADMIN)` = `"hasAuthority('sb_admin')"` (core SecurityExpressionRoot method, prefix-independent). `hasDetail`/`isAimAdmin` referenced nowhere in src/main except their own class and Authority javadoc — and they are ALREADY unresolvable in prod (SBDEV-2863 history in Authority.java:35-41 is consistent with this).

## 3. CAVEAT (not production, but must be handled in the same change)
a) `CustomMethodSecurityExpressionRootUnitTest.java:333-335` `evaluate(...)` calls `handler.createEvaluationContext(authFor(user), invocation)` — the 2-ARG path. It is the ONLY live caller of the custom root, and it tests a configuration production never runs. Its claim at :455-460 ("The handler nulls the prefix, so the bare name matches ... hasRole ACCIDENTALLY equivalent") and the javadoc at :321-330 ("resolve here exactly as they do in production") are FALSE for production: there `hasRole('sb_admin')` checks `ROLE_sb_admin` and returns false. Any surviving helper must use the Supplier overload `createEvaluationContext(() -> auth, mi)` against the production bean, and the hasRole assertion flips to FALSE.
b) `MethodSecurityEnablementContractTest.java:195-215` asserts `isInstanceOf(CustomMethodSecurityExpressionHandler.class)` — must become DefaultMethodSecurityExpressionHandler (and keep :218-220 evaluator pin).
c) `Authority.java:25-28` javadoc ("unless the prefix is nulled — which CustomMethodSecurityExpressionHandler happens to do today, making the two accidentally equivalent") is false today and dangling after deletion; also :22 references `CustomMethodSecurityExpressionRoot#isAimAdmin`. Rewrite: hasRole is NOT equivalent in production.
d) sbdocs referencing the Custom* classes (wms2-keycloak-role-matrix.md, 260826 authz audit report, two memory files) — verify-docs drift.

## 4. Method behind each 'none'/'only' claim, and its blind spot
- "Production callers use the Supplier overload": read of 6.5.7 SOURCES jar. Blind spot: assumes the sources jar matches the binary jar on the runtime classpath (same GAV/version, so low risk); javap of the binary would close it.
- "No src/main caller/injector of the handler": regex source grep over src/main/java. Blind spot: reflection / getBean by string name, Kotlin/Groovy, generated sources, or a subtype reached via a supertype name not in the pattern (e.g. injecting `AbstractSecurityExpressionHandler`). A compiled-class constant-pool scan would close it.
- "No messaging/ACL/data security on classpath": `mvn -o dependency:list` (compile+runtime). Blind spot: jars added outside Maven, or a profile-activated dependency not in the default resolution.
- "No RoleHierarchy/GrantedAuthorityDefaults bean": src/main grep. Blind spot: an auto-configuration contributing one — Boot 3.5.9 auto-configures neither; irrelevant anyway since PrePost config does not apply them to a user-supplied handler (:115-123).
- "Only hasAuthority expressions": grep of `@(Pre|Post)(Authorize|Filter)(...)` in src/main. Blind spot: meta-annotations / templated @PreAuthorize on a custom annotation type; none surfaced but a descriptor scan was not run here.
Strongest counter-case considered: a reactive @PreAuthorize method (Mono return) — would only route to the 2-arg Reactive managers under @EnableReactiveMethodSecurity, which is absent; and no Mono/Flux in src/main.
