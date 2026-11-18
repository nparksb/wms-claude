head: f44d1ce6a539a353af224c0686f7bf42d041c3c0

# SBDEV-4108: independent code review, round 4 (scoped to f44d1ce6)

Scope: `git show f44d1ce6` only (parent e1e52e29). Three test files changed: `HttpInTransactionArchTest.java`,
`TestClassTransactionManagerArchTest.java` and `StockunitServiceTransferStockPrintAfterCommitUnitTest.java`. Production code
is unchanged. The ticket worktree had 0 dirty paths before and after this review, and HEAD did not move.

Evidence comes from a detached worktree at `/private/tmp/sbdev4108-r4` (f44d1ce6, JDK 21.0.8, `mvn -o test`). It has since
been removed. Every mutant was restored from a saved copy, the probe class was deleted, and `git diff --quiet HEAD` was
clean before removal.

- **Green at the commit:** `HttpInTransactionArchTest` 3/3 (both production rules report **0 violations on main**),
  `TestClassTransactionManagerArchTest` 6/6, `StockunitServiceTransferStockPrintAfterCommitUnitTest` 7/7.
- **Main-tree census** (7159 methods). The HEAD predicate selects **282** and the parent predicate (copied verbatim)
  selects **282**, with **0** methods that differ. The raw name+arity hierarchy arm hits **0** methods on main. So the
  broader match cannot add a false positive or a violation on main today.
