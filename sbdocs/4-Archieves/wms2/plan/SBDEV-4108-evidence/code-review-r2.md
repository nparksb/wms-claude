head: 3c3aa0b4

# SBDEV-4108: independent code review, round 2 (scoped to 3c3aa0b4)

Reviewed: `git show 3c3aa0b4` only (4 files: `StockunitService.java`, `HttpInTransactionArchTest.java`,
`TestClassTransactionManagerArchTest.java`, `StockunitServiceTransferStockPrintAfterCommitUnitTest.java`), against the
findings in `code-review-r1.md` (head eb46d10a). Read-only on the ticket worktree. That worktree was clean when I checked;
I did not run mvn in it.

Evidence, all from a detached worktree at `/private/tmp/sbdev4108-rr` (3c3aa0b4, JDK 21.0.8, `mvn -o test`). It has
since been removed.
- **Green at the commit:** `HttpInTransactionArchTest` 3/3, `StockunitServiceTransferStockPrintAfterCommitUnitTest` 7/7,
  `TestClassTransactionManagerArchTest` 6/6, `NeverMatcherNullBlindnessArchTest` 10/10.
- **Mutation checks.** Each mutant below was applied, run, and then restored from a saved copy:

  | Mutant | Result |
  |---|---|
  | drop `\| RuntimeException` | RED (RuntimeException test) |
  | guard on `isSynchronizationActive()` alone | RED (empty-tx test) |
  | drop `, e` from the WARN | RED (throwable assertion) |
  | delete the WARN | RED (2 tests) |
  | condition ignores method references | RED (control) |
  | remove the NOT_SUPPORTED/NEVER exclusion | RED (control) |
  | remove the superclass arm | RED (control) |
  | **remove the interface arm** | **GREEN, survives** (L1) |

- **Predicate probe.** `OPEN_A_TRANSACTION.test()` was run on hand-built fixtures:

  | Fixture | Verdict | Correct? |
  |---|---|---|
  | class `@Transactional` + method `@Transactional(NOT_SUPPORTED)` | **false** | yes |
  | class `@Transactional(NOT_SUPPORTED)` + plain method | **true** | FP |
  | class `@Transactional(NOT_SUPPORTED)` + method `@Transactional` (REQUIRED) | true | yes |
  | method annotated with a custom annotation meta-carrying `@Transactional(NOT_SUPPORTED)` | **true** | FP |
  | interface METHOD `@Transactional`, impl class and method unannotated | **false** | FN |
  | interface TYPE `@Transactional`: impl's interface method and an extra method | true / true | yes |
  | class `@TenantTransactional` + method `@Transactional(NEVER)` | false | yes |
  | class `@TenantTransactional` + static method | **true** | FP |
  | subclass of a class-level `@Transactional`: override and new method | true / true | yes |

- **Production coverage probe** (main classes only). 282 methods are selected (277 annotation lines in main, plus
  class-level ones). The matcher sees 203 call sites on PrintService/`cupsPrint*`, `Keycloak`, `RealmResource`,
  `UsersResource`, `UserResource`, `GroupsResource`, `GroupResource` and the 3 app wrappers. **0** of them are in a
  selected method. The narrowed Keycloak matcher therefore adds no false positive on main, and the rule is not vacuous on
  main.
- Spring source: `spring-tx-6.2.15-sources.jar` (the resolved version), `AbstractPlatformTransactionManager:767-1031`
  and `TransactionSynchronizationUtils:125-206`.

## Verdict: APPROVE

**Counts: High 0 · Medium 0 · Low 2 · Nit 6**

Every r1 finding that was meant to be closed is closed, and closed correctly. The mutation checks above confirm that each
new assertion protects what it claims to. Nothing here blocks the PR. L1 and L2 cost a few lines each, and per standing
policy should be fixed in the same pass.

## (1) r1 findings: closure status

