head: 350192f6b13ab27c2858bc0e93dcbe31ed0ec513

# SBDEV-3362: scoped re-review of fix commit 350192f6 (code-reviewer lane, not the author)

- **Scope:** `git show 350192f6` only. That is 6 files, +322/−15. It answers `code-review.md`, which covered L1–L9 plus one Open Question.
- **Tree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3362`. Read-only. I did not run mvn.
- **Evidence I read myself:**
  - `target/failsafe-reports/TEST-…CustomerorderForceCancelOutboxIntegrationTest.xml` (21:04, 2 tests / 0 fail / 0 err). Its log line 246 shows the collision that actually occurred: `Unique index or primary key violation: "public.CONSTRAINT_INDEX_9 ON public.outbox_message(idempotency_key …) VALUES ('CO-CANCELLED-4')"`.
  - Unit strictness is `@MockitoSettings(strictness = LENIENT)` (`CustomerorderServiceUnitTest:60`).
  - The OMS side: `origin/main:app/Services/Legacy/LegacyPositionCancelService.php:206-224`.
- **Not independently verified:** the 7169/0/1 unit-lane total and the M1–M4 mutant kills. Where noted below, I checked those claims for consistency by reading the code.

## Verdict: APPROVE

There are no High or Medium findings. There are 5 new Lows (N1–N5).

| Severity | Count |
|---|---|
| High | 0 |
| Medium | 0 |
| Low (new) | 5 |

## Per-finding disposition

| # | Status | Evidence |
|---|---|---|
| **L1** OMS pre-QA CLUB entry untested | **ADDRESSED** | `cancelOrder_omsInitiatedPreQaClubForceCancel_enqueuesOneCancellationSignal` sets `clubBatch.setType(CLUB)` and calls `cancelOrder(testOrder, false)`. `findByIdForUpdate` is unstubbed, so it returns `Optional.empty`, and `clubRunCancellationBlockingState` returns null. `isOmsPreQaPackedCancellationAllowed` reads `findById(1L)` and gets CLUB. The test asserts `times(1)` and the literal key. A mutant that makes the CLUB predicate false throws `BusinessException("…not a pre-QA club order")`, so the test goes red. |
| **L2** gate false-direction and dead-arm emission unpinned | **ADDRESSED** | `forceCancelOrder_shouldNotEnqueue_whenNeitherArmCancels` sets FINISHED (700), which is outside `< 650` and outside `{650, 670}`. Nothing between the arms and the gate throws (`save` and `finalizeBatchIfComplete` are mocks), so control does reach `:547`. That test is non-vacuous. `forceCancelOrder_belowPackedArm_enqueuesOneCancellationSignal` pins the dead arm's emission. Detail on why the reflection test is sound is under N-check A below. |
| **L3** key compared to its own constant | **ADDRESSED** | `:3033` now reads `.isEqualTo("CO-CANCELLED-100")`, and the three new tests use the literal too. |
| **L4** "two sites / two emitters" siblings | **PARTIAL** | All four code comments were rewritten to state the rule: `PickingorderBusinessService:753-756`, unit tests `:3682-3684` and `:3714`, and `PickingorderBusinessServiceUnitTest:2926-2929`. Integration map §2.3: the Condition cell is corrected, a force-cancel row was added (`:114`), and the SBDEV-3332 note (`:145-152`) states the rule. **Missed:** `wms2-oms-integration-map.md:351` still says `CustomerorderService.cancelOrder() uses WEBSERVICE_STOCK_COUNT_URL_KEY for its cancellation notification — this is a known inconsistency`. That is the same false claim the author just corrected at `:113`, now left standing in the troubleshooting table (see N4). The cancel-cascade §6 "the two real emitters" and "two producers" are still correct as a count of *source sites* (the helper plus `cleanUpCancelledOrder`), so I am not flagging them. |
| **L5** WmsConstants lacks the cancel-vs-cancel trade | **ADDRESSED** | New paragraph at `WmsConstants:565-571`. I checked its claims. There is no `@Version` on `Customerorder` (grep finds none). The batch `findByIdForUpdate` runs before the CLUB type check, so it serialises the two cancels. The second request's remaining orders are aborted: `OrderRestController:613` `catch (Exception e)` rethrows `WebserviceBusinessExceptionClientSide`. The paragraph is accurate. |
| **L6** new over-long enumerating comment line | **ADDRESSED**, with a sibling regression | `CustomerorderService:818-820` now states the rule and is under 120 chars. However, the same kind of line was **introduced** at the sibling site; see N3. |
| **L7** opaque failure on null `orderbatchId` | **PARTIAL** | `Objects.requireNonNull(..., () -> "customerorder " + id + " has no orderbatch_id; …")` is in, and it is pinned by `cancelOrder_nullOrderbatchId_failsWithNamedMessage` (`isInstanceOf(NullPointerException.class).hasMessageContaining(...)` plus `never()` enqueue). The second half of the fix was not done. The review asked for a clause at `forceCancelOrder:538` explaining why *that* guard exists. It still reads `if (customerOrder.getOrderbatchId() != null) { finalizeBatchIfComplete… }` with no comment. So there is still a null guard followed, ten lines later, by a hard NPE on the same field (N2). |
| **L8** no real-DB test of the force emission | **ADDRESSED**, with an overclaim | `CustomerorderForceCancelOutboxIntegrationTest` exercises the real `OutboxService.enqueue` (MANDATORY) reached through `cancelOrder` → `forceCancelOrder`, the IDENTITY insert, the commit together with CANCELED, and a wholesale rollback on collision. The DB is **H2** (`BaseRollbackIntegrationTest`: `jdbc:h2:mem:rollback_tenant;MODE=PostgreSQL`, `ddl-auto=create-drop`), not Postgres. The constraint it hits is the Hibernate-generated `CONSTRAINT_INDEX_9` from `@Column(unique = true)` (`OutboxMessage:75`), not V2.2.00's `uk_outbox_message_idempotency_key`. Adequate for T2. The javadoc's "real database" overclaims; see N5. |
| **L9** commit message omits the two behaviour changes | **DEFERRED-TO-PR** | See the PR-body requirements below. |
| **Open Question** (already-CANCELED positions re-released by OMS) | **RESOLVED: not a defect** | `cancelOrderItemParcel` is an atomic claim: `OrderItemParcel::where(id)->where(qa_status IS NULL OR != STATUS_CANCEL)->update(['qa_status' => STATUS_CANCEL])`, then `if ($claimed === 0) return;` *before* `returnInventoryToAvailable`. A position that is already cancelled releases nothing. `updateParcelStatusIfAllItemsCancelled` is guarded on the transition in the same way (SBDEV-2685). The author's answer is correct. |

### L9: the PR body must say
1. **The accepted trade.** Two overlapping cancels of one PACKED/PALLETIZED CLUB order used to both return 200, with the second silently re-force-cancelling. Now the second rolls back on the `CO-CANCELLED-<id>` key and returns an error. In `OrderRestController.cancelPositions` it also aborts the rest of that request's orders. Retry self-heals: `isAlreadyCancelled` short-circuits. Recorded as Nam, 2026-09-26.
2. **New failure points on the force path.** A missing `Itemdata` (`itemData.getItemNr()` NPE), a null `CustomerorderPosition.amount` (`getAmount().intValue()`), a missing `CustomerorderBatch` row, or a serialisation `IOException` now roll back a force-cancel that used to succeed.
3. **The null-`orderbatch_id` failure** is now a named `NullPointerException`, replacing Spring Data's `IllegalArgumentException` (translated to `InvalidDataAccessApiUsageException`). This makes no difference to callers (see N-check C).
4. **The reconciliation note.** Orders force-cancelled before deploy never get a signal retroactively. Signature: `state = 800 AND parcel_id IS NOT NULL`.
5. **Test evidence**, stated with its limits. The unit-lane total and the 2/2 IT class. The IT runs on H2 and hits the Hibernate-generated unique index, not the Flyway-named constraint.

## Fresh review of 350192f6: the questions the brief asked

**A. Does the neither-arm reflection test really reach the gate? Yes.**
- `arrangeForceCancel(PACKED)` then `setState(FINISHED)`:
  - `:417` reads positions.
  - `700 < 650` is false.
  - `700 == 650 || 700 == 670` is false.
  - `transferlaneId` is null.
  - `customerorderRepository.save` (mock).
  - `finalizeBatchIfComplete(1L)` (mock).
  - Then the gate.
- Any throw would surface as `InvocationTargetException` and fail the test, so a green result proves the gate ran. The class is LENIENT, so the unused parcel and item stubs raise no `UnnecessaryStubbingException`.
- Under M1 (the gate replaced by `true`), the helper runs to completion. Item 7, batch 1, and the sysprops are all stubbed, so `enqueue` is called and `never()` goes red. That is consistent with the author's M1 claim.
- The `< PACKED` arm test is also sound. `pickingtoteId = null` skips the tote block. The empty picking positions keep `pickingOrder` null, so `finishPickingOrder` is not called.

**B. Does the IT's rollback test exercise a key collision, not some other failure? Yes at runtime; no in the assertion.** See N1.
- The report's log (`:246`) shows the unique violation on `'CO-CANCELLED-4'`.
- There is a differential control: the sibling test runs the identical order shape with the key free and commits.
- But `assertThatThrownBy(...).as("…")` asserts only that *something* was thrown. Any other failure would also leave the order PACKED and the row count at 1, and the test would stay green. Examples: a future NPE in the payload build, or a changed `finalizeBatchIfComplete` precondition. The "positive control is the test above" argument holds only while that other test is green, and it does not prove *this* test failed for the reason it names.

**C. Is the `requireNonNull` NPE a behaviour change for any caller? No.**
- `UtilRestController.resetOrdersInReleasedStatus:1089` catches only `BusinessException | FacadeException`. Neither the old `IllegalArgumentException` / `InvalidDataAccessApiUsageException` nor the new NPE was ever caught there: both escape the loop, and both roll back `cancelOrder` as RuntimeExceptions.
  - Also, that endpoint iterates ASSIGNED orders, which take the direct branch. Its own `:1095` `findById(customerOrder.getOrderbatchId())` would fail on a null id anyway.
- `OrderRestController.cancelPositions:613` has a `catch (Exception e)` that maps both to `GENERIC_ERROR`.
- `RestExceptionHandler` has no handler for NPE, IAE or DataAccessException.
- Result: the same outcome, with a better message.

**D. Do the new `@MockitoBean UnitloadRepository` / `UnitloadBusinessService` break anything in the Spring context? No new hazard.**
- The mock set becomes part of the context-cache key, so this class gets its own context, and other classes never see the mocks.
- 12 other `BaseRollbackIntegrationTest` subclasses already declare their own `@MockitoBean` sets. So several contexts sharing the one `jdbc:h2:mem:rollback_tenant;DB_CLOSE_DELAY=-1` DB under `create-drop` is a pre-existing condition, not introduced here. Each class's `setUp` re-seeds, and this one `deleteAll()`s the outbox.
- A mocked `UnitloadRepository` also drops it from Spring Data REST's repository set in *this* context only. No test in this class uses SDR.
- Nothing else on the cancel path depends on a real unitload: `isShippedOrPastCancellationBoundary` uses the real `stockunitRepository`, which returns empty for parcel 900.

**E. Are the rewritten comments accurate?** Mostly yes. The exceptions are N3 (formatting), N4 (doc line 351) and N5 (the IT javadoc).

## New findings

### N1 [Low]: the rollback IT does not assert why it threw
**File:** `src/test/java/net/aim_ai/wms/integration/CustomerorderForceCancelOutboxIntegrationTest.java:190-191`
**Confidence:** HIGH

```java
assertThatThrownBy(() -> customerorderService.cancelOrder(order, true))
    .as("the duplicate key must fail the force-cancel, not be swallowed");
