---
name: archunit-lambda-calls-attributed-to-enclosing-method
description: "ArchUnit 1.3 attributes a LAMBDA body's calls to the declaring method (anonymous classes are separate); method refs are not calls"
metadata:
  node_type: memory
  type: reference
  originSessionId: 13e35dc8-e608-4d1f-a2e2-c3bd698308ff
  modified: 2026-11-11T11:54:45.784Z
---

ArchUnit 1.3.0 behaviour, measured on JDK 21 (SBDEV-4108 review r1):
- `getMethodCallsFromSelf()` **includes** the calls inside a lambda declared in that method. ArchUnit does not import `lambda$…` synthetics as separate members.
- An **anonymous class** body is a separate member, and its calls are NOT seen from the enclosing method.
- A **method reference** (`svc::m`) is a `JavaMethodReference`, not a call. Read `getMethodReferencesFromSelf()` as well, or it is invisible.
- `areDeclaredInClassesThat().areMetaAnnotatedWith(X)` does **not** follow `@Inherited` to subclasses. Walk `getAllRawSuperclasses()`/`getAllRawInterfaces()` yourself.
- `tryGetMethod(name, exactRawTypes)` on a generic supertype lands on the **bridge** method. Match by name + arity instead.

**Why:** both the architect consult and the rule's own comment stated the opposite about lambdas. The error failed closed, but the "sanctioned fix" guidance was wrong.

**How to apply:** for an "X must not be called inside @Transactional" rule, the after-commit callback must be an anonymous `TransactionSynchronization`, or a lambda in a non-transactional helper. Give every such rule's fixture control a lambda case and a method-reference case. See `HttpInTransactionArchTest`. Related: [[hub-scan-instruments-lie]].
