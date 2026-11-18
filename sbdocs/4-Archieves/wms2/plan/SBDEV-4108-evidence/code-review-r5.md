head: a38fc62ac1713fc7d539baff99f4373c0de13710

# SBDEV-4108 code review, round 5 (scoped to the tip commit only)

Scope: `git show a38fc62a`. It is test-only and touches 2 files (+16/-2). It closes the r4 Nits N1, N3, N4 and N5, and leaves N2 as is.

## Evidence
- Baseline: in the temp worktree `/private/tmp/sbdev4108-r5` (detached at HEAD, JDK 21), `mvn -q clean test -Dtest=HttpInTransactionArchTest` ran 3 tests with 0 failures.
- STATIC-guard mutant (`&& !method.getModifiers().contains(JavaModifier.STATIC)` changed to `&& true`): RED at `HttpInTransactionArchTest.java:277`, which is the new `noneSatisfy(... "OverridesMethodLevelTxBase.hiddenStatic(")` line. The violation reads `OverridesMethodLevelTxBase.hiddenStatic() runs in a transaction and calls PrintService.cupsPrint()`. The r4 N1 mutant is now killed, and it fails at the line the commit message names.
- The temp worktree was removed afterwards. The ticket worktree was not touched.

## Answers
- **Does the fixture exercise the STATIC exclusion?** Yes. Name and arity match: the base has `private hiddenStatic(PrintService)` (arity 1, `@Transactional`) and the subclass has `static hiddenStatic(PrintService)`. Neither class is class-level `@Transactional`, so the hierarchy arm is the only way to reach the method. The subject is package-private, not private, so the PRIVATE guard cannot stand in for the STATIC one. The mutant result above proves this.
- **Is it legal Java?** Yes. The base method is private, so it is not inherited (JLS 8.4.8), and the static subclass method neither hides nor overrides it. A non-private *instance* base method with the same signature would not compile ("static method cannot hide instance method"), so making the base method private is the necessary choice. The green baseline compile confirms it.
- **Are the comment additions accurate?** Yes, in substance. The N3 text (a NOT_SUPPORTED supertype method under a class-level `@Transactional` implementer) and the N4 text (a private or static supertype method still selects; only the subclass side is filtered) both match the code at `:177-188`. One small imprecision: see L1.
- **Is the N2 decision reasonable?** Yes. Removing the arity filter only over-selects, so it fails closed. The comment at `:171-175` states the name + arity match. Pinning it would buy precision, not safety.
- **Is the commit message accurate?** Yes. N1's claim "mutant fails at the fixture's assertion line" is verified at `:277`. The N3/N4, N5 and N2 lines describe the diff correctly. The new `.as()` text matches the production comment cited in r4 (`StockunitService.java:912-913`).

## Findings
### [NIT] L1. The blind-spot wording says "same-named public method"
File: `HttpInTransactionArchTest.java:148-149`. Confidence: HIGH.
The rule matches any non-private, non-static subclass method with the same name **and arity**, package-private included. "Same-named public method" is narrower than what the code does.
Fix (optional): say "a same-named, same-arity non-private, non-static method in a subclass".

### [NIT] L2. The static fixture's kill depends on N4 staying unfixed
File: `HttpInTransactionArchTest.java:468-471`. Confidence: HIGH (by reading the code).
The base method is private. If someone later applies r4 N4's suggested fix (filter private/static on the supertype stream), the base method stops matching, the STATIC-guard mutant survives again, and the `noneSatisfy` at `:277` passes vacuously. The `hidden()` fixture has the same coupling for the PRIVATE guard.
Fix (optional): use a non-private instance base method with the same arity but a different parameter type, for example `@Transactional void hiddenStatic(Object)` alongside the subclass's `static hiddenStatic(PrintService)`. That is a legal overload and keeps the guard pinned even after N4 is fixed. Alternatively, add a one-line comment tying the fixture to the N4 behaviour.

## Counts
High 0 · Medium 0 · Low 0 · Nit 2

## Verdict: APPROVE
