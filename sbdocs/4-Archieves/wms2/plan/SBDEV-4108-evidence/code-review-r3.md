head: e1e52e29

# SBDEV-4108: independent code review, round 3 (scoped to e1e52e29)

Reviewed: `git show e1e52e29` only (4 files: `StockunitService.java`, `HttpInTransactionArchTest.java`,
`TestClassTransactionManagerArchTest.java`, `StockunitServiceTransferStockPrintAfterCommitUnitTest.java`), against the
findings in `code-review-r2.md` (head 3c3aa0b4). I did not touch the ticket worktree and did not run mvn in it. It
reported 0 dirty paths before and after this review.

Evidence comes from a detached worktree at `/private/tmp/sbdev4108-r3` (e1e52e29, JDK 21.0.8, `mvn -o test`). It has
since been removed. Every mutant was restored from a saved copy, and the probe class was deleted before removal.
- **Green at the commit:** `HttpInTransactionArchTest` 3/3 (both production rules: **0 violations on main**),
  `StockunitServiceTransferStockPrintAfterCommitUnitTest` 7/7.
  `TestClassTransactionManagerArchTest` went red only on my own probe fixtures (`R3ProbeTest$ImplNotSupported#op`,
  `R3ProbeTest$NsContract#op`), which is the rail working as designed.
- **Main-tree census** of OPEN_A_TRANSACTION. It selects **282** methods, the same as r2. The new method-hierarchy arm
  selects **0** methods that the other arms did not already select. **0** external (non-`net.aim_ai`) supertypes produce a
  hierarchy hit. The new arm therefore cannot add a false positive on main today. ArchUnit 1.3.0 `tryGetMethod` searches
  **declared methods only**: `SubNoOverride.tryGetMethod("op","int")` was empty while `Base` declares it. Iterating every
  supertype is therefore the right shape.
- **Predicate probe** on new fixtures:

  | Fixture | Verdict | Spring at runtime | Correct? |
  |---|---|---|---|
  | interface `@Transactional void op()` ← impl `op()` NOT_SUPPORTED | **false** | no tx (impl method wins) | yes |
  | `interface G<T> { @Transactional void op(T) }` ← `implements G<String>`, `op(String)` | **false** | tx (Spring resolves generic overrides) | **FN** (L1) |
  | ...same, the synthetic bridge `op(Object)` | true | (bridge only delegates) | harmless |
  | covariant return `Object get()` → `String get()`, plus its bridge | true / true | tx | yes |
  | interface method `@Transactional(NOT_SUPPORTED)` ← plain impl | **true** | no tx | **FP** (N1) |
  | ...same, impl class carries class-level `@Transactional` | **true** | no tx (method hierarchy beats class) | **FP** (N1) |
  | superclass `@Transactional op(int)` ← override `op(int)` / overload `op(long)` | true / false | tx / no | yes |
  | superclass `@Transactional` private `priv()` / static `st()` ← same-signature private/static in subclass | true / true | neither proxied | FP (N3) |

- **Mutation checks**:

  | Mutant | Result |
  |---|---|
  | new hierarchy arm returns false | RED (control) |
  | hierarchy arm reads interfaces only (drop `getAllRawSuperclasses` from the concat) | **GREEN, survives** (N2) |
  | drop the interface TYPE arm | RED (control) |
  | drop the `NEVER` exclusion | RED (control) |
  | RuntimeException WARN drops `e` | RED |
  | FacadeException WARN drops the `: {}` reason | **GREEN, survives** (L2) |
  | FacadeException WARN passes `e` (re-introduces the duplicate stack r2 N2 removed) | **GREEN, survives** (L2) |

- **B evidence.** `partB-measurement.md` and `partB-probe-...IT.java.txt` agree. The output shows the failing line `:111`,
  which matches the probe source's `isTrue()` on `closedInAfterCommit`. `closed=false alive=true` inside afterCommit, with
  the positive control `closed=false alive=true` inside the tx. Production uses the same tenant EMF with a bare
  `HibernateJpaVendorAdapter` (`TenantDatabaseConfig:110`), and nothing in main overrides
  `hibernate.connection.handling_mode`. Spring's adapter therefore sets DELAYED_ACQUISITION_AND_HOLD, and the connection
  is released in `doCleanupAfterCompletion`, after afterCommit. HELD applies to production, as the file's "Limit" line
  argues. One oddity: the probe's assertion `.as(...)` text states the *finding* ("is still checked out") on an
  assertion that expects the opposite. That is intentional for a red-by-design probe, but it reads backwards.

## Verdict: APPROVE

**Counts: High 0 · Medium 0 · Low 2 · Nit 5**

All eight r2 findings are closed, and both production rules are green on main with 0 violations. The new arm is safe on
main: it adds 0 selections and 0 FPs. The two Lows are an unhandled generic-override false negative (fails open, latent,
0 instances on main) and an unpinned log detail. Per standing policy, fix them in the same pass. Neither blocks.