- **Predicate probe** on new fixtures:

  | Fixture | HEAD verdict | Spring at runtime | Correct? |
  |---|---|---|---|
  | `interface G2<A,B> { @Transactional op(A,B) }` ← `op(String,Integer)` | true (+ bridge true) | tx | yes (L1 closed for multi-param too) |
  | superclass `@Transactional op(int)` ← subclass overload `op(String)` | true | no tx | FP, documented as the same-arity overload blind spot |
  | superclass `@Transactional op(int)` ← subclass `static op(long)` | false | no tx | yes |
  | superclass `@Transactional private p()` ← subclass **public** `p()` | **true** | no tx | FP (N4) |
  | superclass `@Transactional static s(long)` ← subclass public `s(int)` | true | no tx | FP, covered by the overload line |
  | interface `@Transactional(NOT_SUPPORTED) op()` ← impl in a class with class-level `@Transactional` | **true** | no tx | FP (N3; this is r3 N1's second case) |
  | the interface method itself (`NsC.op()`) | false | no tx | yes |

- **Mutation checks** (each run alone, file restored after each):

  | Mutant | Result |
  |---|---|
  | drop the subject-side `PRIVATE` guard | RED at `:273` (`noneSatisfy ... hidden()`) |
  | drop the subject-side `STATIC` guard | **GREEN, survives** (N1) |
  | drop `&& !isNonTransactional(m)` in the hierarchy arm | RED at `:272` (`noneSatisfy ... notSupportedOp()`) |
  | drop the arity filter (name only) | **GREEN, survives** (N2) |
  | arity → exact raw parameter types (the r3 behaviour) | RED (`anySatisfy ... ImplementsGenericTxContract.op()`) |
  | FacadeException WARN loses the `e.getMessage()` reason | RED at `:229` |
  | FacadeException WARN also passes `e` (duplicate stack) | RED at `:234` |

## Verdict: APPROVE

**Counts: High 0 · Medium 0 · Low 0 · Nit 5**

Both r3 Lows are closed and pinned by mutants that fail on the right line. Each r3 Nit is closed or is now a documented,
fail-closed remainder. Both production rules are green on main with 0 violations and the selection set is unchanged
(282 = 282). All five Nits are fail-closed or wording issues with 0 instances on main.

## (1) r3 findings: closure status

| r3 | Status | Evidence |
|---|---|---|
| L1 generic override fails open | **Closed** | The name+arity match selects `op(String)` for `op(T)`, and also `op(String,Integer)` for `op(A,B)` (probe). The exact-types mutant goes RED. The over-match it introduces is listed in the blind-spot comment (`:144-146`) and the predicate comment (`:168-173`), and fails closed. |
| L2 WARN content unpinned | **Closed** | `.contains("CUPS refused the job")` and `allSatisfy(getThrowableProxy() isNull)`. Both r3 surviving mutants are now RED. `allSatisfy` cannot pass vacuously because the preceding `anySatisfy` requires at least one element. See N5 for the `.as()` wording. |
| N1 supertype-method NOT_SUPPORTED/NEVER | **Closed for the plain-impl case** | The `notSupportedOp` fixture and its mutant go RED at `:272`. The exemption entry in `TestClassTransactionManagerArchTest:194-195` keeps that rail green. Still open, and not listed: the same case when the impl class has class-level `@Transactional` (N3). |
| N2 superclass half unpinned | **Closed** | `MethodLevelTxBase`/`OverridesMethodLevelTxBase.op()` is flagged. The superclass half of the concat now has a fixture that only it can satisfy, because neither class is class-level transactional. |
| N3 private/static via the hierarchy | **Closed on the subject side** | Subject-side `PRIVATE` is pinned and `STATIC` is not (N1). The supertype side is not filtered (N4). |
| N4 out-of-repo path | **Closed** | The comment now names the ticket and the IT class. ClickUp comment 90110287921220 on [SBDEV-4108](https://app.clickup.com/t/868mv915x) records the instrument, the output line `afterCommit[closed=false alive=true]`, the control and the limit. Boundary-map §6 (`:178-191`, Verification Log `:460`) carries it too. The boundary map is also in sbdocs (not in git), but the ticket alone makes the comment resolvable. |
| N5 rollBack() snapshot | **Closed** | beforeCompletion iterates a fresh read. The list for afterCompletion is read after beforeCompletion and before `clearSynchronization()`, which matches `triggerAfterCompletion` in `processRollback`. Spring's exception swallowing is still not mirrored, and the commit does not claim it. |

## (2) Specific questions

- **Name+arity hierarchy match: new defects?** None that fail open. On main it adds 0 selections and 0 raw hits, and both
  rules report 0 violations. The defects it adds are all over-selection (fails closed): same-arity overloads (documented),
  a private/static supertype method matched by a public subtype method (N4), and the NS-interface method plus
  class-level-tx impl case (N3). `getMethods()` on each supertype returns declared methods only (consistent with r3's
  `tryGetMethod` finding). Iterating `getAllRawSuperclasses` + `getAllRawInterfaces` therefore covers the hierarchy.
  Interface default methods are not declared on the implementing class, so nothing is double-counted.
- **Arch rules on main:** `transactionalMethodsMustNotCallHttpRestService` and `transactionalMethodsMustNotCallCupsOrKeycloak`
  both pass, with **0 violations**.
- **Private-method fixture.** It is legal Java (JLS 8.4.8: private members are not inherited, so `Sub.hidden()` declares
  a new method and has no `@Override`. It compiles, which the green run proves). It tests what it says: `hidden()` in
  the subclass is reachable only through the hierarchy arm (neither class is class-level transactional), and dropping
  the `PRIVATE` guard turns `:273` RED. The fixture pins the **subject** side only. Its Javadoc ("Shares hidden()'s name
  and arity ... but is private: never proxied, not selected") is accurate.
- **`hasSize(12)` and the bridge.** The violation message uses `getName() + "()"`, so `op(String)` reports as
  `ImplementsGenericTxContract.op()`. The bridge `op(Object)` is selected, but it calls only `op(String)` and emits
  nothing. 10 + generic + superclass override = 12. The comment at `:275-276` is correct.
- **Log assertions.** Both are correct and mutation-proven. The test's `.as()` text is wrong for its own scenario (N5).

## (3) New findings

### [NIT] N1. The STATIC guard is unpinned, and the commit message says every new arm was mutation-checked
File: `src/test/java/net/aim_ai/wms/unit/config/HttpInTransactionArchTest.java:175`
Confidence: HIGH (mutant survives)
Replacing `!method.getModifiers().contains(JavaModifier.STATIC)` with `true` stays green. No fixture has a static subject
method that shares a name and arity with a transactional supertype method. The guard fails closed if removed. The commit
line "Every new arm was mutation-checked: each mutant fails the control" overclaims for this arm.
Fix: Add a `static void hidden2()`-style fixture (static in the subclass, transactional same-name in the base, calling
`cupsPrint`) with a `noneSatisfy`. Or drop "every" from the claim.

### [NIT] N2. The arity filter is unpinned
File: `HttpInTransactionArchTest.java:180`
Confidence: HIGH (mutant survives)
Matching by name alone stays green. It would only over-select further (fails closed), so this is precision, not safety.
Fix (optional): Add a fixture with a different-arity overload of a transactional supertype method that prints, expected
`noneSatisfy`.

### [NIT] N3. r3 N1's second case is still flagged and is not listed as a blind spot
File: `HttpInTransactionArchTest.java:186-188` (the class-level fall-through); blind-spot list `:141-146`
Confidence: HIGH (probed)
An interface method `@Transactional(NOT_SUPPORTED)` with an impl whose class carries `@Transactional` is selected: the
hierarchy arm declines, then the class-level arm returns true. Spring's `findMergedAnnotation` on the method finds the
interface method's NOT_SUPPORTED before it consults the class, so no transaction opens. This fails closed, with 0 on
main. The commit's N1 line ("no longer selects its implementation") is true only when the impl class is not itself
transactional.
Fix: Return false from the hierarchy arm's NS/NEVER hit before the class arm runs: find the first matching supertype
method and, if `isNonTransactional`, return false. Or add the case to the over-strict list.

### [NIT] N4. A private or static SUPERTYPE method still selects a public subtype method
File: `HttpInTransactionArchTest.java:179-181`
Confidence: HIGH (probed: `PrivBase @Transactional private p()` ← `PubSub public p()` → true)
The guard filters only the subject. A private or static supertype method is never overridden, so it cannot make a
subtype method transactional. This fails closed, with 0 on main. The commit's N3 line reads as if both sides were handled.
Fix: Add `.filter(m -> !m.getModifiers().contains(PRIVATE) && !m.getModifiers().contains(STATIC))` on the supertype
stream, or reword to "a private or static method is not selected".

### [NIT] N5. The L2 assertion's `.as()` text, and the commit message, say PrintService logged an ERROR in a scenario where it did not
File: `src/test/java/net/aim_ai/wms/unit/service/StockunitServiceTransferStockPrintAfterCommitUnitTest.java:235`; commit body L2
Confidence: HIGH
The test simulates `new FacadeException("CUPS refused the job")` with a mocked PrintService. PrintService logs at ERROR
only for transport failures (`PrintService.java:171`). A refusal goes through `assertPrintAccepted` with no ERROR.
The production comment (`StockunitService.java:912-913`) states this correctly: "a transport failure's stack ... a
refused job has no stack". The test's `.as()` and the commit's "(PrintService already logged it at ERROR)" do not.
Fix: `.as("no stack trace on the FacadeException WARN: a transport failure's stack is already logged at ERROR by PrintService, a refusal has none")`.

## (4) Commit message accuracy

Accurate, with three overclaims:
- "Every new arm was mutation-checked: each mutant fails the control": the STATIC guard and the arity filter survive (N1, N2).
- N1 "no longer selects its implementation": not when the impl class is class-level transactional (N3).
- L2 "(PrintService already logged it at ERROR)": true for transport failures, not for the refusal the test simulates (N5).
- Everything else is accurate: L1 (including "an unrelated same-arity overload also matches, listed as a strict-side
  blind spot"), N2, N3 (subject side), N4 and N5.

## Positive observations
- The NS/NEVER test was extracted into `isNonTransactional` and reused on both sides, so the subject check and the
  supertype check cannot drift apart.
- The trade-off was made in the right direction: L1 was the only fail-open gap, and it was closed by accepting
  documented fail-closed over-match. The predicate comment explains why exact-type lookup lands on the bridge.
- Mutants fail on the `noneSatisfy`/`anySatisfy` line that names the fixture, as the commit says, so a red is diagnosable.
- The `hasSize(12)` comment spells out the bridge accounting rather than leaving a magic number.
- `notSupportedOp` was registered in the `TestClassTransactionManagerArchTest` exemption list in the same commit, so that
  rail stayed green.

## Recommendation
**APPROVE.** No High, Medium or Low. Per standing policy the five Nits can be closed in one small pass. N1 and N5 are
one fixture and one string, N4 is one filter, and N3 is a short-circuit or a blind-spot line. None blocks.