| r1 | Status | Evidence |
|---|---|---|
| M1 lambda claim | **Closed** | Comment block `HttpInTransactionArchTest:127-133` and `because()` corrected. Fixture `printsInLambdaInTransaction` is asserted flagged. The production helper's lambda sits in private, non-transactional `printCaseLabelAfterCommit` (StockunitService has no class-level @Transactional), so it is correctly not flagged. |
| M2 RuntimeException arm | **Closed** | Test `transferStock_shouldNotThrow_whenPrintPathThrowsRuntimeException`. Dropping `\| RuntimeException` turns it red. |
| L1 printLabel=false | **Closed** | `transferStock_shouldNeverPrint_whenPrintLabelIsFalse` (commit, then `never()` on both print methods). |
| L2 second guard flag | **Closed** | Empty-scope test. The sync-only mutant turns it red. |
| L3 throwable | **Closed** | `e` passed last, and the test asserts `getThrowableProxy().getMessage()`. See Nit N2 for the side effect. |
| L4 refused job silent | **Closed** (took the cupsPrintChecked option) | `PrintService` is not touched by this commit. `cupsPrintChecked` = `assertPrintAccepted(submitCupsJob(..))`, and a null result (printing disabled) still passes. No other caller changed: `LabelPrintingService:401,1148` already used it, and every `cupsPrint` caller is untouched. The arch matcher covers it (`startsWith("cupsPrint")`), and a fixture pins it. |
| L5 WARN not asserted | **Closed** | ListAppender on `StockunitService`'s logger (`LOG` = `getLogger(StockunitService.class)`, `:33`), detached in `finally`. Deleting the WARN turns 2 tests red. |
| L6 blind spots | **Closed**, apart from L1 below | Method references are read (pinned). Inheritance is selected (superclass pinned, interface not). NOT_SUPPORTED/NEVER are excluded (NOT_SUPPORTED pinned). Keycloak is narrowed to `org.keycloak.admin.client.` minus `KeycloakBuilder`/`CreatedResponseUtil`, plus the 3 wrappers, with 0 FPs on main. `isPrintAvailable` and private/self-invoked are now listed as known gaps. |
| L7 commit() order | **Closed** | The helper now matches `processCommit` (`:775-776` beforeCommit, beforeCompletion; `:836` afterCommit with sync active; `:839` then `:1017-1022` clear, then afterCompletion) and `processRollback` (`:881`, `:931`). Remaining fidelity gaps are listed in Nit N1. |
| L8 because() connection claim | **Closed** | `because()` now names row locks and rollback coupling only. See L2 for the new "measured HELD" sentence. |
| L9 duplicated selector | **Closed** | `cupsOrKeycloakRule()` serves both `check` and `evaluate`, so the selector cannot drift. |
| L10 HttpRestService selector | **Closed** | `.that(OPEN_A_TRANSACTION)`. Still green on main, so "no new hits" is true. |
| N1 nesting limit | **Closed** | Javadoc paragraph. Its claim is accurate: during `triggerAfterCommit` both flags read true, and the new sync is only reached by `triggerAfterCompletion`, never by afterCommit. |
| N2 "tenant transaction" | **Closed** | Now reads "transferStock's transaction". |
| N3 Error escapes | **Left unchanged; the reasoning is sound but incomplete** | See Nit N6. |
| N4, N5 | Not mentioned | N5 is moot: the untracked IT is gone from the worktree (`git status` clean). N4 is moot if L2's "HELD" result holds. |

## (2) New findings