## (1) r2 findings: closure status

| r2 | Status | Evidence |
|---|---|---|
| L1 interface arm unpinned / method-level not read | **Closed**, with the new gaps in L1/N1/N2 below | `TypeLevelTxContract` fixture: the type-arm mutant goes RED. `MethodLevelTxContract.op()` is flagged and `untransactionalOp()` is not. The hierarchy-arm mutant goes RED. The comment `:113-118` now describes the method hierarchy. |
| L2 Part B cited, HttpRestService because() | **Closed** | `:142-148` cites the evidence path. `because()` `:83-89` no longer offers after-commit as a connection fix and says it "releases the locks but NOT the connection". It is consistent with the CUPS rule's because(), which claims row locks only. The evidence is accurate (above). See N4 on where the path points. |
| N1 commit() fidelity | **Closed** (both claimed parts) | Re-read per phase, and afterCompletion in a `finally`. This now matches `processCommit`'s `try { triggerAfterCommit } finally { triggerAfterCompletion }`. Spring's swallowing of before/afterCompletion exceptions is still not mirrored. The commit did not claim it. See N5. |
| N2 duplicate stack | **Closed in code, unpinned** | The split catch is correct. See L2. |
| N3 over-strict cases listed | **Closed** | `:139-143` lists the private/static/self-invoked, class-level NOT_SUPPORTED and meta-carried cases. It does not list the new supertype-method case (N1). |
| N4 NEVER arm | **Closed** | `printsUnderNever` fixture plus `EXEMPT_NON_TRANSACTIONAL` entry (`TestClassTransactionManagerArchTest:192-193`). The mutant goes RED. |
| N5 "committed" wording | **Closed** | "label print failed after a stock transfer (the transfer stands)". Accurate in both branches, because the helper is the last statement of the print block (`StockunitService:884`) and nothing after it can throw. |
| N6 rationale | **Closed** (no code change, rationale now answers the real alternative) | It matches r2's own analysis. |

## (2) New findings

### [LOW] L1. The method-hierarchy arm misses overrides of generic supertype methods (fails open)
File: `src/test/java/net/aim_ai/wms/unit/config/HttpInTransactionArchTest.java:167-172`
Confidence: HIGH (probed)
Issue: `tryGetMethod(name, rawParamsOfTheOverride)` compares erased parameter types. For
`interface Contract<T> { @Transactional void op(T t); }` implemented as `op(String)`, the supertype declares `op(Object)`.
The lookup misses, and the real method is **not selected**. The compiler's bridge `op(Object)` *is* selected, but it only
delegates, so a CUPS/Keycloak/HttpRestService call in `op(String)` passes the rule. Spring's `AnnotatedElementUtils`
(TYPE_HIERARCHY search) resolves generic overrides, so the method is transactional at runtime. The commit message's "as
Spring resolves it" overclaims. This is latent: the census found 0 hierarchy-only selections on main, so no generic
`@Transactional` interface method exists today. It is the only gap in this rule that fails **open**.
Fix (either):
(a) When the owner has a bridge method with the same name that the arm selects, also select the non-bridge method that
the bridge calls. In ArchUnit, find the bridge's single `getMethodCallsFromSelf()` target in the same owner.
(b) Add one line to the blind-spot list: "method-level @Transactional on a GENERIC supertype method is not matched to its
parameterised override". (b) costs nothing and is honest. (a) closes the gap.

### [LOW] L2. The FacadeException WARN's new content is unpinned
File: `src/main/java/net/aim_ai/wms/service/StockunitService.java:911-915`; test
`StockunitServiceTransferStockPrintAfterCommitUnitTest.java:227-231`
Confidence: HIGH (two surviving mutants)
Issue: The split catch was the N2 fix, but nothing protects it. (i) Dropping `: {}` / `e.getMessage()` stays green. For a
**refused** job (`cupsPrintChecked` → `assertPrintAccepted`, no cause, and PrintService logs refusals only at DEBUG per
r1 L4), that reason is now the only WARN-level diagnostic. (ii) Passing `e` again, which brings back the duplicate stack,
also stays green. The existing assertions are still meaningful: they pin the prefix, `unitLoad=2` and the printer, and
the RuntimeException test pins the throwable. They just do not cover what this commit changed.
Fix: In `transferStock_shouldNotThrowAndShouldWarn_whenCupsPrintFails`, add `.contains("CUPS refused the job")` to the
formatted-message assertion and `assertThat(e.getThrowableProxy()).isNull()`.

