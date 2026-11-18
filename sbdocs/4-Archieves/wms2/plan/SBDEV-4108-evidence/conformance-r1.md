head: eb46d10a

# SBDEV-4108 conformance, round 1 (criteria A and C; B out of scope for this commit)

Lane: read-only conformance. Own detached worktree (removed afterwards); the SBDEV-4108 worktree was not touched. Java 21 (`JAVA_HOME=ms-21.0.8`); the default `java` is 8 and fails the build on the spring-boot plugin, so a Java 8 run proves nothing.
Diff: 3 files, +479/-1: `StockunitService.java` (+38), `HttpInTransactionArchTest.java` (+158), `StockunitServiceTransferStockPrintAfterCommitUnitTest.java` (+284 new). Merge-base with origin/develop = `df30fa62` (equals origin/develop now).

## Verdict: PASS for A and C as scoped, with one PARTIAL (log assertion) and one flagged ambiguity.

## Evidence

| Check | Result | Command / source | Output |
|---|---|---|---|
| Red today (origin/develop `df30fa62` + only the two test files from eb46d10a) | red, 5 of 7 | `mvn -o test -Dtest='HttpInTransactionArchTest,StockunitServiceTransferStockPrintAfterCommitUnitTest'` | Tests run: 7, Failures: 5, Errors: 0 |
| Green at eb46d10a | pass | same command | Tests run: 7, Failures: 0; BUILD SUCCESS |
| Mutation 1: rethrow FacadeException from the print callback | red | edit in my worktree, reverted | 2 failures: `shouldNotThrow_whenCupsPrintFails:218`, `shouldPrintImmediately_whenNoTransactionIsActive:262` |
| Mutation 2: print in `afterCompletion` instead of `afterCommit` | red | edit in my worktree, reverted | 1 failure: `shouldNotPrint_whenTransactionRollsBack:247` |
| Mutation 3: delete the `LOG.warn` (silent swallow) | NOT RUN; test source has no log-capture (grep for appender/OutputCapture/logback: no hits), so it would stay green | inspection | see Gap 1 |
| Full suite vs baseline | NOT-ASSESSED | running separately | |

Red-today detail (all five are assertion failures, none are compile or setup errors; the tests compile and the fixtures run on develop):
- `HttpInTransactionArchTest.transactionalMethodsMustNotCallCupsOrKeycloak:144` ArchUnit violation; the only violation reported is `StockunitService.transferStock() is @Transactional and calls PrintService.cupsPrint()`.
- `shouldNotThrow_whenCupsPrintFails:214` AssertionError ("a print failure must not propagate out of transferStock..."), carrying `FacadeException: CUPS refused the job`.
- `shouldPrintOnlyAfterCommit_whenTransactionCommits:231` MockitoAssertionError "cupsPrint ran inside transferStock's transaction, before commit, while it held the row locks".
- `shouldNotPrint_whenTransactionRollsBack:247` MockitoAssertionError "a label was printed for a transfer whose transaction rolled back".
- `shouldPrintImmediately_whenNoTransactionIsActive:262` AssertionError: the FacadeException escapes (the test is red today for the swallow, not for the immediate print).
- `HttpInTransactionArchTest.cupsOrKeycloakRuleIsNotVacuous` (the fixture-based control) passes on develop, as it should: it grades the matcher, not production code.

## Acceptance criteria

| # | Criterion | Status | Evidence |
|---|---|---|---|
| A1 | Failing test: a print failure rolls back the transfer (red today); after the fix the transfer commits and the print failure is surfaced/logged; mutation-check | PARTIAL | Red today proven (`shouldNotThrow_whenCupsPrintFails` fails with the FacadeException escaping a `rollbackFor=FacadeException` method). Green after the fix. Mutation 1 turns it red. PARTIAL only because "logged" is not asserted: see Gap 1. The mechanism the test models is that anything thrown out of transferStock rolls back; it does not run a real transaction manager (synchronization is simulated by hand), which is a limit but is the repo's usual idiom. |
| A2 | Print happens only after commit (test with a commit failure, no print) | VERIFIED | `shouldPrintOnlyAfterCommit` (never before commit, once after) and `shouldNotPrint_whenTransactionRollsBack` (rollback `afterCompletion`, never printed) both red on develop, green at eb46d10a. Mutation 2 (print on any completion) is caught by the rollback test. Note the "commit failure" is modelled as `STATUS_ROLLED_BACK` completion without `afterCommit`, which is what Spring does when commit throws. |
| C | Arch test catches CUPS and Keycloak calls inside @Transactional (positive control: fails on today's transferStock) | VERIFIED | Production rule fails on develop naming `StockunitService.transferStock()` -> `PrintService.cupsPrint()`; green after the fix. Separate fixture control (`cupsOrKeycloakRuleIsNotVacuous`) asserts exactly 5 violations (cupsPrint, cupsPrintChecked, Keycloak call, meta-annotated tx, class-level tx) and that the non-transactional and afterCommit-callback members are NOT flagged. Caveat: on production code the Keycloak branch has zero hits (only transferStock was reported), so Keycloak coverage rests on the fixture alone. |
| Full suite vs baseline | NOT-ASSESSED | running separately | |
| B (all rows) | OUT OF COMMIT | declared by the requester | not graded |

## "Surfaced/logged": is a WARN log enough?

Literal reading: the ticket says "surfaced/logged", a slash alternative, so a WARN log satisfies the words. The ticket's own fix text ("a print failure must not roll back the stock move") and its model, `setLockDamaged` under SBDEV-3086, also swallow and log. The commit's Javadoc states the behaviour change openly: the operator no longer sees the print error, only the WARN log shows a missing label.

What the wording could imply beyond that: "surfaced" suggests a signal to the caller, and the ticket's problem statement says a bulk "transfer + print" currently fails every row, which is at least visible to the operator. After the fix a lost label is invisible in the UI. Whether that is acceptable is a product call, not provable from the ticket. I read it as met by WARN only if Nam accepts the silent-label risk; if "surfaced" is meant to reach the user (response flag, warning field, message row), this commit does not do it. Recommend the ticket comment states which reading was chosen.

## Gaps

1. The WARN log is not tested. No test captures the log, so deleting `LOG.warn` (print failure silently dropped) keeps all 7 tests green. Since the only "surfaced" channel this fix offers is that log line, A1's "logged" half is unproven. Risk: medium. Suggestion: a Logback `ListAppender` on `StockunitService` asserting one WARN containing the unitLoad id and printer, then mutation-check by deleting the line.
2. The Keycloak half of rule C has no production positive hit; it is graded only by the fixture (which does cover it). Risk: low. Suggestion: none needed beyond the existing fixture, but note that the rule matches only direct calls, not helpers or lambdas; the test Javadoc says so.
3. A single print call site was fixed. Other `cupsPrint*` callers inside transactions: the widened rule found none on develop apart from transferStock, so no sibling is flagged by the instrument, but the rule's own documented blind spots (helper indirection, lambdas) mean this is "none found by a direct-call scan", not "none exist".
4. `printCaseLabelAfterCommit` falls back to an immediate print when no transaction is active; that branch is tested (`shouldPrintImmediately`).

## Overall: PASS (A and C), full suite NOT-ASSESSED, B not graded. Recommendation: APPROVE with Gap 1 closed in the next round if "logged" is to count as verified.