### [LOW] L1. The interface arm of OPEN_A_TRANSACTION is unpinned, and the docs overclaim interface coverage
File: `src/test/java/net/aim_ai/wms/unit/config/HttpInTransactionArchTest.java:146-165` (predicate) and `:112-116` (comment);
control `:213-234`
Confidence: HIGH (measured)
Issue: (a) Deleting `|| owner.getAllRawInterfaces()...` leaves the whole class **green**. No fixture implements a
`@Transactional` interface, so the arm the commit message advertises ("inherited/interface @Transactional selected") is
not protected by any test. This breaks the floor rule that every new assertion is mutation-checked.
(b) The comment and the predicate's description say "@Transactional on the method, its class, a superclass or an
interface". Only **type-level** annotations on supertypes are read. A `@Transactional` on an interface **method** (or on
an overridden superclass method) is not seen: in the probe, `D.ifaceMethodTx` returned **false**. Spring 6's
`AnnotationTransactionAttributeSource` resolves method-level annotations through the method hierarchy, so such a method is
transactional at runtime. This gap is latent: main has no app interface carrying method-level @Transactional that an app
class implements, as far as the 0-hit run shows. But it is a false negative that the blind-spot list does not admit.
Fix: Add a fixture `@Transactional("tenantTransactionManager") interface TxContract { void op(); }` with an implementing
class whose `op()` prints, expected flagged, and bump `hasSize` to 9. Either add a method-hierarchy check (for each
supertype, `tryGetMethod(name, params)` → `isMetaAnnotatedWith`) or add "method-level @Transactional on an interface or
overridden method is not read" to the blind spots.

### [LOW] L2. "measured HELD on 2026-11-11; see the ticket" cites a measurement with no instrument in the tree, and contradicts the sibling rule's because()
File: `HttpInTransactionArchTest.java:140-142`; sibling `because()` at `:83-88`
Confidence: MEDIUM (I could not read the ticket. The evidence dir and the repo hold no Part B result.)
Issue: The Part B IT (`TenantConnectionReleasedBeforeAfterCommitIT`) was untracked in r1 and is now gone. Its
`@DisplayName` asserted the opposite conclusion ("returned before afterCommit"). The new comment states a result whose
instrument is not committed and whose direction flipped since r1, so a reader cannot reproduce it. Also, if HELD is
right, the HttpRestService rule's `because()` (`:83-88`) still offers "Defer the call to after-commit
(OmsNotificationService.sendAfterCommit)" as the remedy for holding "the tenant DB connection". The same file now states
both that afterCommit does and does not free the connection. This commit touched that rule (L10) but not its text.
Fix: Commit the Part B instrument, or put its run output under `SBDEV-4108-evidence/` and cite that path instead of "the
ticket". Then reword the HttpRestService `because()` the way L8 reworded the new one: afterCommit releases locks and
decouples rollback, and only a non-transactional caller frees the connection.

### [NIT] N1. commit()/rollBack() still differ from Spring in three ways that today's callback cannot see
File: test class `:343-358`
- The helper takes **one** `getSynchronizations()` snapshot and reuses it. Spring re-reads it in every phase
  (`TransactionSynchronizationUtils:126,136,153`), so a sync registered during beforeCommit or beforeCompletion gets
  afterCommit in production but not in the test.
- Spring catches and logs exceptions from `beforeCompletion` and `afterCompletion` (`:137-142`, `:201-206`). The helper
  lets them propagate.
- Spring runs afterCompletion in a `finally` after afterCommit (`APTM:835-839`). The helper skips it if afterCommit throws.
  `@AfterEach` cleans up, so there is no leak.

The javadoc's claim about **order** is now accurate. Optional fix: re-read `getSynchronizations()` per phase and wrap
afterCommit in try/finally.

### [NIT] N2. Transport failures now log the same stack trace twice
File: `StockunitService.java:912-914`
`PrintService:171` already logs ERROR with the stack, then wraps it as the FacadeException's cause. Passing `e` to the
WARN prints that cause chain again. r1 L3 said "at least for RuntimeException". Optional fix: split the catch, logging
`e.getMessage()` for FacadeException and `e` for RuntimeException. A refused job (no cause) is fine either way.

### [NIT] N3. Latent false positives not listed in the blind spots
File: `HttpInTransactionArchTest.java:115-116`, `:137-138`
All measured in the probe:
- class-level `@Transactional(NOT_SUPPORTED)` with a plain method is flagged;
- a custom annotation that meta-carries `@Transactional(NOT_SUPPORTED/NEVER)` on a method is flagged, because
  `tryGetAnnotationOfType` reads only a direct annotation;
