# SBDEV-4108 — architect consult: is afterCommit the right shape for transferStock's print?

Worktree `.claude/worktrees/wms2-api/SBDEV-4108` @ `df30fa62` (origin/develop). Read-only. 2026-11-11.

## Verdict
**Yes, afterCommit (deferred, swallowed) is the right shape, with three amendments** (A1–A3 below). Every
caller that can print runs `transferStock` as its OWN outermost transaction, so the print fires exactly once
per committed transfer. The one caller inside an outer tx never prints (it passes a literal `false`).

## 1. Callers (instrument: `grep -rnw transferStock src/main/java`, then dropping comment lines and
the same-named methods on other classes; cross-checked with an ArchUnit one-hop scan over `target/classes`,
which reported the same three sites)
Exactly 3 call sites of `StockunitService.transferStock`:
| Site | Outer tx? | printLabel | Effect of afterCommit |
|---|---|---|---|
| `StockUnitController.java:158` single `/transferStock` | none: the class has no `@Transactional` (grep of the file finds 0 hits) and `spring.jpa.open-in-view=false` (`application.properties:91`) | from request | one print at transferStock's own commit |
| `StockUnitController.java:284` bulk `ids` loop | none, as above; each loop pass calls the proxy, so it gets its own tx | from request | one print per committed id, at that id's commit. Same count and timing as today, and a failed id prints nothing |
| `CancellationReversalService.java:449` inside `completeReversal` (`@Transactional(... rollbackFor ...)` at `:285`) | **yes**, transferStock joins it (REQUIRED) | **literal `false`**: `transferStock(stockUnit, log.getAmountPicked(), false, resolveDestinationName(log, destination), null, null, false)` | the `if (printLabel)` block (`StockunitService.java:854`) is skipped, so **zero prints**. The "N prints at the outer commit / none on outer rollback" scenario cannot happen today |
The mobile `TransferOrderController.java:101` calls `mobileTransferOrderService.transferStock`, a different method.
Guard for the future: if a printing caller ever runs inside an outer tx, the label waits for the OUTER commit
and is dropped on an outer rollback. That is the correct semantics (no label for stock that did not move).

