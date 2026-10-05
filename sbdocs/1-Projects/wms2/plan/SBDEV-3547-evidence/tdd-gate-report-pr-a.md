# SBDEV-3547 — TDD gate baseline, PR-A (2026-09-27)

- **Branch:** wms2-api `bugfix/SBDEV-3547-a-visibility`, off freshly-fetched origin/develop `0ac108e2`
- **Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3547-a`. The executor must implement in this same tree.
- **Main-session re-run** (8 classes, `-Dtest=…`): `Tests run: 290, Failures: 9, Errors: 0, Skipped: 0`. That is 265 existing tests green plus 25 new, and the 9 failures are exactly the RED rows.
- **Skeletons (behaviour-free):**
  - `util/LockRefusalMessages` stubs: `describe` returns `String.valueOf`, `goodsOutHint` returns `""`.
  - `CustomerorderCancellationLogRepository.findPendingReversalsOnPallets`, with the §4 A3 JPQL exactly. The field names were verified and the method is not yet called.
  - `BillofladingService` gets a new constructor parameter, unused for now, and `BillofladingServiceUnitTest:145` gets a `@Mock`.
- ⚠ The constructor change is a Spring DI change, so the executor must gate it on `mvn clean compile` plus a context-load test.

| Test | Kind | AC | Failure line (verbatim) |
|---|---|---|---|
| UnitloadBusinessServiceUnitTest$SendToClearing.sendToClearing_recordsOrderNumberAsOrderNumber | RED | AC-SC | `[arg 8 (orderNumber) must carry the order number passed to sendToClearing] expected: "ORD-001" but was: null` |
| LockRefusalMessagesUnitTest.describe_pickedForGoodsout_namesPicked | RED | AC-4 | `expected: "100 (Picked)" but was: "100"` |
| LockRefusalMessagesUnitTest.describe_null_isUnknown (extra row) | RED | AC-4 | `expected: "null (Unknown)" but was: "null"` |
| LockRefusalMessagesUnitTest.goodsOutHint_namesContainerCancellationScreenAndOutboundManager (no "Waive") | RED | AC-4 | `Expecting actual: "" to contain: "TOTE-0042"` |
| StockunitBusinessServiceUnitTest$Sbdev3547_SourceLockRefusalText.transferStockToUnitLoad_lock100_messageNamesToteAndCancellationScreen | RED | AC-4 R1 | `… "Source stockUnit=10 is locked=100" to contain: "Source stockUnit=10 is locked=100 (Picked)"` |
| … .transferStockToUnitLoad_lock104_hasNoGoodsOutHint | GREEN | AC-4 | passes |
| SourceLockGuardUnitTest.stockunitAt100_messageCarriesGoodsOutHint (new class) | RED | AC-4 R2 | `… "Source stockUnit=10 is locked=100 (Picked)" to contain: "TOTE-0042"` |
| StockunitServiceUnitTest$NonTransactionalWritePathOrdering.adjustAmount_lock100_messageCarriesGoodsOutHint | RED | AC-D3 | `Expecting actual: "unexpected lock=100 found. value not changed" to contain: "UL-001"` |
| … .adjustAmount_lockTransfer_hasNoGoodsOutHint | GREEN | AC-D3 | passes |
| BillofladingServiceUnitTest$Sbdev3547_ShippedPalletPendingReversal.closeBOL_writesServiceLogAfterCommit_whenShippedPalletCarriesPendingReversal | RED | AC-5 | `Wanted but not invoked: messageService.createServiceLog(...)`. The fixture first proves it reached the bulk `UPDATE Stockunit` |
| … .finishTransfer_writesServiceLogAfterCommit_whenShippedPalletCarriesPendingReversal | RED | AC-5 | same |
| … .closeBOL_serviceLogNotWrittenBeforeAfterCommit | GREEN | AC-5 | passes |
| … .closeBOL_registersNothing_whenNoPendingRows | GREEN | AC-5 | passes |
| MoveSourceLockComparisonRailTest (main + 7 self-tests + 4 bookkeeping self-tests) | GREEN | AC-6 | passes. Scope 19; 8 offences; 8 keys, each matching exactly one site; allowlist control satisfied |

**Rail mutants.** These were throwaway edits to MobileMoveUnitloadService, restored from a /tmp copy; diff and hash-object were identical afterwards.
- (a) A bare `== ON_HOLD` throw in `checkReservedStock` fails with `UNLISTED offence MobileMoveUnitloadService.java#checkReservedStock:261 …`.
- (b) Deleting the :365 check fails with `STALE key …#scanDestination :: (stockUnit.getEntityLock() == …ON_HOLD) … matches no site`.
- (c) Duplicating :365 fails with `OVER-MATCH key … matches 2 sites`.
- **Not run:** the plan's 4th mutant (a lexer that drops NOT_LOCKED lines) was covered only by the synthetic self-test `missingAllowlistConjunctFailsTheControl`. The executor should run it as a real mutant.

**Deviations from the plan:**
1. `SourceLockGuardUnitTest` did not exist, so it was created in `unit/util/`. `SourceLockGuard.describe` already renders `100 (Picked)`, which means R2 is red only on the tote label and hint.
2. The cancellation log has no order-number field, so the BOL Service Log assertions check the log id, `customerorderId`, the tote and the BOL number.
3. Extra row `describe_null_isUnknown`, which pins null-safety.
4. EXEMPT key = file simple name + innermost enclosing method + whitespace-normalised condition, matched by exact equality. The census script had no method detection, so this was added.
5. Surefire lists the rail's top-level test under the `$BookkeepingSelfTests` XML.

**GREEN-guard mutation checks are deferred to the executor.** Their mutants, such as "make the hint unconditional", need the feature to exist first.
