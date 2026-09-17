---
title: "Critic review — SBDEV-3339 plan"
ticket: "SBDEV-3339"
lane: "critic"
graded_ref: "origin/develop @ 221caed1"
date: "2026-09-14"
verdict: "ITERATE"
tags: [review, critic, sbdev-3339]
---

# Critic review — `SBDEV-3339-cancelorder-picking-tote-teardown.md`

**Verdict: ITERATE.** Three blocking findings, four that should be fixed in the same pass.

Every code claim below was graded against `origin/develop` @ `221caed1` via
`git show origin/develop:<path>` / `git grep … origin/develop`. The local checkout was never read.
Test files were extracted from `origin/develop` to a scratch dir and read there.

The plan's *diagnosis* is sound and survives grading in full: the root-cause quote, the three-column
omission table, the day-one-not-a-regression chain, the `PICKED_FOR_GOODSOUT` producer census, the
`setEntityLock`-grep blind spot, the Fix-2 NPE mechanism and the §5.2 throw-source list are all
correct as stated. The problems are concentrated in **what the fix does not do** (H-1), **what the
plan promises the existing suite will do** (H-2), and **what Fix 3 changes that the plan does not
name** (H-3).

---

## HIGH — blocking

### H-1. Fix 1 copies only the first half of `cleanUpCancelledOrder`; the `pickingorder_unitload` teardown is dropped, and dropping it is what makes the tote unsafe to reuse

§5 Fix 1 says the block's "shape and ordering copied from `cleanUpCancelledOrder`". It copies the
block that ends at `customerOrder.setPickingtoteId(null);`. The sibling does not end there. Its last
act, in `PickingorderBusinessService.cleanUpCancelledOrder`, is:

```java
if (tote != null) {
    PickingorderUnitload pickingUnitLoad = pickingorderUnitloadService.getByLabel(tote.getLabelid());
    if (pickingUnitLoad != null) {
        pickingUnitLoad.setHistorytote(tote.getLabelid());
        pickingUnitLoad.setUnitloadId(null);
        pickingUnitLoad.setState(WmsConstants.State.CANCELED);
        pickingorderUnitloadRepository.save(pickingUnitLoad);
    }
}
```

`CustomerorderPositionService.cancelOrderPosition` does not touch `pickingorder_unitload` either — I
read it end to end on the `origin/develop` blob; it writes `pickingorder_position`, `pickingorder`
and `customerorder_position` only. So after Fix 1 the success branch leaves the row intact with
`unitload_id` still pointing at a tote that is now in Clearing, unlocked, and free to be picked into
again.

That `setUnitloadId(null)` is load-bearing, and the repo says so in its own words.
`PickingorderUnitloadRepository`:

```java
/**
 * findByUnitloadLabelid above returns Optional and blows up with
 * IncorrectResultSizeDataAccessException once a tote has been used twice —
 * this one is safe to call on a reused tote (SBDEV-2742).
 */
```

Two live `src/main` consumers sit on the *unsafe* finder: `PickingorderBusinessService:669`
(`pickingorderUnitloadService.getByLabel(tote.getLabelid())` — and `getByLabel` catches only
`NoSuchElementException`, so an `IncorrectResultSizeDataAccessException` propagates) and
`CustomerorderService:614` (`pickingorderUnitloadRepository.findByUnitloadLabelid(pickingTote.getLabelid())`,
on the `packageOrder` path). Separately, `ToteStateService.stillHoldsTote` —
`state < FINISHED && state != CANCELED` — will keep reporting the tote as assigned to the cancelled
order, because nothing sets that state to CANCELED on this branch.

Net effect: the fix as specified trades a stranded-stock defect for a tote-reuse-collision defect on
the same totes. It also falsifies §5.3's own justification —

> "The two branches of `cancelOrder` must leave identical state"