```

- **Issue:** `.as()` is only a description, and the assertion checks nothing about the type. The test's name and javadoc claim "whose key is already taken", but any exception satisfies it. The sibling in the same package already sets the convention: `CustomerorderOutboxIntegrationTest:246` uses `.isInstanceOf(DataIntegrityViolationException.class)`.
- **Fix:** `.isInstanceOf(DataIntegrityViolationException.class)`. Optionally also add `.rootCause().hasMessageContaining("idempotency_key")`. Per the memory rule, do not assert on a script filename or bare column text for Flyway; here the H2 message names the column, and Postgres would name `uk_outbox_message_idempotency_key`. Then mutation-check it by removing the pre-seeded row, and confirm the test goes red.

### N2 [Low]: `forceCancelOrder:538` null guard is now contradicted by the helper's hard fail (L7 second half)
**File:** `src/main/java/net/aim_ai/wms/service/CustomerorderService.java:538-548`
**Confidence:** HIGH

```java
if (customerOrder.getOrderbatchId() != null) {
    customerorderBatchService.finalizeBatchIfComplete(customerOrder.getOrderbatchId());
}
...
enqueueCancellationSignal(customerOrder, coPositions);   // → requireNonNull(orderbatchId)
```

- **Issue:** with a null id, the method politely skips finalization and then NPEs nine lines later. A reader cannot tell which of the two lines states the real contract. The first review asked for a clause here; it was not added.
- **Fix:** add the one-line comment ("defensive for test fixtures only; orderbatch_id is NOT NULL, and enqueueCancellationSignal fails loud on it"), or drop the guard. Dropping it touches `forceCancelOrder_transferOrderWithLane_*`-style fixtures, so a comment is the cheaper option.

### N3 [Low]: new 162-char comment line in the sibling, the same defect L6 fixed in the helper
**File:** `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java:756`
**Confidence:** HIGH

```java
// per customer order; every cancel path emits that one business event, not its own. uk_outbox_message_idempotency_key UNIQUE (idempotency_key) in
```

- **Fix:** rewrap at about 100 chars, as the surrounding block is.

### N4 [Low]: integration-map troubleshooting row still asserts the refuted `WEBSERVICE_STOCK_COUNT_URL_KEY` claim
**File:** `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md:351`
**Confidence:** HIGH

> `…also note CustomerorderService.cancelOrder() uses WEBSERVICE_STOCK_COUNT_URL_KEY for its cancellation notification — this is a known inconsistency`

- **Issue:** the helper reads `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY` (`CustomerorderService:809`). `CustomerorderService.java` contains no `WEBSERVICE_STOCK_COUNT_URL` reference. The same doc's `:113` now says this claim was refuted, so the doc contradicts itself. This is the "retitling leaves the rule asserted below it" pattern.
- **Fix:** delete the clause, or rewrite the row's hint to "check `WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY` (no activation gate, §10 item 6 of the cancel-cascade doc)".

### N5 [Low]: the IT javadoc says "real database"; it is H2 and a Hibernate-generated index
**File:** `CustomerorderForceCancelOutboxIntegrationTest.java:41`
**Confidence:** HIGH

```java
 * SBDEV-3362 — the force-cancel path's outbox row, against a real database with real commits.
