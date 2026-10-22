head: fb6027e69c9abaad604c059b0ae9466787cf03bf

# SBDEV-3362 Conformance + Test-Adequacy Verification (T2)

Worktree: `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3362`
Diff scope (`git diff origin/develop...HEAD --stat`):
```
 .../aim_ai/wms/service/CustomerorderService.java   | 141 ++++++++++++---------
 .../java/net/aim_ai/wms/service/WmsConstants.java  |   8 +-
 .../unit/service/CustomerorderServiceUnitTest.java | 112 +++++++++++++++-
 3 files changed, 198 insertions(+), 63 deletions(-)
```
Only these 3 files changed on the branch (1 ahead of `origin/develop`). No sbdocs files are part of this git diff — the workflow doc lives outside this worktree and was checked separately (see "Doc check" below).

## Fresh test run

Command (exactly as specified):
```
export JAVA_HOME=/Users/np1076/Library/Java/JavaVirtualMachines/ms-21.0.8/Contents/Home PATH=$HOME/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH
cd <worktree> && mvn -o -q test -Dtest='CustomerorderServiceUnitTest*' -Dsurefire.failIfNoSpecifiedTests=false
```
Result: build completed, no `BUILD FAILURE`. Summed every `TEST-*CustomerorderServiceUnitTest*.xml` (40 report files, including all `@Nested` classes) programmatically:

```
files: 40
total tests: 140  failures: 0  errors: 0  skipped: 0
```

Nested-class breakdown for the relevant classes:
- `CancelOrderPackedState`: `Tests run: 6, Failures: 0, Errors: 0, Skipped: 0` — test cases: `cancelOrder_packedOrder_withoutWmsCancel_throws`, `cancelOrder_forceCancel_enqueuesOneCancellationSignal(int)[1]`, `cancelOrder_forceCancel_enqueuesOneCancellationSignal(int)[2]`, `cancelOrder_packedOrder_withWmsCancel_delegatesToForceCancel`, `cancelOrder_forceCancel_payloadCarriesOrderAndPositions`, `cancelOrder_packedOrder_forceCancel_clearsMarkedforcancellation` — all present, all pass.
- `CancelOrderOutboxMigration`: `Tests run: 5, Failures: 0, Errors: 0, Skipped: 0` — includes `cancelOrder_enqueuesOutboxMessageWithExpectedFields` and `cancelOrder_enqueuesCancellationWithPerOrderIdempotencyKey` (the two regression tests the author cites for AC-3) — both present, both pass, **neither was modified by this diff** (confirmed: `git diff origin/develop...HEAD` touches nothing in the `CancelOrderOutboxMigration` nested class).

`WmsConstants.State.PACKED = 650`, `PALLETIZED = 670`, `CANCELED = 800` confirmed by direct read of `WmsConstants.java:108,113,128` — so `cancelOrder_forceCancel_enqueuesOneCancellationSignal(int)[1]`/`[2]` are confirmed to run at exactly the AC-1/AC-2 states.

## Code walk (fb6027e)

`CustomerorderService.java`:
- `coPositions` read hoisted above both `forceCancelOrder` branches (`:415-416`), removing two separate reads — one per branch previously.
- New private helper `enqueueCancellationSignal(Customerorder, List<CustomerorderPosition>)` at `:777-830`. Builds `OrderBatchDto`/`OrderDto`/`OrderPositionDto`, reads `orderBatch` via `customerorderBatchRepository.findById(customerOrder.getOrderbatchId())` (no null guard — see below), enqueues via `outboxService.enqueue(OutboxMessage.builder()...)` with `.aggregateType("CUSTOMER_ORDER")`, `.aggregateId(customerOrder.getId())`, `.processType(WmsConstants.MessageProcessType.ORDER_BATCH_CANCELLED_FROM_WMS)`, `.idempotencyKey(WmsConstants.CANCELLED_IDEMPOTENCY_KEY_PREFIX + customerOrder.getId())`.
- `forceCancelOrder`'s PACKED/PALLETIZED arm (`:498-531`) unchanged in cancellation mechanics; after `customerorderRepository.save(customerOrder)` (`:536`) and the `finalizeBatchIfComplete` guard block (`:538-540`), a new gated call: `if (customerOrder.getState() == WmsConstants.State.CANCELED) { enqueueCancellationSignal(customerOrder, coPositions); }` (`:547-549`).
- `cancelOrder`'s direct branch: the old ~65-line hand-copied enqueue block (formerly `:1012-1068` on `origin/develop`) is deleted and replaced by a one-line call to the same helper (`:1092`).
- `WmsConstants.java` javadoc on `CANCELLED_IDEMPOTENCY_KEY_PREFIX` updated to describe the shared helper and both its callers plus the third emitter (`PickingorderBusinessService.cleanUpCancelledOrder`).