— which is the stated reason for choosing the unconditional clear. Under Fix 1 the two branches do
not leave identical state; they differ in exactly the row that governs reuse.

This is cheap to close: `pickingorderUnitloadRepository` is **already** a `private final` field on
`CustomerorderService` (`private final PickingorderUnitloadRepository pickingorderUnitloadRepository;`,
and the rapid-pick sub-branch already calls `pickingorderUnitloadRepository.findById(...)`), so no new
dependency, no constructor change, no §11 impact.

**Required:** either (a) extend Fix 1 with the `pickingorder_unitload` block, carrying the SBDEV-3316
ordering constraint (it must sit below anything that needs the `picktounitload_id → unitload_id →
stockunit` hop — on this branch the `recordCancellation` calls happen inside the
`cancelOrderPosition` loop, which already ran, so placing it with the rest of the teardown is safe,
but say so explicitly rather than leaving it implied), plus an AC and a mutant; or (b) state with
evidence why the success branch does not need it. Silence is the one option that is not available,
because §5.3 currently asserts the opposite.

---

### H-2. §8's central safety claim is false, and the exact mechanism it rules out is the one that fires

§8 states:

> "**No** existing `cancelOrder` success-path test sets a non-null `pickingtoteId`, so the fix breaks
> nothing and a green run afterwards is not evidence."

and

> "The only mechanism that could have broken an existing test is `unitloadRepository.findById(...)`
> returning `Optional.empty()` into `.orElseThrow` — and that set is empty, as above."

That set is not empty. `CustomerorderServiceUnitTest`, nest `CancelOrderRapidPickingScenarios`,
method `shouldSkipRapidPickingCleanupWhenNotStarted`:

```java
testOrder.setState(WmsConstants.State.ASSIGNED);
testOrder.setPickingtoteId(50L);
...
pickingOrder.setState(WmsConstants.State.PROCESSABLE); // Not STARTED
...
customerorderService.cancelOrder(testOrder, false);
assertThat(testOrder.getState()).isEqualTo(WmsConstants.State.CANCELED);
```

The rapid-pick sub-branch is gated on `pickingOrder.getState() == WmsConstants.State.STARTED`, so
with `PROCESSABLE` the branch that would have nulled `pickingtoteId` is skipped, `pickingtoteId`
stays `50L`, and the test falls through to the success branch and asserts `CANCELED`. There is no
`when(unitloadRepository.findById(50L))` in that method, and there is no nest-level fixture that
could supply one — the file has exactly **one** `@BeforeEach` (class level), and every
`when(unitloadRepository.findById(...))` in the file is inside a test method body; the stub sites
jump straight from the preceding nest to a nest 500 lines later. Under Fix 1 that call returns
`Optional.empty()` and `.orElseThrow(() -> new EntityNotFoundException("UnitLoad", …))` fires. The
test goes red.

*Deriving method:* mapped every `setPickingtoteId` site in the file to its enclosing `@Nested` class
and method with awk, then read each site landing in a `cancelOrder` nest to see whether the tote is
nulled before the success branch. *Blind spot:* a fixture that sets `pickingtoteId` reflectively, via
a builder, or through `TestDataFactory` would not appear in a `setPickingtoteId` grep — I did not
audit `TestDataFactory` internals. `createTestCustomerorder` itself is clean (read in full; it sets
no tote), and the plan's "12 `setPickingtoteId(50L)` sites" positive control is exactly right.

This compounds with the next sentence in §8: *"Baseline: 216 tests, 0 failures … Any deviation is a
regression, not noise."* The implementer is being pre-instructed to read a correct fix's only
legitimate red as a regression. (The 216 figure itself checks out: `grep -c "@Test"` gives
122 + 77 + 17 = 216 across the three classes, with zero `@Disabled` and zero `@ParameterizedTest`.)

**Required:** withdraw the "set is empty" claim, name `shouldSkipRapidPickingCleanupWhenNotStarted`
in §8, and say how it is amended — the honest amendment is to stub the tote and assert the teardown,
which turns it into a second real AC-1 witness rather than a fixture patch.

