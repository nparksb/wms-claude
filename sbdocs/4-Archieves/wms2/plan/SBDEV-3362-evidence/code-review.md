head: fb6027e69c9abaad604c059b0ae9466787cf03bf

# SBDEV-3362: independent code review (code-reviewer lane)

- **Tree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3362`, branch `bugfix/SBDEV-3362-force-cancel-notify-oms`, one commit `fb6027e6` on top of `origin/develop` `d9be4188`. I checked that the merge-base is the current `origin/develop`.
- **Diff:** `git diff origin/develop...HEAD`. It touches 3 files: `CustomerorderService.java`, `WmsConstants.java` and `CustomerorderServiceUnitTest.java`.
- **What I did not do:** I did not run mvn (the lane rule). I did not run lsp_diagnostics. For compile and test evidence I am relying on the author's reported `mvn clean test` result: 7165 run, 0 fail, 1 skip. I did not modify the tree.
- **Architect consult:** read. I am not re-litigating its settled points: the one-emitter analysis, the unguarded `orderbatchId`, and the accepted concurrent-duplicate trade.

## Verdict: APPROVE

There are no High or Medium findings. There are 9 Low findings and 1 Open Question. All 9 Lows are cheap, and per the house rule they should be fixed in this pass.

| Severity | Count |
|---|---|
| High | 0 |
| Medium | 0 |
| Low | 9 |
| Open Question (low confidence) | 1 |

---

## Stage 1: spec compliance — PASS

| Requirement (ticket and Nam's 2026-09-26 decision) | Evidence | Result |
|---|---|---|
| Extract the payload build and enqueue into `private enqueueCancellationSignal(order, positions)` | `CustomerorderService.java:777` | ✅ |
| cancelOrder's direct branch calls it, with unchanged behaviour | `:1092`, at the same point as before (after `save` and `finalizeBatchIfComplete`) | ✅ **Checked mechanically:** I extracted the removed block and the new helper body from the diff and ran `diff` on them. The only difference is one comment (the "these two sites" sentence). The code is byte-identical, including the `orElseThrow` supplier, the `IOException` arm, the metric tags and the `FacadeException` rethrow. |
| forceCancelOrder calls it at the end, after `save` and `finalizeBatchIfComplete`, gated on `CANCELED` | `:536-549` | ✅ |
| Same process type and the same `CO-CANCELLED-<id>` key | The helper is the single site | ✅ (by construction) |
| Positions read hoisted to the top of forceCancelOrder | `:417` | ✅ |
| Stale comments updated | `:514-515`, `:866-867`, `WmsConstants:516-521`, test javadoc `:2921-2923`, and the workflow doc §6, §9.7, §10.8 | ✅ Partial; see L4 |

Nothing extra is in the change: no unrelated edits and no new behaviour beyond the ticket.

## Stage 2: correctness notes (no defects found)

- **The hoist and the dead `< PACKED` arm.** Both arms began with the identical `findByOrderId`, and nothing between the method entry and those reads writes anything. So the hoist changes nothing in either arm.
  - The one observable difference is for a state that is in neither arm (for example 660, or anything above 670, reachable only by reflection). That case now does one extra read that is never used. The gate then correctly suppresses the enqueue. This is not a defect.
  - The dead arm now **also emits** the signal, because it sets `CANCELED` and the gate passes. The architect showed that `finishPickingOrder`, run earlier in that arm, cannot emit the key. So this is correct under the "every path that cancels owes one signal" rule, but no test pins it (see L2).
- **Ordering.** The sequence is save, then finalize, then enqueue, which matches the direct branch. The enqueue is the last statement before `cancelOrder`'s `return`. Every failure the helper can raise rolls back the whole force-cancel:
  - `EntityNotFoundException extends RuntimeException`
  - `FacadeException`, which is in `rollbackFor`
  - `DataIntegrityViolationException`, raised at the IDENTITY insert
  - the same failures from `itemdataService` and `getAmount()`

  Nothing is left half-committed.
- **Throws clause.** `forceCancelOrder` already declared `throws FacadeException, BusinessException`, so the helper's `throws FacadeException` propagates with no signature change. `cancelOrder` already declares both.
- **The gate expression.** `customerOrder.getState() == WmsConstants.State.CANCELED` compares an `Integer` with `public static final int CANCELED = 800` (`WmsConstants:128`). That unboxes to an int compare. It is not the boxed-Long reference-compare trap, which breaks above 127. A null state would NPE, but it would already have NPE'd at `:419`.
- **The payload includes already-CANCELED positions.** This is the same as the direct path, which also passes the full pre-loop list. See the Open Question.

---

## Findings

### L1: the only live entry into force-cancel has no signal test
**File:** `CustomerorderServiceUnitTest.java:3019`, `:3048`

```java
customerorderService.cancelOrder(testOrder, true);
```

- **Issue:** both new tests enter with `cancellationFromWithinWMS = true`. The architect (§2) established that both production callers pass `false`, so the **only** production route into `forceCancelOrder` is `isOmsPreQaPackedCancellationAllowed`, meaning a CLUB batch read through `customerorderBatchRepository.findById`. The tests therefore prove the signal on a path with zero production callers.
  - The code after the gate is shared, so today this is a gap in coverage, not a hidden defect.
  - Consider a future change that makes the CLUB/OMS route stop reaching `forceCancelOrder` (for example, reordering the `||` or tightening `isOmsPreQaPackedCancellationAllowed`). It would lose the signal for every real force-cancel, and both new tests would stay green.
  - The fixture's `new CustomerorderBatch()` / `batch` has type `null`, so it is not a CLUB batch either.
- **Fix:** add one more parameter row, or a third test, that sets `batch.setType(WmsConstants.OrderBatchType.CLUB)` with a batch state that `clubRunCancellationBlockingState` does not block, and calls `cancelOrder(testOrder, false)`. Assert `times(1)` enqueue with the same key. The stub `findById(1L)` serves both the gate read and the helper read.

### L2: the gate's false direction, and the dead arm's emission, are unpinned
**File:** `CustomerorderService.java:547`

```java
if (customerOrder.getState() == WmsConstants.State.CANCELED) {
```

- **Issue:** no test reaches the end of `forceCancelOrder` with a state that is not `CANCELED`. So replacing the `if` with `true` survives every test.
  - PIT's DEFAULTS group has no REMOVE_CONDITIONALS mutator, so the "all new-line mutants killed" claim does not cover this mutant. `NEGATE_CONDITIONALS` is killed; `==`→`true` is never generated.
  - The two reflection tests (`AC-13` at `:3296`, `AC-5` at `:4047`) do drive the dead arm to `CANCELED`, and now emit. But neither asserts on `outboxService`, so the dead arm's new emission is unpinned in both directions.
- **Fix:** add a reflection test that sets the state to, for example, `WmsConstants.State.SHIPPED` (or any value in neither arm) and asserts `verify(outboxService, never()).enqueue(any())`. Optionally add `verify(outboxService).enqueue(any())` to AC-13 so the dead-arm emission is a stated contract rather than an accident.

### L3: the key assertion compares the constant with itself
**File:** `CustomerorderServiceUnitTest.java:3031-3033`

```java
assertThat(msg.getIdempotencyKey())
    .as("must share the ordinary path's key, or two emitters of one event can both land")
    .isEqualTo(WmsConstants.CANCELLED_IDEMPOTENCY_KEY_PREFIX + 100L);
```

- **Issue:** the expected value is built from the same constant as production. Changing the prefix's value, for example `"CO-CANCEL-"`, stays green here. The architect's suggested mutation ("change the prefix at one site") is only meaningful against a literal.
  - The sibling SBDEV-3332 test uses the literal: `:3638`, `.isEqualTo("CO-CANCELLED-100")`.
  - So the value is pinned elsewhere and this is not a gap in the suite. It is only this test's message that overclaims.
- **Fix:** use `isEqualTo("CO-CANCELLED-100")`, matching the sibling. That also pins the property that cleanUpCancelledOrder and OMS reconciliation depend on.

### L4: the sibling sweep missed five comments that still count "two sites / two emitters"
The change fixed `WmsConstants` and the helper's own comment. These siblings still frame the invariant as two sites, and their framing contradicts the new three-caller shape:

| Where | Quoted |
|---|---|
| `PickingorderBusinessService.java:753-756` | `deliberately the SAME key CustomerorderService .cancelOrder writes. ... those two sites are two emitters of one business event` |
| `CustomerorderServiceUnitTest.java:3604-3607` | `these two sites are two emitters of one business event, not two events` |
| `CustomerorderServiceUnitTest.java:3636-3637` | `"... the same key cleanUpCancelledOrder writes, so the two emitters cannot both land"` |
| `PickingorderBusinessServiceUnitTest.java:2926-2928` | `The key is shared with {@code CustomerorderService.cancelOrder}'s enqueue on purpose ... those two sites are two emitters` |
| `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` §2.3, SBDEV-3332 note (≈:145-152) | `Both CustomerorderService.cancelOrder and PickingorderBusinessService.cleanUpCancelledOrder set idempotencyKey ... the two sites are two emitters`. §2.3's table also has no force-cancel row. |

- **Assessment:** none of these is *false* in a way that misleads a caller, because the force path does run inside `cancelOrder`. But they are exactly the "counts emitters" prose the brief asked me to sweep for.
- **A second, pre-existing error:** the first §2.3 table row says `Only when cancellationFromWithinWMS=true; uses WEBSERVICE_STOCK_COUNT_URL key`. The note directly below that table says both halves are wrong.
- **Fix:** restate each as the rule ("every path that takes an order to CANCELED emits one, under this key"), as `WmsConstants` now does. In the integration map, add force-cancel (via `enqueueCancellationSignal`) to the §2.3 producers and correct the stale Condition cell.

### L5: the WmsConstants concurrency paragraph does not record the newly accepted trade
**File:** `WmsConstants.java:551-563`

```
Concurrently it can: finishPickingOrder locks the customer order ... but cancelOrder locks only the batch ...
```

- **Issue:** this javadoc is the place every emitter points to "for the concurrent failure mode". It describes only the `finishPickingOrder` versus `cancelOrder` race.
  - The trade Nam accepted for this ticket is architect Scenario A: two concurrent cancels of one PACKED CLUB order. The batch lock serialises them, but the second holds a stale detached entity at 650, and so it now gets a 500 instead of a silent 200.
  - That trade is recorded only in the workflow doc (§9 item 7), not in code.
  - The next person to read "Sequentially a collision cannot happen" will not learn that a double-sent OMS cancel of a packed club order now fails the second request, and aborts the rest of that request's loop.
- **Fix:** add a short paragraph: "Also `cancelOrder` versus `cancelOrder` on a PACKED/PALLETIZED CLUB order (SBDEV-3362): serialised by the batch lock, but the second caller's entity was loaded outside the transaction at 650. It re-runs `forceCancelOrder` and rolls back on the key. Accepted, Nam 2026-09-26."

### L6: new comment line is a prose enumeration and over-long
**File:** `CustomerorderService.java:815`, 133 chars

```java
// order (this helper's two callers and cleanUpCancelledOrder) emits the one business event. The UNIQUE constraint on
```

- **Issue:** this is the one line the move changed. It reintroduces a count ("two callers"), which rots the same way the "two sites" text just did. It is also the only *new* line above 120 chars in the helper; lines 799, 805 and 824 are moved code.
- **Fix:** rewrap it, and state the rule: "every path that takes an order to CANCELED emits this one business event under this key."

### L7: helper javadoc's "no guard" rationale is correct, but the failure it leaves is opaque
**File:** `CustomerorderService.java:774-775`, `:798`

```java
 * <p>Deliberately no {@code orderbatchId != null} guard: the column is NOT NULL, ...
CustomerorderBatch orderBatch = customerorderBatchRepository.findById(customerOrder.getOrderbatchId()).orElseThrow(...)
```

- **Issue:** I agree with the architect: do not skip silently. But with a null id, Spring Data's `findById(null)` throws `IllegalArgumentException("The given id must not be null")` **before** `orElseThrow`. So the `EntityNotFoundException("CustomerOrderBatch", …)` the code seems to promise never fires.
  - Only test-constructed entities can reach this, which is why it is Low.
  - Meanwhile `forceCancelOrder:538` *does* guard the same id before `finalizeBatchIfComplete`. A reader sees the two disagree within 10 lines.
- **Fix:** optionally use `Objects.requireNonNull(customerOrder.getOrderbatchId(), "order " + id + " has no orderbatchId; cannot build cancellation signal")` so it fails loud with a named cause. Also add one clause at `:538` saying that guard exists only for test fixtures (architect §2).

### L8: no real-DB test of the force-cancel emission
- **Issue:** both new tests mock `OutboxService`. So `Propagation.MANDATORY`, the IDENTITY insert, and `uk_outbox_message_idempotency_key` are never exercised for the force path.
  - `CustomerorderOutboxIntegrationTest.cancelOrder_secondCancellationRowForTheSameOrderIsRefused` covers the constraint for the direct path only.
  - `git grep` finds no IT that cancels a PACKED/PALLETIZED order and inspects `outbox_message`.
  - The accepted trade (a second force-cancel rolls back) is therefore also untested anywhere.
- **Fix:** optional, since this is T2 and the code after the enqueue is shared. One IT in `CustomerorderOutboxIntegrationTest` would pin the force path's commit: a PACKED CLUB order, `cancelOrder(order, false)`, then assert exactly one row with key `CO-CANCELLED-<id>`.

### L9: commit message omits the two behaviour changes the architect asked to call out
**File:** commit `fb6027e6` message.

- **Issue:** the message describes the fix and the fixture stubs. It does not mention either of these:
  - **(a) The accepted trade:** a concurrent duplicate cancel of a PACKED club order now returns 500 and rolls back, where it used to succeed silently.
  - **(b) New failure points on the force path** (architect §2): a missing `Itemdata`, or a null `CustomerorderPosition.amount`, now rolls back a force-cancel that succeeds today.

  Both are real changes to observable behaviour.
- **Fix:** put both in the PR body; amending the commit is optional.

---

## Open Questions (low confidence; not blocking)

### [Medium] Already-CANCELED positions are included in the payload that tells OMS to release allocation
**Confidence:** LOW

- **Where:** `CustomerorderService.java:779`, `coPositions.stream().map(...)` over the full `findByOrderId` list.
- **Question:** the force path sends every position, including any that were already CANCELED before this cancel. That is parity with the direct path, which passes the pre-loop list including SBDEV-3363's skipped positions, so it is not new in kind.
  - The new commentary says `LegacyPositionCancelService.cancelOrderItemParcel is what releases` the OMS allocation. If a position's release is not idempotent on the OMS side, a position cancelled earlier and then re-listed here could be released twice.
  - I did not read the OMS side, `v2/oms-laravel-api`, so this needs confirmation from there.
- **Fix, if confirmed:** filter positions whose state was `CANCELED` *before* this transaction. That means capturing them before the arm's loop sets them, and it has to be done in both callers so the two paths stay identical.

---

## Fixture stub additions: do any mask a regression? No.

| Test | Stub added | Assessment |
|---|---|---|
| `forceCancelOrder_transferOrderWithLane_clearsTransferlaneId` (`:1351`) | `customerorderBatchRepository.findById(1L)` → `new CustomerorderBatch()` | Entry is `cancelOrder(…, true)`, so `isOmsPreQaPackedCancellationAllowed` short-circuits and never reads `findById`. `clubRunCancellationBlockingState` uses `findByIdForUpdate`, which is unstubbed. The stub therefore reaches only the helper. No assertion changed and no existing behaviour is hidden. |
| SBDEV-3332 force-cancel flag tests (`:2898`, `:2948`) | `itemdataService.getById(any())` → `new Itemdata()` | Used only by the helper's position map. A null `itemNr` in the payload is irrelevant to the flag assertions. `any()` is broad, but these tests make no claim about item lookups. |
| `AC-13` null-pickingtoteId (`:3303`) and `AC-5` null-entityLock (`:4061`) | `findById(1L)` → `new CustomerorderBatch()` | Reflection into the dead arm. The positions list is empty, so the helper builds an empty-positions payload. The existing assertions (tote lookup skipped, no NPE) are untouched. The stub is needed because the dead arm now emits; see L2 for making that explicit. |

None of these stubs sits where a regression in the original assertions would be absorbed. Each feeds only the new tail of the method.

## Positive observations
- **One helper instead of a second hand-copy.** This is the invariant-over-instance fix, and the javadoc says why ("a second hand-copy of this block is how a path ends up owing zero").
- **The moved block is byte-identical in code.** I verified this with a mechanical diff, not by eye.
- **The gate on `CANCELED`** stops an order that neither arm touched from being reported cancelled. It is also correct for the dead arm.
- **The helper is unguarded on `orderbatchId`,** as the architect recommended. The fixtures were stubbed rather than a null guard being added to make them pass, which was exactly the anti-pattern the architect warned about.
- **The new tests have a control assertion,** "the order really took the force-cancel path". They use `times(1)` rather than a bare `verify`. The payload test parses JSON with `findPath`, and a comment explains the MissingNode `asInt()` trap.
- **The docs were updated in the same change:** the workflow doc §6, §9.7 and §10.8, including the "orders force-cancelled before deploy will never get a signal" reconciliation note and its signature query.
- **`MANDATORY` propagation is documented** in the helper javadoc, as the architect asked.