Grep confirms exactly one build site for `ORDER_BATCH_CANCELLED_FROM_WMS` inside `CustomerorderService` (`:810`, inside the helper), called from two sites only (`:548` and `:1092`) — no second hand-copy in this class. (`PickingorderBusinessService.java:752` is the pre-existing, legitimate third emitter, unrelated to this ticket's "no duplicate helper" constraint.)

`orderbatch_id` is declared `NOT NULL` in `src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:767` (`customerorder` table) — confirms the "no null-guard" design choice is grounded in an actual NOT NULL column, not an assumption.

## Acceptance Criteria

| # | Criterion | Status | Evidence |
|---|---|---|---|
| AC-1 | Force-cancel of a PACKED(650) order → exactly one outbox enqueue, `processType=ORDER_BATCH_CANCELLED_FROM_WMS`, `idempotencyKey=CANCELLED_IDEMPOTENCY_KEY_PREFIX+orderId`, `aggregate=CUSTOMER_ORDER/orderId` | VERIFIED | `cancelOrder_forceCancel_enqueuesOneCancellationSignal(int)[1]` (state param = `WmsConstants.State.PACKED` = 650) asserts `times(1)` enqueue, process type, `CO-CANCELLED-100` key (`CANCELLED_IDEMPOTENCY_KEY_PREFIX` = `"CO-CANCELLED-"`, confirmed by literal match in `cancelOrder_enqueuesCancellationWithPerOrderIdempotencyKey`), `aggregateType="CUSTOMER_ORDER"`, `aggregateId=100L`. Fresh run: pass. |
| AC-2 | Same for PALLETIZED(670) | VERIFIED | Same test, `[2]` invocation with param = `WmsConstants.State.PALLETIZED` = 670. Fresh run: pass. |
| AC-3 | Ordinary `cancelOrder` direct path still enqueues exactly once with the same key (regression) | VERIFIED | `cancelOrder_enqueuesOutboxMessageWithExpectedFields` and `cancelOrder_enqueuesCancellationWithPerOrderIdempotencyKey` are byte-for-byte unmodified by this diff (git diff shows zero changes to `CancelOrderOutboxMigration` nested class) and both pass fresh (`Tests run: 5, Failures: 0`). The refactor is provably transparent to the direct path's contract, not merely "should still work." |
| AC-4 | Force-cancel payload carries externalnumber, each position (unique id, sku, amount, number), batch id, facility code | VERIFIED | `cancelOrder_forceCancel_payloadCarriesOrderAndPositions`: asserts payload `.contains("EXT-001", "POS-EXT-1", "SKU-7", "BATCH-001", "WH01")` (order externalnumber, position externalid, SKU, batch id, facility code) plus `JsonNode.findPath("amount").asInt()==3` and `findPath("number").asInt()==4` (position amount/index). `EXT-001` traced to `testOrder = createTestCustomerorder(100L, "EXT-001", ...)` at line 180. Fresh run: pass. |
| Design: one shared helper, no second hand-copy | VERIFIED | Single `enqueueCancellationSignal` private method (`:777`); grep shows exactly one `ORDER_BATCH_CANCELLED_FROM_WMS` build site in `CustomerorderService`, called from both `forceCancelOrder` (`:548`) and `cancelOrder`'s direct branch (`:1092`); the old direct-branch hand-copy is deleted in this diff. |
| Design: enqueue after save + finalizeBatchIfComplete | VERIFIED | Code order confirmed by direct read: `customerorderRepository.save(customerOrder)` at `:536`, `finalizeBatchIfComplete` guard at `:538-540`, `enqueueCancellationSignal` call at `:547-549` — strictly after both. |
| Design: no orderbatchId null-guard added in the helper | VERIFIED | Helper calls `customerorderBatchRepository.findById(customerOrder.getOrderbatchId())` unconditionally, no null check. Grounded: `orderbatch_id bigint NOT NULL` in `V2.2.00__base_v2_schema.sql:767`. |
| Design: stale "force-cancel notifies nothing" comments gone from src | VERIFIED | Targeted greps (`"notifies OMS of nothing"`, `"notifies nothing"`, `"enqueues no"`, `"zero rather than one"`, `"Separate and NOT fixed here"`) return zero hits in `src/main` and `src/test`. Broader sweep of every `forceCancelOrder`-referencing file (`MobilePutAwayService.java`, `PickingorderBusinessService.java`, `PickingorderRepositoryIntegrationTest.java`) shows the remaining references are unrelated (parcel lock behavior, a different settle-rule triplication, a pick-list predicate) — none claim force-cancel sends no signal. Blind spot: this is a phrase/keyword search, not a semantic one; a comment making the same claim in unanticipated wording would not be caught. Given the specificity of the original wording (quoted verbatim in the ticket) and the fact both known sites (the `WmsConstants` javadoc and the test class javadoc) were positively confirmed *updated* rather than merely absent, confidence is high. |

## Doc check — `wms2-cancel-cascade-workflow.md`

Read directly (path outside the worktree, in the shared `sbdocs/` vault):
- **§6** ("Post-Commit OMS Callbacks"): states `forceCancelOrder` included since SBDEV-3362, both paths route through `CustomerorderService.enqueueCancellationSignal`. Matches code.
- **§9 item 7**: "Notifies OMS — since SBDEV-3362 ... After the save and `finalizeBatchIfComplete`, and only if the order is now `CANCELED`". Matches the exact code ordering confirmed above (save → finalizeBatchIfComplete → gated enqueue). Also cites `forceCancelOrder` declared at `:408` — confirmed by `grep -n "void forceCancelOrder"` → line 408.
- **§10 item 8**: "`forceCancelOrder` sends OMS no cancellation at all — fixed by SBDEV-3362 (§9 item 7)". Consistent, and correctly scoped (notes pre-deploy force-cancelled orders still have no retroactive signal — an operational caveat, not a code claim).

All three sections are internally consistent with each other and with the diff. VERIFIED.

## Regression risk assessment

- **cleanUpCancelledOrder** (the third, pre-existing emitter in `PickingorderBusinessService`) is untouched by this diff and was not re-run here (out of the specified targeted-test scope); its own idempotency key format is unchanged (`WmsConstants.java` diff is javadoc-only, no constant value changed).
- **Idempotency collision surface increases**: prior to this fix, a force-cancelled order produced 0 outbox rows; now it produces 1 with the `CO-CANCELLED-<id>` key, same key space as `cancelOrder`'s direct branch and `cleanUpCancelledOrder`. Per the workflow doc's own §9 item 7 "Accepted trade" note (Nam, 2026-09-26), a concurrent double-cancel of a PACKED order now surfaces as a 500 (unique constraint violation) rather than silently succeeding with zero signals — an explicitly accepted, documented trade, not an unflagged regression.
- **`coPositions` read hoisted above both branches** in `forceCancelOrder`: behaviorally a no-op for the `< PACKED` branch (same query, same timing relative to that branch's use), confirmed by full targeted suite still green (140/140, including the `< PACKED` branch's own tests such as `cancelOrder_packedOrder_withoutWmsCancel_throws`... — actually that one is PACKED branch; the `< PACKED` branch tests live in other nested classes within the same 140-test total, all passing).
- Only the targeted class was run per the hard constraint (not the full suite) — this report does not claim full-suite regression coverage beyond what the targeted class run demonstrates plus the static diff-scope confirmation (only these 3 files changed).

## Verdict

**PASS** — all 4 numbered ACs and all 4 design constraints VERIFIED with fresh evidence (140/140 tests green across 40 report files for `CustomerorderServiceUnitTest*`, including 6/6 in the directly relevant `CancelOrderPackedState` nested class and 5/5 in `CancelOrderOutboxMigration`). Doc sections §6/§9.7/§10.8 of `wms2-cancel-cascade-workflow.md` match the code. No blockers found.