---

### H-3. Fix 3 changes the response for the *pre-existing* rejection path, not just for teardown failures — and breaks an existing test the plan does not list

§5.2 frames Option B as containing "new throw sources into that loop, all from `sendToClearing`". A
`catch` around `customerorderService.cancelOrder(...)` cannot distinguish those from the rejections
that already flow through it. On `origin/develop`, `cancelOrder` throws `BusinessException` for
"order is already shipped or past cancellation boundary", for "order contains position with status
beyond PACKED. can not be cancelled anymore", for "order is beyond status PACKED and not a pre-QA
club order", and for the club-batch block. Today every one of those becomes `HTTP 400 WRONG_STATE`.
Under Option B as specified — log, record, `continue` — every one becomes a 200 carrying an `errors`
entry.

That is a far larger OMS contract change than the plan's ⚠ describes, and it is already pinned:
`OrderRestControllerUnitTest`, `/cancelPositions` nest, `shouldReturnBadRequestWhenOrderInWrongState`:

```java
doThrow(new BusinessException("Wrong state")).when(customerorderService).cancelOrder(existingOrder, false);
ResponseEntity<Object> response = orderRestController.cancelPositions(List.of(batch));
assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
```

Three consequences the plan does not carry:
- §6 lists `OrderRestControllerUnitTest.java` as **"1 new test"**. It also needs an existing test
  amended or deliberately inverted.
- §8's baseline covers `CustomerorderServiceUnitTest` + `CustomerorderPositionServiceUnitTest` +
  `PickingorderBusinessServiceUnitTest`. `OrderRestControllerUnitTest` — the only class whose
  behaviour Fix 3 changes — is not in it. There are 9 existing `cancelPositions` tests.
- §9 Risks has no row for "a cancel OMS was correctly refused now reads as accepted-with-errors".

**Required:** decide explicitly whether containment is scoped to the teardown throws (e.g. catch only
around the new block, or discriminate on the exception key) or is deliberately global; if global, say
so in §5.2, amend the existing test as part of the plan, add `OrderRestControllerUnitTest` to the §8
baseline with its own count, and add the §9 row. This also needs to reach prerequisite 6 — what Nam
confirms with OMS is no longer just "a response shape" but "400 → 200 for orders OMS asked to cancel
that WMS legitimately refuses".

---

## MEDIUM

### M-1. `CancelOrderRollbackIntegrationTest` is cited for a property it does not assert — and the sentence it supports is wrong twice over

§5.2: *"a teardown throw rolls back the `CANCELED` state **and** the outbox row. That is correct and
`CancelOrderRollbackIntegrationTest` already pins it."* §9 row 2 and §8's "Deliberately skipped —
Integration test for Fixes 1–2" both rest on the same citation.

The test does not pin that. It arranges the throw at the *entry guard*:

```java
// Force the post-cancel cleanup to throw by leaving the order in a state
// that cancelOrder cannot accept (e.g., already-FINISHED) ... The exact
// throwing site doesn't matter for this assertion
order.setState(WmsConstants.State.FINISHED);
assertThatThrownBy(() -> customerorderService.cancelOrder(order, true)).isInstanceOf(Exception.class);
verify(httpRestService, never()).post(any(), any());
```

`isShippedOrPastCancellationBoundary` fires before any state mutation and before any
`outboxService.enqueue`. The single assertion is "no HTTP POST" — which would hold with rollback
entirely broken, because nothing was ever enqueued. It is a vacuous foundation for this plan.

And the sentence is independently wrong: Fix 1 is placed *before* `customerOrder.setState(CANCELED)`
and roughly 60 lines before the `outboxService.enqueue(...)`, so a teardown throw short-circuits both
— there is no `CANCELED` state and no outbox row to roll back. This is precision beyond what the
evidence supports (criterion 6). Either delete the claim or replace it with a test that throws
*after* the enqueue.