## 2. Does any caller rely on a print failure propagating?
- **Behaviour today:** `cupsPrint` throws `FacadeException("PRINT_FAILED " + printerName, e)` (`PrintService.java:172`),
  which rolls the move back (rollbackFor). The controller catches it and shows it to the operator:
  `catch (FacadeException e) { errors.add(getErrorMessage("Runtime Error", e.getLocalizedMessage())); }`
  (`StockUnitController.java:162-164`; bulk `:288-289`). **This is a user-visible contract change:** after
  the fix the move commits, the response is `true`, and no label prints. The operator only finds out by
  looking at the printer. The same trade was accepted for `setLockDamaged` (SBDEV-3086 M1,
  `StockunitServiceUnitTest.java:3216-3220`: "A printer outage must NOT propagate ... the operator would
  be invited to damage the same stock twice") and for receiving (`ReceivingService.java:761-762`).
  The same retry argument applies to the bulk transfer, which is not idempotent either. Recommend
  calling the contract change out in the PR and on the ticket.
- **Tests:** none of them asserts that a transferStock print failure propagates. Instrument: `grep -rn cupsPrint src/test/java`.
  The only `doThrow` on cupsPrint is in the setLockDamaged test (`:3212`), which asserts NON-propagation, and in the new
  gate test. `StockUnitControllerUnitTest.java:351` stubs `doThrow(new FacadeException("System error"))` on the
  service MOCK, so the change cannot affect it. The method still declares `FacadeException`.
- Note: `cupsPrint` declares only `FacadeException` (`PrintService.java:103`). Catching `BusinessException` around
  that call alone does not compile, since both are checked (`BusinessException extends Exception`, `FacadeException extends Exception`).

## 3. Reuse a helper, or use an anonymous TransactionSynchronization?
`registerSynchronization` sites in main: ReceivingService, ReplenishmentMaintenanceTrigger, OmsNotificationService,
BolOmsNotificationService, BillofladingService ×2, ClubRunJobService. **No shared print-after-commit helper exists.**
- `ReceivingService.printAfterCommit` (`:763-775`) is the closest precedent, but it is `private`, catches only
  `FacadeException`, and calls `registerSynchronization` with no check that synchronization is active.
- `ReplenishmentMaintenanceTrigger` (`:51-53`) records why it uses `afterCompletion(STATUS_COMMITTED)`: "an exception
  thrown from afterCommit propagates to whoever called commit ... and skips the remaining afterCommit callbacks,
  among them OmsNotificationService's sends". transferStock registers OMS stock-change sends in the same tx.
- **Do NOT put the helper on `PrintService`.** The gate test mocks `printService` and asserts `cupsPrint` after
  commit, and a mocked `printService.cupsPrintAfterCommit` would swallow it. This is the trap the Trigger's
  javadoc (`:66-67`) names.
**Recommendation:** use a private helper in StockunitService that mirrors ReceivingService (A1, A2). Extracting a shared
`@Component` used by both is reasonable, but it is follow-up scope.

## 4. Amendments to the proposed shape
- **A1 — catch `FacadeException` AND `RuntimeException` in the callback**, or use `afterCompletion(STATUS_COMMITTED)`.
  `submitCupsJob` calls `syspropService.getSysvalue(...)` (`PrintService.java:142-144`) OUTSIDE its try, so a
  runtime failure there would escape `afterCommit`. It would then turn a committed move into a 500 and skip the OMS sends registered after it.
- **A2 — the immediate-call condition must agree with the gate test.** The test only calls
  `TransactionSynchronizationManager.initSynchronization()` (`...PrintAfterCommitUnitTest.java:179`), so
  `isActualTransactionActive()` is **false** there. Copying the Trigger's two-flag guard
  (`!isSynchronizationActive() || !isActualTransactionActive()` → run now, `ReplenishmentMaintenanceTrigger.java:92-93`)
  would print immediately and fail AC A2a. Do one of two things: key on `isSynchronizationActive()` alone (enough here,
  because transferStock is `@Transactional`, so the "empty tx" case the Trigger guards cannot happen), or add
  `setActualTransactionActive(true)` to the test. Prefer the second, because it keeps the real two-flag guard.
- **A3 — capture values before deferring:** pass the `printer` address String and the `byte[]`, not entities. Build the
  label in-tx as proposed. ReceivingService does the same (`String printerAddress = printer.getAddress();`).
- **What this does NOT fix:** row locks release at commit, so lock hold and rollback are fixed. The JDBC connection
  may still be checked out during `afterCommit`. The boundary map's open caveat
  (`wms2-transaction-osiv-boundary-map.md:178-184`, `DELAYED_ACQUISITION_AND_HOLD`, "not yet measured; SBDEV-4108
  carries the probe") applies to this callback too. If pool hold must also go, the print has to run after the
  service returns, in the non-transactional controller (see trade-offs).

## 5. Widening `HttpInTransactionArchTest` (instrument: ad-hoc ArchUnit 1.3.0 scan over `target/classes`, compiled
today after HEAD, on JDK 21. Positive control: it saw 273 tx-annotated methods, 299 Keycloak calls, 16 HttpRestService
calls and 19 PrintService calls repo-wide, so the matcher works)
Rule shape: tx methods, meaning direct `@Transactional`, meta-annotated, or class-level, that **directly** call the target.
| Target | Newly flagged @Transactional methods |
|---|---|
| `PrintService.cupsPrint` / `cupsPrintChecked` | **1:** `StockunitService.transferStock → cupsPrint @879`. This is the ticket's own site, so the rule goes green once the fix lands |
| any `PrintService.*` method | **+1:** `ReceivingService.receiveGoods → isPrintAvailable @386` (a CUPS `getPrinter` network probe in-tx, `PrintService.java:183-208`). **This grows scope**, so keep the rule to `cupsPrint*` unless you want it |
| `KeycloakService` / `MultiTenantKeycloakService` / `org.keycloak.*` | **0** |
| `HttpRestService` (existing rule) | 0 (consistent with the current green) |
- **No false positive from the fix:** anonymous-class and lambda bodies are separate, unannotated `JavaMethod`s,
  and `getMethodCallsFromSelf` does not descend into them. ReceivingService's existing `afterCommit` body passes today.
- **Existing blind spot worth closing while widening:** the rule uses `areAnnotatedWith(Transactional.class)`
  (`HttpInTransactionArchTest.java:66`), which misses the meta-annotation `@TenantTransactionalReadOnly`
  (used at `StockunitService.java:1390`; it wraps `@Transactional` at `TenantTransactionalReadOnly.java:16`) and
  class-level `@Transactional` (`PickLineRealignmentService.java:41`). My scan included both and found no extra hits,
  so closing the gap is free today.
- Transitive callers stay out of scope (javadoc `:27-31`). The one-hop scan found only
  `CancellationReversalService.completeReversal → transferStock @449`, which passes `printLabel=false`.

## Trade-offs
| Option | Pros | Cons |
|---|---|---|
| A. afterCommit/afterCompletion in transferStock (proposed + A1–A3) | no signature change; covers every caller; matches ReceivingService and the gate test as written | connection may still be held (unmeasured); operator loses the print-error message |
| B. return label bytes, print in the controller after the call | truly outside the tx (frees the connection) | changes the service's return type; ~20 test files stub/verify `transferStock`; every future printing caller must remember to print |
| C. keep the in-tx print, add a timeout | smallest diff | a CUPS outage still rolls back moves; still violates the rule |
Go with A now. Revisit B only if the SBDEV-4108 connection probe shows the afterCommit hold matters.
