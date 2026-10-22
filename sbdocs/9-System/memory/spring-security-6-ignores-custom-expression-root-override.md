---
name: spring-security-6-ignores-custom-expression-root-override
description: "Under @EnableMethodSecurity, overriding createSecurityExpressionRoot(Authentication, MI) does nothing — the Supplier path uses a PRIVATE root factory; wms2's custom root was dead since 2025-09-20"
metadata:
  node_type: memory
  type: project
  originSessionId: 979cbe0e-12e0-40b1-af5d-de870ab4cdc5
  modified: 2026-10-14T18:52:34.434Z
---

Spring Security 6 (`@EnableMethodSecurity`) evaluates `@Pre/PostAuthorize` and `@Pre/PostFilter` through
`createEvaluationContext(Supplier<Authentication>, MethodInvocation)`. Verified with `javap` on 6.1.0 and 6.5.7.
On `DefaultMethodSecurityExpressionHandler`, that overload builds its root in a **private** method that
hard-codes `new MethodSecurityExpressionRoot` with the `ROLE_` prefix. A subclass overriding the protected
`createSecurityExpressionRoot(Authentication, MI)` is **never consulted**. Only the legacy
`@EnableGlobalMethodSecurity` advice used the 2-arg path.

In wms2-api this meant `CustomMethodSecurityExpressionRoot` (`isAimAdmin()`, `hasDetail`, a null prefix) was
dead from `bd330a3a` (2025-09-20, the Keycloak 26 / `@EnableMethodSecurity` migration) onward. Its tests passed
because they called the 2-arg overload directly. So **SBDEV-2863's 500s started 2025-09-20, not 2025-10-29**:
`ded4d644` turned one unresolvable expression into another. SBDEV-2872 deleted the custom root/handler,
corrected the dates in `Authority`, `UserAdministrationController` and the role matrix, and added
`MethodSecurityExpressionsResolveArchTest`.

**Why:** a test that evaluates SpEL through the 2-arg overload grades a root production never builds. It
false-greens `"isAimAdmin()"`, and it asserted `hasRole('sb_admin')` is TRUE when production says FALSE.

**How to apply:** any security-expression test must call `createEvaluationContext(() -> auth, mi)` on the
bean returned by `MethodSecurityConfig`. Never construct a root by hand. A "custom root" needs an override of
the Supplier overload itself. Related: [[green-tests-that-prove-nothing]],
[[a-guard-fences-the-mechanism-you-aimed-at]], [[sb-admin-is-siteboss-super-admin-via-groups-claim]].