### M-2. §8's stated check for Fix 3 points at coverage of a dead method

§8 Deliberately skipped: *"confirm against `CancelOrderRollbackIntegrationTest`'s existing **batch**
coverage that a contained failure still leaves the failing order fully rolled back."* The only batch
test in that class is `cancelBatch_shouldNotPostToOms_whenChildSaveThrows`, which calls
`customerorderBatchService.cancelBatch(batch, principal)` — the dead method §5.4 proposes deleting.
It never touches `cancelPositions`. There is no existing batch coverage for the path Fix 3 changes;
say so, or name a real substitute.

### M-3. §5.4's enumeration is wrong across every per-class figure, and the cost estimate that rests on it is understated ~3x

§5.4 is a PROPOSAL, so its numbers are the decision input. Measured on `origin/develop`
(`git grep -o "cancelBatch" origin/develop -- <file> | wc -l`):

| Plan says | Actual |
|---|---|
| "4 `docs/plan/**` files" | **12** files |
| `CustomerorderBatchServiceUnitTest` ×13 | **36** |
| `CustomerorderBatchOutboxIntegrationTest` ×4 | **13** |
| `CancelOrderRollbackIntegrationTest` ×1 | **4** |
| (not listed) | `PickingorderBusinessServiceUnitTest` ×1 — a **fifth** referencing test file |
| "53 references across 4 test classes" | 54 across 4 test files |
| "18 test call sites retired … half a day at most" | 54 references; the estimate does not follow |