```

- **Issue:** the commits are real, but the database is H2 in PostgreSQL mode under `create-drop`. The uniqueness comes from `@Column(unique = true)`, as the report's `CONSTRAINT_INDEX_9` shows, not from V2.2.00's `uk_outbox_message_idempotency_key`. So this test would stay green if the Flyway constraint were dropped from production. Its guarantee is about the entity mapping and the transaction wiring, not the production schema.
- **Fix:** reword it: "against an H2 (PostgreSQL mode) database with real commits; the unique index here is Hibernate's from `@Column(unique = true)`, not the Flyway constraint". The sibling `CustomerorderOutboxIntegrationTest:244`'s `.as("uk_outbox_message_idempotency_key must refuse…")` has the same pre-existing overclaim, which is out of scope here.

## Positive observations
- Every new test either carries a control assertion (the state is really CANCELED, or really still FINISHED) or pins by literal. None relies on a bare `verify`.
- The OMS-path test exercises exactly the production route, including the `findByIdForUpdate`-returns-empty subtlety, and the comment says so.
- `requireNonNull` uses the `Supplier` overload, so the message string is not built on the happy path. The `orderbatchId` local also removes the double getter call inside the `orElseThrow` lambda.
- The WmsConstants trade paragraph is precise about *why* the second request sees stale state (no `@Version`), which is the detail a future fixer needs.
- The Open Question was answered with a checkable citation, and the citation checks out.

## Recommendation
**APPROVE.** Fix N1–N5 in the same pass, per the house rule on Lows. N1 and N4 are the two worth doing before the PR. Put the five L9 items in the PR body.