### [NIT] N1. A NOT_SUPPORTED/NEVER on the supertype METHOD is treated as "opens a transaction"
File: `HttpInTransactionArchTest.java:167-172`; blind-spot list `:139-143`
The hierarchy arm returns true for any `@Transactional` on the supertype method, whatever its propagation. In the probe,
an interface method `@Transactional(NOT_SUPPORTED)` with a plain impl is flagged, even when the impl class carries
class-level `@Transactional`. Spring reads the method hierarchy before the class, so neither runs in a transaction. This
fails closed, and there are 0 instances on main. The new "only a DIRECT @Transactional propagation is read" wording
implies it but does not list it.
Fix: Map the found method through the same propagation test (`tryGetAnnotationOfType(...).map(not NS/NEVER)`), or list
the case as a blind spot.

### [NIT] N2. The superclass half of the hierarchy arm is unpinned
File: `HttpInTransactionArchTest.java:168`
Replacing the `Stream.concat(superclasses, interfaces)` with interfaces alone stays green. The commit message says
"interface or overridden superclass method", but only the interface case has a fixture. `InheritsClassLevelTransactional`
is caught by the class-level arm first.
Fix: Add a fixture of a superclass with a method-level `@Transactional op()` and an unannotated subclass override that
prints, expected flagged. Bump `hasSize` to 11.

### [NIT] N3. A same-signature private/static method in a subclass is selected through the hierarchy arm
File: `HttpInTransactionArchTest.java:167-172`
Probe: `Sub.priv()` / `Sub.st()` are selected because `Base` declares `@Transactional` private/static methods with the
same signature. They neither override nor get proxied. The blind-spot line ("private, static and self-invoked methods of
a transactional class") nearly covers this, but here the subclass is not itself transactional. It fails closed, and
there are 0 on main. Optional fix: skip `m` when either side is private or static.

### [NIT] N4. The code comment cites a path outside every git repository
File: `HttpInTransactionArchTest.java:147-148`
`sbdocs/` is a local vault, not in git, so a clone of wms2-api (CI, another developer) cannot follow
`sbdocs/1-Projects/.../partB-measurement.md`. r2 offered this option, so this is a nit. Optional fix: add the ticket ID
next to the path ("SBDEV-4108, evidence partB-measurement.md") so it is resolvable from ClickUp as well, or paste the
one-line result (`afterCommit[closed=false alive=true]`) into the comment.

### [NIT] N5. rollBack() still takes one snapshot, and commit() does not mirror Spring's exception swallowing
File: `StockunitServiceTransferStockPrintAfterCommitUnitTest.java:358-363`
`commit()` now re-reads per phase, but `rollBack()` still reuses one list across beforeCompletion and afterCompletion.
Spring's `processRollback` re-reads in `triggerAfterCompletion`. In the commit `finally`, an exception from afterCompletion
would mask one from afterCommit, where Spring logs and swallows afterCompletion failures. Today's single callback cannot
see either difference. `remaining` is also an odd name for "the list afterCommit runs over". Optional.

## (3) Specific questions

- **Can `tryGetMethod` on a supertype false-positive on main?** No. It adds 0 selections on main and hits 0 external
  supertypes, and both rules report 0 violations. In principle it can over-select (N1, N3), and both of those fail
  closed.
- **Generic or bridge methods?** Generic overrides: **no** (L1, fails open). Bridges: yes, they are selected, but they
  only delegate, so the effect is nil. Covariant returns: matched correctly, because parameters are compared and the
  return type is not.
- **Does impl NOT_SUPPORTED beat interface REQUIRED?** Yes. The direct-propagation exclusion (`:155-160`) runs before the
  hierarchy arm. The probe returned `false`, which matches Spring (most specific method first).
- **Split catch and log wording.** The code is correct, and the wording is accurate in both the tx and no-tx branches.
  The assertions are still meaningful but do not pin the change (L2).
- **commit()/finally helper.** It is correct against `processCommit`. See N5 for the remainder.
- **Evidence file and probe source.** Both are accurate and agree with each other. HELD transfers to production (see
  Evidence).

## (4) Commit message accuracy

Accurate, with two overclaims:
- L1 "as Spring resolves it": not for generic overrides (L1) or supertype-method propagation (N1).
- L1 "fixtures ... pin both arms": true for interface TYPE and interface METHOD. The superclass-method half is not pinned
  (N2).
- N2: true in code, but not under test (L2).
- L2, N1, N3, N4, N5, N6: accurate.

## Positive observations
- The NOT_SUPPORTED exclusion stays first, so the most-specific-method precedence is right by construction.
- The `untransactionalOp()` negative fixture proves the method-level arm is per-method rather than per-interface. That is
  exactly the case a type-level shortcut would have got wrong.
- The HttpRestService `because()` now gives correct remediation advice, and it is consistent with the measured B result
  and the CUPS rule.
- `printsUnderNever` was registered in `EXEMPT_NON_TRANSACTIONAL` in the same commit, so the rail stayed green.
- The Part B evidence is reproducible: the command, the source, the raw output, a positive control and a stated limit.

## Recommendation
**APPROVE.** Fix L1 (at minimum the blind-spot line) and L2 (two assertions) per standing policy. The Nits are optional.