The *conclusion* survives and I agree with it: `src/main` contains exactly **1** occurrence of
`cancelBatch`, its own declaration at `CustomerorderBatchService:398`, so the method is dead and
deletion is the right call. Only the arithmetic needs fixing. *Blind spot (mine and the plan's):*
reflective/SpEL invocation, which the plan already names.

### M-4. The `setEntityLock` census is off by 4

§5.5 D-1: *"`git grep -n "setEntityLock(" origin/develop -- 'src/main/**/*.java'` → **90 hits** across
`src/main`, **none** in `CustomerorderBatchService`."* The count is **94** — `git grep -n … | wc -l`
and `git grep -o … | wc -l` both return 94, so there are no multi-match lines to explain the gap.

The half that matters is correct: `git grep -c "setEntityLock(" origin/develop --
'…/CustomerorderBatchService.java'` returns no line at all, i.e. zero. D-1 is genuinely a false claim
in the workflow doc and correcting it in this PR is right.

---

## LOW

- **L-1. AC-2's positive control does not establish the instrument.** §5 point 2 offers
  `pickfromstockunit_id IN (7 ids) → 0` with the control *"exactly **1** row tenant-wide has a
  non-null `pickfromstockunit_id` at all."* A control showing the column is ~universally null cannot
  show the scan would have detected a true positive; the zero is a base-rate artifact. The plan is
  honest about this ("measured-theoretical") — it just should not be labelled a positive control.
  The ordering argument itself is fine and does not need the measurement: I confirmed
  `WmsConstants.CODE_TRANSFER = "TRANSFER"` is a member of
  `PickLineActivityCodeClassifier.BLOCK_REALIGN_CODES`, so `sendToClearing`'s
  `pickLineRealignmentService.lockOwningPickingorders(...)` pre-walk genuinely fires and §10 row 8 is
  correctly reasoned.
- **L-2. AC-6's named mutant does not exist in the code.** *"Mutant = drop the `continue` so the
  throw propagates."* The loop today has no `continue`; it has three `catch` arms that each
  `throw new WebserviceBusinessExceptionClientSide(...)`. The killing mutant is "restore the `throw`
  in the catch". Name the real statement or PIT has nothing to remove.
- **L-3. §1 drops a qualifier its own evidence carries.**
  `ORDER_BATCH_CANCELLED_FROM_PSD` is written on **both** branches of `cancelPositions` —
  `OrderRestController:591` (`MessageStatus.RECEIVED`, 200) and `:608` (`FAILED`, 400) — so a bare
  row count does not prove the cancels landed. `analysis-bundle.md:31` says *"8 rows RECEIVED"*; the
  plan dropped the word. One word restores the argument.
- **L-4. §0 row 2 line drift.** `cancelBatch` nulls `pickingtote_id` at **:506**, not `:513`
  (`customerOrder.setPickingtoteId(null);` inside the `if (customerOrder.getPickingtoteId() != null)`
  block that begins at :498). Cosmetic under the plan's own citation-form rule, but row 2 is the row
  a reader follows to check §5.4.
- **L-5. Fix 3 leaves the service-log row undecided.** `messageService.createMessage(…,
  ORDER_BATCH_CANCELLED_FROM_PSD, "N/A", WmsConstants.MessageStatus.RECEIVED,
  Integer.toString(HttpStatus.OK.value()), null)` runs after the loop. Under containment a batch
  containing a failed order still logs RECEIVED/200. Decide it alongside the response shape in
  prerequisite 6 — the row is a support diagnostic and L-3 shows people already reason from it.

---

## Sections that are fine — one line each

- **§2 Root cause** — exact. The quoted success-branch sequence matches the blob, and the "three
  omissions" table is correct for all four columns on all three rows.
- **§3 Regression chain** — the `canOrderPositionBeCancelled` discriminator and the
  600-`PICKED`-window explanation hold.
- **§4 Architecture** — `UtilRestController` is `@Service` (dead route) and `OrderRestController` is
  `@RestController` + `@RequestMapping("/rest/order")`; the positive control is genuine.
- **Fix 1's copied internals** — verbatim match to the sibling, including `sendToClearing` before
  `saveAll` and the argument transposition: `sendToClearing(ul, activityCode, comment, orderNumber)`
  forwards as `transferUnitLoadToLocation(ul, clearing, true, activityCode, comment, orderNumber)`
  into a signature of `(…, activityCode, orderNumber, comment)` — slots 5 and 6 swapped, exactly as
  §5 point 4 says. "Do not correct it here" is the right call.
- **Fix 2** — real and correctly diagnosed: `Unitload.getEntityLock()` returns `Integer`,
  `GOING_TO_DELETE` is `public static final int` (`WmsConstants:1450`), the column is
  `entity_lock integer` with no NOT NULL and no default in `V2.2.00`, and the rule is already stated
  in `relocateEmptiedContainer` in the exact words the plan quotes.
- **§5 point 2's "no `entity_lock` guard on the path"** — holds: `ignoreLock=true` skips both the
  `locationRepository.findByIdForUpdate` re-fetch and the
  `destinationLocation.getEntityLock() != BusinessObjectLockState.NOT_LOCKED` guard. The stated
  positive control (the sweep surfaced those reads where they exist) is real.
- **§5 point 3** — `Clearing` is seeded in `V2.2.00` with the quoted *"This is a system used entity.
  DO NOT REMOVE OR LOCK IT!"*; `relocateEmptiedContainer` does carry the emptiness guard it is
  contrasted with.
- **§5.2 throw-source list** — accurate in type and key on all five: `EntityNotFoundException`,
  `BusinessException("unitloadTypeNotPermittedOnLocation", …)`,
  `FacadeException("CARRIER_NOT_ON_FIXLOC")` / `("WRONG_ITEMDATA_FIXASSIGNMENT")`,
  `BusinessException(ACTIVE_PICK_MESSAGE)`,
  `FacadeException("CARRIER_IS_ITS_OWN_CARRIER")` / `("CARRIER_HIERARCHY_CYCLE")`.
- **The `errors`-map claim** — exactly 2 occurrences of `errors` in `OrderRestController` (`:124`,
  `:537`), both bare declarations, neither ever read. The positive control is genuine.
- **§5.3** — the `CancellationReversalService` gate is quoted exactly
  (`final boolean clearNeeded = arrivedLocked || stockUnit.getEntityLock() == null;`). Worth adding:
  the unconditional policy is **already pinned** by
  `PickingorderBusinessServiceUnitTest.shouldCleanUpWithStockUnitsAndPositions`, which fixtures
  `stockUnit2.setEntityLock(…ON_HOLD)` and asserts it becomes `NOT_LOCKED` — free evidence for the
  decision, and a warning that narrowing later breaks a real test.
- **§8's "model to copy"** — exists and pins what the plan says it pins (fixture at
  `PICKED_FOR_GOODSOUT`, `verify(unitloadBusinessService).sendToClearing(eq(tote), …)`,
  `assertThat(stockUnit1.getEntityLock()).isEqualTo(…NOT_LOCKED)`). Its "only lock-after-cancel
  assertion in the three classes" claim also holds — `grep -n "getEntityLock()"` over the three test
  files returns exactly those two lines. *My blind spot:* an assertion routed through an
  `ArgumentCaptor` on `saveAll` or through `extracting(...)` would not match that grep.
- **§8 strictness warning** — correct and non-obvious: `CustomerorderServiceUnitTest` is
  `@MockitoSettings(strictness = Strictness.LENIENT)` while `PickingorderBusinessServiceUnitTest` is
  `STRICT_STUBS`. Worth keeping.
- **§12 blind spots** — both the `BillofladingService` bulk-JPQL miss (two such queries, the
  `SHIPPED` one at ~:1601) and the `updateStateByIds` latency are real; sole caller passes
  `WmsConstants.State.PACKED` at `CustomerorderBatchService:975`, as stated. The
  `PICKED_FOR_GOODSOUT` census is exact: 14 hits, 2 assignments
  (`PickingorderBusinessService:876`, `CancellationReversalService:407`).
- **§11** — all three collaborators are already `private final` on `CustomerorderService`; no
  `REQUIRES_NEW`, no new query, no migration. Correct.
- **§7 scope discipline** — clean. §5.4 carries no implementation steps, no step in §7 touches
  `CustomerorderBatchService`, and the non-goals restate it. Nothing leaked. (H-1 will add steps to
  §7, but inside `CustomerorderService`, not into the proposal.)
- **Proportionality** — broadly right. The length is justification rather than specification, which
  is the correct shape for T3. The one place precision exceeds evidence is M-1's rollback sentence;
  L-1's mislabelled control is the other.

---

## Required changes for APPROVE

1. **H-1** — extend Fix 1 with the `pickingorder_unitload` teardown (or justify its absence with
   evidence); add an AC and a mutant; reconcile §5.3's "identical state" sentence with whatever is
   decided.
2. **H-2** — withdraw §8's "that set is empty" claim, name
   `shouldSkipRapidPickingCleanupWhenNotStarted`, and specify its amendment. Re-state the baseline
   as "216 green, of which 1 is expected to go red for a known and named reason".
3. **H-3** — decide and record the true breadth of Option B's containment; amend
   `shouldReturnBadRequestWhenOrderInWrongState`; add `OrderRestControllerUnitTest` to the §8
   baseline; add the §9 risk row; widen prerequisite 6 to cover the 400→200 change on the refusal
   path.
4. **M-1, M-2** — drop or replace the `CancelOrderRollbackIntegrationTest` citations; correct the
   "rolls back the CANCELED state and the outbox row" sentence.
5. **M-3, M-4** — correct §5.4's enumeration and cost estimate, and the 90 → 94 count.
6. **L-1 … L-5** — relabel the AC-2 control, name AC-6's real mutant, restore "RECEIVED" in §1, fix
   the §0 row 2 line number, decide the service-log status.
