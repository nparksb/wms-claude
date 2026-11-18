head: eb46d10a

# SBDEV-4108 — independent code review, round 1

Reviewed: `git diff origin/develop...eb46d10a` in `.claude/worktrees/wms2-api/SBDEV-4108` (1 commit, 3 files:
`StockunitService.java`, `HttpInTransactionArchTest.java`, new `StockunitServiceTransferStockPrintAfterCommitUnitTest.java`).
Read-only. I did not run mvn in the worktree. Evidence used:
- the diff, plus targeted reads of `StockunitService`, `PrintService`, `OmsNotificationService`, `ReceivingService`,
  `StockUnitController` and `CancellationReversalService`;
- `target/surefire-reports/...HttpInTransactionArchTest.txt` (18:07, from the running verify): 3 run, 0 failures. There is no
  surefire report yet for the new unit test, so I have **not** seen it pass;
- an ArchUnit 1.3.0 probe on JDK 21 that I compiled outside the repo
  (`/private/tmp/claude-503/-Users-np1076-dev-spk-owl/13e35dc8-e608-4d1f-a2e2-c3bd698308ff/scratchpad/arch/`).
  It settled the questions about lambdas, method references and inheritance below.

## Verdict: COMMENT (no blocking finding). Fix the 2 Mediums and the Lows before the PR.

**Counts: High 0 · Medium 2 · Low 10 · Nit 5**

The production change is correct for every current caller. Most findings are in the tests and in what the
comments claim.

## Stage 1: does the change match the plan?

| Plan bullet | Status |
|---|---|
| A: build the label in the tx, send it afterCommit, send immediately with no tx, never print on rollback, swallow and log failures, mirror setLockDamaged | Implemented as written (`StockunitService.java:878-917`) |
| Architect A1: catch FacadeException **and** RuntimeException | Implemented (`:900`) but **untested** (M2) |
| Architect A2: two-flag guard plus `setActualTransactionActive(true)` in the test | Implemented (`:906-907`, test `:193-194`). The second flag is not pinned by any test (L2) |
| Architect A3: capture the address String and byte[], not entities | Implemented (`printer`, `caseLabel`, `unitLoadId` Long) |
| C: the rule covers @Transactional (direct, meta, class-level) calling `PrintService.cupsPrint*` or Keycloak, with a fixture positive control | Implemented. Its documented blind spots are partly wrong (M1, L6) |
| Call out the behaviour change | Done in the javadoc and the commit message. The wording overclaims (L4) |

## Answers to the brief's questions

1. **afterCommit registration for each caller.** Correct for all 3 call sites (`grep -rn "\.transferStock(" src/main/java`).
   - `StockUnitController:158` (single) and `:284` (bulk loop): the class has 0 `@Transactional` and `open-in-view=false`
     (`application.properties:91`). Each call goes through the proxy, so it is its own outermost tx, and the label prints at that
     id's own commit. A bulk id that fails prints nothing.
   - `CancellationReversalService:449`: joins `completeReversal`'s tx (REQUIRED, `:285`) but passes a literal `printLabel=false`,
     so nothing is registered. If a printing caller ever joins an outer tx, the label waits for the outer commit and is dropped on
     an outer rollback, which is the right semantics.
2. **The `isSynchronizationActive && isActualTransactionActive` guard.** Right. It is the same idiom as
   `OmsNotificationService:68-69`, whose comment (SBDEV-3267) records what the second flag actually tells apart: an **empty**
   transaction, not nesting.
3. **Synchronization active but no actual tx (SUPPORTS / NOT_SUPPORTED).** This cannot happen through the proxy. transferStock is
   REQUIRED, so from a SUPPORTS scope or a suspended NOT_SUPPORTED scope the tenant TM starts a real tx with fresh synchronization.
   `getTransaction` → `suspend(null)` suspends the outer synchronizations, so the print attaches to transferStock's own commit.
   The same holds under an outer landlord-TM tx. Only a **non-proxied** call in an empty-tx scope reaches the else branch, and
   printing immediately is correct there: writes in an empty tx are not held back by a commit. `main` has 0 uses of
   `Propagation.SUPPORTS/NOT_SUPPORTED/NEVER` today. The one undocumented hole: transferStock called from **inside another
   afterCommit** would see both flags true, register into the list Spring is already iterating, and lose the label silently (N1).
4. **Do exceptions in afterCommit escape?** FacadeException and RuntimeException do not. `Error` does, into
   `processCommit` → the controller → a 500 for a committed move. It would also skip the afterCommit callbacks after it
   (N3, theoretical). The OMS send registered earlier in the same tx (`messageService.sendStockChangeMessage`) runs first, and
   `doSend` catches Exception (`OmsNotificationService:154`), so it cannot skip the print. The print does wait for the OMS POST
   to finish (fine).