- static methods of a transactional class are flagged.

Main has 0 class-level NOT_SUPPORTED, no such custom annotation (`TenantTransactional`/`TenantTransactionalReadOnly` are
REQUIRED), and 0 hits. These fail closed, which is the right direction. Fix: one line each in the blind-spot list.
The specific question asked of this review, about the NOT_SUPPORTED exclusion and REQUIRED/NOT_SUPPORTED at class versus
method level, is answered in the predicate probe table above: class REQUIRED + method NOT_SUPPORTED is excluded, and class
NOT_SUPPORTED + method REQUIRED is included. Both are correct.

### [NIT] N4. The NEVER arm of the exclusion is unpinned
File: `HttpInTransactionArchTest.java:152-153`
Only a NOT_SUPPORTED fixture exists, so dropping `|| ... NEVER` survives. Optional fix: a `printsUnderNever` fixture,
expected not flagged. It would also need an `EXEMPT_NON_TRANSACTIONAL` entry.

### [NIT] N5. In the no-transaction branch the WARN says "AFTER a committed stock transfer"
File: `StockunitService.java:913`, else-branch `:925`
In the else branch nothing has committed, and the print runs inside transferStock. Only a non-proxied or empty-tx caller
reaches it, so it is cosmetic. Possible wording: "label print failed after a stock transfer (not rolled back)".

### [NIT] N6. The N3 rationale rebuts catching Error, but not r1's actual alternative
File: commit message ("Not changed: N3 ...")
r1 N3 already said not to catch Error, and offered `afterCompletion(STATUS_COMMITTED)`, which Spring wraps in
catch-Throwable (`TransactionSynchronizationUtils:201-206`). Keeping afterCommit is defensible: it matches ReceivingService
and the gate test, and with afterCommit an Error still runs afterCompletion through the `finally` at `APTM:838-839`, so only
later afterCommit callbacks are skipped. The decision is fine. The message just answers a weaker version of the
suggestion. No code change needed.

## (3) Commit message accuracy

Accurate, with one overclaim:
- "7 tests" is correct.
- "commit()/rollBack() now fire callbacks in AbstractPlatformTransactionManager's order" is correct against 6.2.15.
- "Keycloak narrowed ... the three app wrappers" is correct: the classes exist at the named FQNs.
- "HttpRestService rule uses the same selector (L10, no new hits)" is correct: green on main.
- The two rails named in the subject are real and both are handled: bare `any()` in `never()`, and named-TM fixtures plus
  the `EXEMPT_NON_TRANSACTIONAL` entry. `TestClassTransactionManagerArchTest` goes red without the exemption: my probe
  tripped exactly those two rules.
- **Overclaim:** "inherited/interface @Transactional selected". Interface **type-level** only, and untested (L1).
- The subject says "Nits" without noting that N4 and N5 were not acted on. Both are moot (see the table), so this is
  harmless.

## Positive observations
- The cupsPrintChecked swap is the stronger of r1's two options, and it is contained. PrintService is untouched, so no
  other caller's refusal semantics change.
- The one shared `cupsOrKeycloakRule()` object removes the drift class entirely. The control asserts every expected
  verdict by name, plus an exact size.
- Every new test kills a real mutant: 7 of 8 mutants went red. The log capture asserts content, not just a count.
- The Keycloak narrowing is driven by actual usage (it excludes `KeycloakBuilder`/`CreatedResponseUtil` and leaves
  representations out), and it keeps 203 real call sites in view on main with 0 false positives.
- The blind-spot comment is now honest about lambdas versus anonymous classes, and states the new-wrapper limitation
  outright.

## Recommendation
**APPROVE.** Before the PR, fix L1 (one fixture plus one comment line) and L2 (cite or commit the Part B evidence, and
align the HttpRestService `because()`). The Nits are optional.