5. **byte[] and printer captures, and their lifetime.** No problem. The values are immutable or never mutated after capture.
   No managed entity is captured. The synchronization object is dropped by `clearSynchronization` at completion. The lambda
   captures `this` (a singleton). The label is a few hundred bytes.
6. **Is the log line useful?** Partly. It carries unitLoad and printer, which is good correlation. It drops the throwable (L3),
   and it never fires for the commonest silent failure, a job CUPS refuses (L4).
7. **Do the tests prove what they claim?** A1, A2a, A2b and the no-tx fallback are well built. A2a asserts `never()` before
   commit and `times(1)` after. A1 asserts the print was attempted. They miss the RuntimeException catch (M2) and the second
   guard flag (L2), and they do not assert the WARN they rely on (L5). The hand-rolled `commit()` does not reproduce Spring's
   order (L7).
8. **Arch rule false positives and negatives.** Yes, several. One claim is **empirically false** (M1); the rest are not
   admitted (L6).
9. **Does the javadoc or a comment overclaim?** Yes: M1, L4, L8, L7.

## Findings

### [MEDIUM] M1. The arch-rule comment says lambda bodies are invisible. In ArchUnit 1.3.0 they are attributed to the enclosing method
File: `src/test/java/net/aim_ai/wms/unit/config/HttpInTransactionArchTest.java` (SBDEV-4108 C comment block, "It does NOT follow
calls through helpers, and it does NOT see a call made from a lambda or anonymous class inside the method (those compile to other
members)"). The architect consult §5 makes the same claim.
Confidence: HIGH (measured)
Issue: My ArchUnit 1.3.0 / JDK 21 probe produced this:
```
Fx.lambdaInTx calls=[run, cupsPrint]      ← @Transactional method, lambda body: FLAGGED
Fx.anonInTx   calls=[run]                 ← anonymous class: not seen (comment correct for this one)
Cl.plain      calls=[run, cupsPrint]      ← class-level @Transactional, lambda: FLAGGED
```
ArchUnit does not import `lambda$…` synthetics as separate methods. It attributes a lambda body's calls to the method that
declares the lambda. Consequences:
(a) The stated blind spot is false for lambdas. This is fail-closed: `list.forEach(x -> printService.cupsPrint(..))` in a tx
**is** caught, which is good.
(b) The "sanctioned fix" guidance in the comment and the `because()` is wrong for a lambda. If someone inlines this commit's
own shape (`Runnable print = () -> printService.cupsPrint(..)` plus an anonymous synchronization calling `print.run()`) into a
@Transactional method, the rule goes red. The production fix passes only because its lambda lives in the private,
non-transactional `printCaseLabelAfterCommit`.
(c) The fixture covers only the anonymous-class shape, so the control does not pin the lambda behaviour either way.
Fix: Reword the comment: anonymous-class bodies are separate members and not seen, but lambda bodies count as the enclosing
method. Say the afterCommit body must be an anonymous class, or a lambda declared in a non-transactional helper, as
`printCaseLabelAfterCommit` does. Add a fixture member `@Transactional void printsInLambda()`, expected **flagged**, so the
behaviour is pinned. Correct architect consult §5 ("anonymous-class and lambda bodies are separate").

### [MEDIUM] M2. The `RuntimeException` arm of the catch (architect A1) has no test. Deleting it survives the whole suite
File: `StockunitService.java:900` (`catch (FacadeException | RuntimeException e)`); test class
`StockunitServiceTransferStockPrintAfterCommitUnitTest.java:203-273`
Confidence: HIGH (grep: the test class stubs only `doThrow(new FacadeException(..))`, at `:205` and `:257`, and no
RuntimeException anywhere)
Issue: A1 exists because `PrintService.submitCupsJob` calls `syspropService.getSysvalue(...)` **outside** its try
(`PrintService.java:142-144`). A runtime failure there would escape `afterCommit`, turning a committed move into a 500 and
skipping the later afterCommit callbacks. That is the one guard that keeps the new contract ("a print failure never fails the
transfer") true for non-Facade failures, and no test fails if it is removed. This breaks the floor rule to mutation-check every
assertion.
Fix: Add a test: `doThrow(new IllegalStateException("sysprop read failed")).when(printService).cupsPrint(anyString(), any())`,
then `transferStock(...)` and `assertThatCode(this::commit).doesNotThrowAnyException()`. Mutation-check it by dropping
`| RuntimeException`, which must go red.

### [LOW] L1. Nothing pins `printLabel=false` → no synchronization registered (the CancellationReversal path)
File: test class (no case); `StockunitService.java:855`
Confidence: MEDIUM
Issue: The architect's "zero prints for the one outer-tx caller" rests on `printLabel=false`. No test asserts
`TransactionSynchronizationManager.getSynchronizations()` gains no print callback, or that `cupsPrint` is never called after
`commit()`, when `printLabel=false`. A regression that registers unconditionally would print a label at the end of every
cancellation reversal.
Fix: One more test: `transferStock(..., false)`, then `commit()`, then `verify(printService, never()).cupsPrint(..)`.

### [LOW] L2. The `isActualTransactionActive()` half of the guard is not pinned
File: `StockunitService.java:906-907`; test `:193-194`, `:256-257`
Confidence: HIGH (by inspection: the tests set both flags true together, or both false together)
Issue: A mutant guarded on `isSynchronizationActive()` alone passes every test. The empty-tx case (synchronization true, actual
false) is the one the second flag exists for, and nothing exercises it. Under that mutant the label would be deferred to the end
of an empty-tx scope instead of printing now. This is harmless today, but the flag is then unjustified code.
Fix: Add a case that sets `initSynchronization()` with `setActualTransactionActive(false)` and asserts `cupsPrint` ran during
`transferStock` (before any `commit()`). Or drop the second flag and document why it cannot matter for a REQUIRED method. The
first option is better, because it keeps the idiom aligned with `OmsNotificationService`.

### [LOW] L3. The WARN discards the throwable, so a RuntimeException is undiagnosable
File: `StockunitService.java:901-902`
Confidence: HIGH
Issue: `LOG.warn("...: {}", ..., e.getMessage())` keeps only the message. For a FacadeException that is acceptable:
`PrintService:171` already logged ERROR with the stack trace, and the message is just `"PRINT_FAILED <printer>"`, which repeats
`printer={}`. For the RuntimeException arm (M2's path) nothing upstream logs it. An NPE prints `: null` with no stack, the one
failure you could not diagnose from the log.
Fix: Pass `e` as the last argument (`LOG.warn("... unitLoad={} printer={}", unitLoadId, printer, e)`), at least for
RuntimeException.

### [LOW] L4. The javadoc's behaviour-change note overclaims. A CUPS-refused job leaves no WARN at all
File: `StockunitService.java:893-894` ("Now the transfer succeeds and the missing label is visible only in the WARN log"); the
commit message says the same thing ("the missing label shows only in the log")
Confidence: HIGH
Issue: `cupsPrint` deliberately swallows a job the CUPS daemon **refuses** (paused queue, bad printer state). It logs that at
DEBUG only (`PrintService.java:103-110`, then `:165`). Only transport failures throw, and those are logged twice (ERROR at
`PrintService:171`, then this WARN). The most common missing-label case therefore produces no WARN, so "visible in the WARN log"
is false for it. Before this change that case was silent too, but the new contract is the place to fix it: a failure now rolls
nothing back, so the old reason to swallow refused jobs in-tx no longer applies here.
Fix: In the callback, call `printService.cupsPrintChecked(...)` so a refused job raises a FacadeException and reaches the WARN.
Do this only if you accept that the ArchUnit predicate already covers `cupsPrintChecked`, which it does. Otherwise reword the
javadoc to say that transport failures are logged at ERROR and WARN, and that a job CUPS refuses is logged only at DEBUG.

### [LOW] L5. "Logged" is part of the tested contract but is never asserted
File: test class `:202-216` (AC A1: "a print failure after commit must be logged, not thrown")
Confidence: HIGH
Issue: The AC and the javadoc both say the failure is logged. The test proves only that nothing was thrown. A mutant with an
empty catch block passes. Given L4, the WARN is the operator's only signal that a label is missing.
Fix: Capture the `StockunitService` logger. The repo has precedents: `ListAppender` / `OutputCaptureExtension` usage in
`TenantPoolMetricsClobberTest`, `TenantProbeStallTest` and `StockSummaryExportJobUnitTest`. Assert one WARN containing
`unitLoad=2` and the printer address.

### [LOW] L6. Arch rule false negatives and false positives that the comment does not admit
File: `HttpInTransactionArchTest.java` (`OTHER_NETWORK_CLIENT` and the selector)
Confidence: HIGH for the items I measured, MEDIUM for the rest
Issue: The comment lists only "helpers" and "lambda/anonymous" as blind spots, and M1 shows the lambda part is wrong. Not
admitted:
- **FN, measured:** a method reference (`printService::cupsPrint`) is a `JavaMethodReference`, not a call. In the probe
  `getMethodCallsFromSelf` misses it (`Fx.methodRefInTx calls=[requireNonNull, accept] refs=[cupsPrint2]`), so it is not flagged.
- **FN, measured:** a subclass of a class-level `@Transactional` class. Spring's `@Transactional` is `@Inherited`, so the
  subclass's methods are transactional at runtime, but `areDeclaredInClassesThat().areMetaAnnotatedWith` does not follow
  inheritance (`Sub.subPrint` was not flagged). Interface-level `@Transactional` is missed the same way.
- **FN:** other PrintService network calls are excluded on purpose (`isPrintAvailable`, a CUPS `getPrinter`, and `testPrint`).
  The architect found a live in-tx site, `ReceivingService.receiveGoods → isPrintAvailable`. The comment should name this as a
  known, accepted gap (or as a T3-style proposal), not leave it implicit.
- **FP, latent:** `@Transactional(propagation = NOT_SUPPORTED | NEVER)` (and SUPPORTS with no outer tx) is flagged even though
  no tx is open. That is a legitimate escape hatch. `main` has 0 such annotations today.
- **FP, latent:** private methods (never proxied) and methods called only by self-invocation are flagged, as is any method of a
  class-level `@Transactional` class.
- **FP, latent:** `owner.startsWith("org.keycloak.")` matches pure DTO and utility calls (`UserRepresentation.setUsername`,
  `KeycloakBuilder`) that make no network call. The app's `Keycloak*` prefix also matches any future non-network
  `KeycloakConfig` / `KeycloakProperties` getter.
Fix: Add these to the comment's blind-spot list. Cheaply closable in the condition:
`method.getMethodReferencesFromSelf()` (same filter on the target), and excluding methods whose effective
`@Transactional.propagation` is NOT_SUPPORTED/NEVER. Narrow `org.keycloak.` to
`org.keycloak.admin.client..` plus `org.keycloak.authorization.client..` if those are the only network packages in use.

### [LOW] L7. The hand-rolled `commit()` does not reproduce Spring's order, and its javadoc says it does
File: test class `:275-283` ("Fires the callbacks Spring's transaction manager fires on a successful commit, in its order")
Confidence: HIGH
Issue: `AbstractPlatformTransactionManager.processCommit` runs `beforeCommit`, then `beforeCompletion`, then the commit, then
`afterCommit` **while synchronization is still active** (and `isActualTransactionActive()` is still true, see
`OmsNotificationService:73-75`), then `triggerAfterCompletion`, which clears the list and then calls `afterCompletion`. The
helper clears synchronization **before** `beforeCommit`/`afterCommit` and never calls `beforeCompletion`. `rollBack()` also
skips `beforeCompletion`. For today's callback this changes nothing. But a future callback that branches on
`isSynchronizationActive()` or registers a nested synchronization (the SBDEV-3267 trap) would be graded in a state production
never has, and would pass the test while silently dropping the work in production.
Fix: Keep synchronization active through `afterCommit` and clear it only before `afterCompletion`, and add
`beforeCompletion()` to both helpers. Or drive a real `AbstractPlatformTransactionManager` stub
(`ResourcelessTransactionManager`-style, a few lines extending `AbstractPlatformTransactionManager` with no-op
`doBegin`/`doCommit`/`doRollback`) so Spring itself fires the callbacks. At minimum, drop "in its order" from the javadoc.

### [LOW] L8. The `because()` text implies afterCommit releases the DB connection
File: `HttpInTransactionArchTest.java` (`because("a CUPS print or a Keycloak call inside an open @Transactional holds the tenant
DB connection ... Register the call for after commit ...")`)
Confidence: MEDIUM
Issue: The text gives connection hold as a reason and offers afterCommit as the remedy. Architect consult §4 notes the
connection may still be checked out during `afterCommit`: `triggerAfterCommit` runs before `doCleanupAfterCompletion`, and the
behaviour depends on `DELAYED_ACQUISITION_AND_HOLD`. Part B's probe (the untracked
`TenantConnectionReleasedBeforeAfterCommitIT`, see N5) exists because the answer is not yet known. Until it is, the rule's
message claims a fix it has not shown. It also says "tenant", but the selector covers landlord-TM methods too
(`LandlordService` is class-level `@Transactional`).
Fix: Say "row locks and rollback coupling are fixed by afterCommit; to also free the connection, call from a non-transactional
method", or point at Part B's result once it is committed. Drop "tenant", or say "the DB connection".

### [LOW] L9. The control "verbatim" copies the production selector and condition, so the two can drift
File: `HttpInTransactionArchTest.java` (control test: "The production rule's selector, verbatim, so the control grades the
selector as well as the matcher")
Confidence: HIGH
Issue: The selector chain is duplicated by hand. An edit to the production rule (for example, adding a propagation exclusion
per L6) would leave the control grading the old selector, and it would stay green. "Verbatim" is true only until the first edit.
Fix: Extract `static ArchRule cupsOrKeycloakRule()` (or the `GivenMethodsConjunction`) and call `.check(appClasses)` and
`.evaluate(fixture)` on the same object.

### [LOW] L10. The existing HttpRestService rule keeps the direct-annotation blind spot this commit closes for the new rule
File: `HttpInTransactionArchTest.java:75` (`.that().areAnnotatedWith(Transactional.class)`)
Confidence: HIGH
Issue: The architect noted (§5) that `areAnnotatedWith` misses `@TenantTransactional`, `@TenantTransactionalReadOnly` and
class-level `@Transactional` (`PickLineRealignmentService`, `LandlordService`). The new rule fixes this, but the two rules in
the same file now use different selectors for the same hazard. The architect's scan found no extra HttpRestService hits, so
closing it is free.
Fix: Point the HttpRestService rule at the same shared selector (see L9).

### [NIT] N1. The javadoc does not say that a call from inside another afterCommit loses the label
File: `StockunitService.java:887-895`
Issue: `OmsNotificationService:72-83` documents that the two-flag guard cannot detect nesting inside `afterCommit`, and that a
registration there is "discarded unseen". The same holds here. No caller does this today. One sentence, or a pointer to
`NestedCallSiteRailTest`, would keep the next caller from finding out the hard way.

### [NIT] N2. "the current tenant transaction" in the javadoc
File: `StockunitService.java:888`
Issue: The helper keys on whatever synchronization scope is current, not specifically the tenant TM. It is accurate in practice
because transferStock is tenant-TM REQUIRED. Saying "transferStock's transaction" is more precise.

### [NIT] N3. An `Error` thrown from the callback still escapes afterCommit
File: `StockunitService.java:897-904`
Issue: Catching Error is wrong, so do not change the catch. The alternative is to register with
`afterCompletion(STATUS_COMMITTED)`, the `ReplenishmentMaintenanceTrigger:51-53` idiom: an exception there is logged by Spring
and not propagated. That would also make A1 hold structurally rather than by catch list. This is optional; the current shape
matches ReceivingService and the gate test.

### [NIT] N4. A cache-miss sysprop read in the callback runs inside the committed transaction's still-bound resources
File: `PrintService.java:142-144`, reached from the callback
Issue: `getSysvalue` is `@Cacheable`. On a miss, the repository read joins the committed, not-yet-cleaned-up JPA tx, which is
Spring's documented afterCommit caveat. This is harmless for a read and is the same as the ReceivingService precedent. It is
worth one clause if Part B concludes the connection is released before afterCommit, because the read would then re-acquire
one.

### [NIT] N5. An untracked Part-B IT sits in the worktree, outside eb46d10a
File: `src/test/java/net/aim_ai/wms/integration/TenantConnectionReleasedBeforeAfterCommitIT.java` (`??` in `git status`)
Issue: This is not part of this review. Its `@DisplayName` asserts a conclusion ("the tenant connection is returned before
afterCommit callbacks run") that L8 and the architect consult treat as open. Make sure the running `clean verify` result is read
as covering an uncommitted file, and that the file's claim is backed by the run before anyone cites it.

## Open questions (not blocking)
- The commit message says "On develop it flagged exactly one method, transferStock." That figure comes from the architect's
  ad-hoc scan, not from running this rule against develop's classes. M1 shows the lambda attribution makes the shipped rule
  stricter than the scan described. A red-on-develop run of the real rule (in a detached worktree) would make the claim
  first-hand.
- The new unit test has no surefire report yet. Confirm 4/4 green in the running verify.

## Positive observations
- The fix is the smallest correct shape. The label is still built in-tx where it reads the DB. Only primitives and the byte[]
  are captured, so no detached entity is touched after commit. The private helper avoids the `PrintService` mock trap the
  architect named.
- The guard reuses the repo's established idiom, matching `OmsNotificationService`.
- Each test pairs a negative with a positive: `never()` before commit and `times(1)` after; "did not throw" and "was
  attempted". That rules out the vacuous pass where the fix simply stopped printing.
- The arch rule ships with a real positive control that asserts each expected violation by name, no unexpected ones, and an
  exact count. The control also covers meta-annotated and class-level selection, which the old rule could not see.
- The comment at the call site (`:881-883`) states exactly which two harms the move fixes (locks, rollback coupling) and does
  not claim the connection.
