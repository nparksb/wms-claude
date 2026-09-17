---
ticket: SBDEV-3339
lane: code-review
reviewer: review-3339 (independent lane)
date: 2026-09-14
subject_commit: c84c799f0194c762ab9fbdfa35f9cf5074ccfd83
base: origin/develop @ 221caed1
worktree: .claude/worktrees/wms2-api/SBDEV-3339
verdict: ITERATE (1 High, 2 Medium, 3 Low)
---

# SBDEV-3339 — code review of `feature/SBDEV-3339-cancelorder-picking-tote-teardown`

## Verdict

**ITERATE** — 1 High, 2 Medium, 3 Low. The three fixes are **correct as mechanisms**: the teardown is
placed correctly, the exception type and its `catch`-arm ordering are right, the transaction semantics
hold, and the SBDEV-3316 ordering constraint is *satisfied* (it is just unpinned). Nothing in the diff
is wrong in a way that would strand stock or break the existing rejection contract.

The High is at the controller's exit, not in the teardown: a partially-failed batch still writes the
**clean-success service-log row**, and the comment sitting three lines above it asserts the opposite.
That row is the exact forensic instrument plan §1 used to diagnose this defect.

## What was run

| Check | Result |
|---|---|
| `mvn -o test-compile` (isolated copy of `c84c799f`) | **clean**, exit 0 |
| `mvn -o test -Dtest=CustomerorderServiceUnitTest,OrderRestControllerUnitTest,CustomerorderPositionServiceUnitTest,PickingorderBusinessServiceUnitTest` | **321 tests, 0 failures, 0 errors, 0 skipped — BUILD SUCCESS** |

Reconciles against plan §8's measured baseline of **308** declared across the same four classes:
321 − 308 = **13 new** = 11 in `Sbdev3339_CancelOrderToteTeardown` + 1 `Sbdev3339_ToteTeardownExceptionContract`
+ 1 `CancelPositionsEndpoint` (nested report shows `CancelPositionsEndpoint` at **10**, was 9). ⚠ The
outer-class `.txt` reads `Tests run: 0` — the `@Nested` trap; the lane total is the figure above.

⚠ **A first run of this suite reported 2 failures. Those were my artifact, not the branch's.** I copied
the worktree while a sibling lane had `CustomerorderService.java` transiently modified — the copy was
missing `customerOrder.setPickingtoteId(null)` at the teardown site (`md5` differed from the worktree
file). The re-run was taken from a copy verified byte-identical with `diff -r`, against a clean
`git status` at `c84c799f`. **This is the "review lanes must not share a worktree" hazard, and it
produces a plausible, on-theme red.** Any other lane building in this worktree should assume the same.

Builds and test runs were done in `/tmp/.../scratchpad/build2`, never in the worktree, never in
`v2/wms2-api`, never in `SBDEV-3339-baseline`. No `git checkout --`, `git restore`, or `git stash` was run.

---

## HIGH

### H1 — a partial batch still writes the clean `RECEIVED`/`200` service-log row, and the comment says it does not

**`src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java`**, `cancelPositions`. The
service-log write is **unconditional and sits above** the new partial check:

```java
// save service log
…  WmsConstants.MessageProcessType.ORDER_BATCH_CANCELLED_FROM_PSD,
    "N/A",
    WmsConstants.MessageStatus.RECEIVED,
    Integer.toString(HttpStatus.OK.value()), null);
…
LOG.info("cancelPositions finished with {}", orderBatchList.size());
…
if (!errors.isEmpty()) { … return ResponseEntity.ok(partial); }
```

The comment immediately above that `if` claims the opposite:

> `// … what IS settled is that a partial batch does not report "success" and does not write a clean`
> `// RECEIVED/200 service-log row, because that row is the forensic trail this defect was originally`
> `// diagnosed from.`

**Measured, not inferred.** I added an `ArgumentCaptor` on `messageService.createMessage(...)` to the
AC-6 test in a scratch copy and ran it:

```
PROBE service-log status=RECEIVED code=200
Tests run: 1, Failures: 0 — cancelPositions_ToteTeardownFailureOnOneOrder_ContinuesBatch
```

i.e. in the very scenario AC-6 grades, the row written is `ORDER_BATCH_CANCELLED_FROM_PSD` / `RECEIVED`
/ `200` — indistinguishable from a fully successful batch.

**Why this is High and not cosmetic.** Plan §1 derives the whole diagnosis from this row: *"8 `message`
rows with `process = 'ORDER_BATCH_CANCELLED_FROM_PSD'` **at status `RECEIVED`** … ⚠ The status qualifier
is load-bearing"*. Plan §5.2 names it as the third of prereq 6's answers and says so in the same words:
*"under containment a batch with a failed order still takes that exit — destroying the exact forensic
trail §1 used as primary evidence."* So the diff ships the failure mode the plan predicted, while
carrying a comment asserting it was avoided. A future reader — or a future incident — will trust the
comment.

**Fix.** Two parts, and the first is not blocked on prereq 6:

1. **Correct the comment** so it describes what the code does. A wrong comment frozen next to a
   mutation-checked test is durable misinformation (the plan's own §14 phrasing).
2. **Move the `createMessage` call below the `errors.isEmpty()` check** and write a distinguishable
   status/code on the partial exit. The *value* is prereq 6's (Nam / OMS side) — but "not `RECEIVED`/200"
   needs no decision, because `RECEIVED`/200 is the one value that is provably wrong: it is the success
   signature. If the owner wants the value deferred, the minimum is part 1 alone, plus a line on the
   ticket naming the open item.
3. Add the captor assertion above to `cancelPositions_ToteTeardownFailureOnOneOrder_ContinuesBatch`, so
   the guarantee the comment claims is actually graded.

---

## MEDIUM

### M1 — AC-7's `InOrder` assertion is missing: the SBDEV-3316 ordering constraint is satisfied but unpinned

Plan §8.1 AC-7 specifies: *"the retirement happens **after** the `cancelOrderPosition` loop, preserving
the SBDEV-3316 constraint … mutants = remove `setUnitloadId(null)` (confirm red), **and hoist block 2
above the loop (confirm the `InOrder` assertion goes red)**"*. Plan §5 Fix 1 repeats it: *"Pinned by the
`InOrder` assertion in AC-7."*

The implemented test —
`CustomerorderServiceUnitTest$Sbdev3339_CancelOrderToteTeardown.cancelOrder_shouldRetirePickingorderUnitload_whenSuccessBranchHasTote`
— asserts final state (`pul.getUnitloadId()` null, `state == CANCELED`, `historytote` set) and
`verify(pickingorderUnitloadRepository).save(pul)`. **There is no `InOrder` anywhere in it.**
*Deriving method:* read the full method body in the diff, plus `grep -n "InOrder" ` over the new nested
class — the only `InOrder` in the new code is AC-2's `sendToClearing` → `saveAll` pair. *Blind spot:* an
ordering assertion expressed some other way (a captor on a shared collaborator, a `doAnswer` sequence
recorder) would not match "InOrder"; none appears in the block by reading.

**The ordering itself is correct today.** `CustomerorderPositionService.cancelOrderPosition` writes the
cancellation log inside the loop —
`cancellationLogService.recordCancellation(customerOrderPosition, pickingPosition, pickingOrder, customerOrder, tenantName, facilityCode);`
— and the teardown runs after the loop, so
`CancellationLogService.resolvePicktoStockunitId`'s hop
`picktounitload_id → pickingorder_unitload.unitload_id → stockunit` is still live when it is made.

**What is missing is the guard.** The sibling this block was copied from carries a loud, explicit
warning that this diff does not reproduce — `PickingorderBusinessService.cleanUpCancelledOrder`:

> `// ⚠ SBDEV-3316 — THIS BLOCK MUST STAY BELOW THE recordCancellation LOOP ABOVE.`
> `// … PickingorderBusinessServiceUnitTest$Sbdev3316_CancellationLogOrdering pins the order with`
> `// InOrder — hoisting this block makes it fail … Do not reorder without making it fail first.`

The new block's comment explains placement in terms of lock ordering and "runs once per position", and
never mentions SBDEV-3316 at all. So a later refactor that hoists the teardown above the loop — which is
a natural-looking tidy-up, since the teardown reads as order-scoped and the loop as position-scoped —
re-lands SBDEV-3316 silently, on a second site, with a green suite.

**Fix.** Add the `InOrder` assertion the plan specifies
(`inOrder(customerorderPositionService, pickingorderUnitloadRepository)`: `cancelOrderPosition` then
`save(pul)`), hand-apply the hoist mutant and confirm red, and add the SBDEV-3316 sentence to the
production comment.

### M2 — accumulated teardown errors are silently discarded if a later order in the same batch is rejected

In `cancelPositions`, `errors` is only read at the success exit. Any later order that throws
`BusinessException` / `FacadeException` leaves via
`throw new WebserviceBusinessExceptionClientSide(WmsConstants.WRONG_STATE, e, …)`, which the method's own
`catch (WebserviceBusinessExceptionClientSide e)` turns into
`return ResponseEntity.badRequest().body(e.getErrorMap());` — so a mixed batch (order 1 teardown-failed,
order 3 already shipped) returns a plain 400 whose body names **only** order 3. Order 1 was left
uncancelled and OMS is never told, in the response or in the service-log row (which on that path is
`FAILED`/400 for the whole batch).

The ERROR log still names order 1, but plan prereq 8 is explicit that the log is the *operative* control
precisely because *"nothing scrapes Prometheus yet"* — and plan §5.2 adds that *"logs are not queryable
at the five-week horizon at which this ticket was diagnosed."* So on this path the containment reports
nothing durable at all.

This is a smaller sibling of H1 and is not covered by any test: `cancelPositions_ToteTeardownFailureOnOneOrder_ContinuesBatch`
uses a 3-order batch where only the middle order fails, and `shouldReturnBadRequestWhenOrderInWrongState`
uses a batch with no teardown failure. *Deriving method:* read all 10 tests in `CancelPositionsEndpoint`
in the post-fix file; *blind spot:* a mixed-scenario test living outside that nested class would not have
been seen — `git grep -l cancelPositions -- src/test` was not run.

**Fix.** Fold `errors` into the `WebserviceBusinessExceptionClientSide` exit too (merge it into the
returned error map, or at minimum into the FAILED service-log payload), and add a two-order test: one
teardown failure followed by one wrong-state rejection.

---

## LOW

### L1 — AC-4 is missing its third specified negative assertion

Plan §8.1 AC-4 and §8's test table specify three `never()` checks:
`unitloadRepository.findById`, `unitloadBusinessService.sendToClearing`, **and**
`pickingorderUnitloadRepository.findLatestByUnitloadLabelid`.
`cancelOrder_shouldSkipTeardown_whenNoPickingTote` has the first two only. Cheap to add; it is the one
assertion that would catch a future block-2 lookup being hoisted out of the null guard.

(The test being green pre-fix is expected and correctly declared in plan §15.1 — not a finding. Worth
adding that one-line note to the test's own javadoc so a reader does not mistake it for a gate.)

### L2 — the lock clear is not tree-recursive, while the move it accompanies is

`stockunitRepository.findByUnitloadId(tote.getId())` returns only stock sitting **directly** on the tote.
`sendToClearing` → `transferUnitLoadToLocation` → `processTransfer` **does** recurse:
`List<Unitload> childUnitloadList = unitloadRepository.findByCarrierunitloadId(unitload.getId());` followed
by a per-child recursive call. So a tote carrying a child unit-load has that child moved to Clearing with
its stock still at `entity_lock = 100` — a smaller instance of the defect this ticket closes.

This is the **sibling's shape**, copied deliberately per plan §5 point 5, and `cleanUpCancelledOrder` has
the identical gap — so it is pre-existing, not introduced here. But AC-1's wording is *"every stock unit
on that tote"*, and that is true only for direct children. Two things are worth doing: narrow the AC-1
assertion message to say "directly on", and **dispatch** the recursion gap — it belongs on §5.6 item 1's
extraction ticket (the six-axis table), not in this PR. Blast radius unmeasured: whether a picking tote is
ever a carrier on live tenants was not queried (the DB MCP servers for this tenant are timing out this
session).

### L3 — the counter named in §5.2 and §6 was not implemented and was not dispatched

Plan §5.2 Option B: *"`LOG.error` with the `unique_id`, **increment a counter**, record the order into the
`errors` map, continue"*, and §6's file-change row for `OrderRestController` says *"ERROR log + counter +
populate the existing `errors` map + `continue`"*. The implemented arm has the log, the map and the
`continue`, and no counter. *Deriving method:* `grep -n "MeterRegistry\|meterRegistry\|Counter"` over
`OrderRestController.java` → no match (positive control: the same pattern over `CustomerorderService.java`
returns `meterRegistry.counter("wms2.outbox.serialize_failed", …)`, so the grep finds counters where they
exist). *Blind spot:* a counter incremented inside `messageService` or an AOP advice would not match.

Given prereq 8 (*"a Micrometer counter is published but nothing scrapes Prometheus yet, so the log is the
operative control"*), the omission is defensible — but it is a named deliverable, so it must be
*dispatched*, not dropped: either add the two-line counter, or put a line on the ticket saying the counter
was deliberately skipped because nothing scrapes it, so the next reader does not treat §6 as shipped.

---

## Verified correct — the specific risks the brief asked me to probe

| Probe | Finding |
|---|---|
| **`catch (Exception)` scope** | Tight to the teardown block only — it opens after `if (customerOrder.getPickingtoteId() != null) {` and closes before `customerOrder.setState(WmsConstants.State.CANCELED);`. It cannot swallow the position loop, the state write, the transfer-lane clear, the save, `finalizeBatchIfComplete` or the outbox enqueue. **Not reported as a smell** — as the brief states, `EntityNotFoundException extends RuntimeException` (confirmed in `exceptions/EntityNotFoundException.java`) and is not a `DataAccessException`, and it is what `UnitloadBusinessService.sendToClearing` raises: `locationRepository.findByName(WmsConstants.STORAGE_LOCATION_CLEARING).orElseThrow(() -> new EntityNotFoundException("Location not found by name: " + …))`. Narrowing it would break containment. |
| **Can anything catch `ToteTeardownException` before the controller?** | Two call sites of `cancelOrder` exist in `src/main`. *Deriving method:* `grep -rn "\.cancelOrder(" src/main/java --include=*.java` → `OrderRestController` and `UtilRestController` only. `UtilRestController.resetOrdersInReleasedStatus` does `catch (BusinessException \| FacadeException e) { LOG.error(…); continue; }`, which **does** absorb it — but that class is annotated `@Service`, not `@RestController`, so its `@RequestMapping` methods do not route; it is not a live path. Nothing inside `cancelOrder` re-catches it. *Blind spot:* a Spring `@ControllerAdvice` or an AOP around-advice would not appear in that grep; neither was searched. |
| **Transaction semantics** | The controller is **not** transactional — `grep -n "Transactional"` over `OrderRestController.java` and `AbstractRestController.java` returns only the new comment line, no annotation. So each `cancelOrder` runs in its own tx via the proxy, `ToteTeardownException extends FacadeException` is covered by `rollbackFor = {BusinessException.class, FacadeException.class}`, and the failing order rolls back whole rather than half-cancelled. `spring.jpa.open-in-view=false` is present in `src/main/resources/application.properties`, so a rolled-back order cannot poison the next one's persistence context. **Containment does not risk committing a half-cancelled order.** |
| **Lock ordering** | The comment's premise checks out: `PickLineActivityCodeClassifier.BLOCK_REALIGN_CODES` is `Set.of(CODE_MOVE_FIX_ASSIGNMENT, CODE_MANUAL_TRANSFER, WmsConstants.CODE_TRANSFER, CODE_ON_HOLD)` — `CODE_TRANSFER` **is** a member, so `transferUnitLoadToLocation` does run its pre-walk `pickLineRealignmentService.lockOwningPickingorders(treeStockUnitIds)`. That resolves owners via `pickingorderPositionRepository.findByPickfromstockunitId(stockUnitId)`, and `cancelOrderPosition` has already run `pickingPosition.setPickfromstockunitId(null);` on every line of this order — so on this path it locks nothing. The residual inversion (Stockunit-then-Pickingorder) is real in the general case and the diff's comment already labels it "measured-theoretical" rather than claiming preservation, which is the honest framing. No new lock type, no `Location` lock (`ignoreLock=true`). |
| **`pickingorder_unitload` retirement** | Uses `findLatestByUnitloadLabelid`, not `PickingorderUnitloadService.getByLabel` — correct. The repository method is `order by pu.id desc limit 1` and is `exported = false` at method level, so it adds no SDR surface. `ifPresent` is the right shape: the finder returns `Optional`, and on a tote with no assignment row skipping is the intended no-op. |
| **Null-safety / SBDEV-2102** | The explicit `if (customerOrder.getPickingtoteId() != null)` guard is present and correct — `findById(null)` would raise `IllegalArgumentException`, not return empty. Graded (vacuously today) by AC-4. |
| **Fix 2 reachability** | `forceCancelOrder`'s changed line is inside `if (customerOrder.getState() < WmsConstants.State.PACKED) {`, and its only caller reaches it under `isPackedOrPalletized(...)` — so the branch is dead in production, exactly as plan §15.2 corrects. The AC-5 reflection test does enter it (state `PROCESSABLE`), so the test is **not** vacuous. `!Integer.valueOf(GOING_TO_DELETE).equals(pickingTote.getEntityLock())` is the correct null-safe form and preserves the original truth table for non-null values. |
| **The `sendToClearing` argument transposition** | `sendToClearing(Unitload, activityCode, comment, orderNumber)` forwards as `transferUnitLoadToLocation(…, activityCode, comment, orderNumber)` against a declaration of `(…, activityCode, orderNumber, comment)` — the last two are swapped, so these teardown transfers record a null `orderNumber`. **Pre-existing on every caller, and an explicit non-goal** (plan §7: *"do not 'fix' the `sendToClearing` argument transposition"*). Noted, not reported as a defect. |
| **Stale `tote` reference after the move** | `customerOrder.setHistorytote(tote.getLabelid())` reads the pre-move snapshot. Safe here: only `sendToNirvana` mangles `labelid` (hence its own *"unitload maybe updated … get the updated one"* comment); a location transfer does not. |
| **Test quality** | The new tests assert **behaviour** (entity lock values, `pickingtoteId`, `historytote`, `pul` field state, the thrown type and its cause), not call shapes — except where a call *is* the behaviour (`sendToClearing` invoked; AC-2's ordering). AC-2's `InOrder` is a genuine ordering assertion that would go red on a swap. AC-8 is correctly sited on `CustomerorderServiceUnitTest`, where the collaborators are real mocks, and its four parameters do distinguish checked from unchecked — this is the test round 2 returned ITERATE for, and it landed. The one vacuous-today test (AC-4) is declared as such in plan §15.1. ⚠ `CustomerorderServiceUnitTest` is `@MockitoSettings(strictness = Strictness.LENIENT)`, so no "STRICT_STUBS would have caught it" reasoning applies to any of these; the AC-6 test in the controller class correctly uses `lenient()` with a comment explaining why. |
| **Existing rejection contract** | `catch (ToteTeardownException)` sits above `catch (BusinessException)` (required, since it is a `FacadeException` subtype — the compile is clean, so the arm order is legal) and is scoped to that one type. `shouldReturnBadRequestWhenOrderInWrongState` is untouched and green in the 321-test run. |
| **Doc deliverable (plan §6)** | `sbdocs/3-Resources/workflows/wms2-cancel-cascade-workflow.md` **has** been corrected: D-1 (§5's *"release entity locks"*) and D-2 (§2's *"REST `/clubLine/...` + admin"* trigger) are both rewritten with deriving methods and positive controls, and a 2026-09-14 changelog row records the scope and why `last_verified` deliberately stays at 2026-05-08. Not in this repo's diff because `sbdocs/` is not in this git repository — expected, not a gap. |

---

## Design dispute for the owner — not a defect, do not fix here

**A partial batch returns HTTP `200` with `{status: "partial", errors: {...}}`.** Plan §5.2 decided
*"Never a bare 200 when an order failed"*, and plan prereq 6 leaves the body shape, the HTTP status and
the service-log status to Nam / the OMS side.

**My view, for what it is worth:** the `200` is defensible and `207 Multi-Status` is not. 207 is a WebDAV
status whose body shape is specified; an OMS HTTP client that branches on `status < 300` before parsing
will treat 207 as success anyway, so it buys nothing but a new parsing rule. A 200 carrying an explicit
`status: "partial"` discriminator is the smaller change and reads correctly to a client that parses the
body — which this client must do regardless, because the `errors` map is the only place the failed
`unique_id` appears.

**But the 200 only works if the other two answers are consistent with it**, and today they are not: H1
shows the service-log row still says `RECEIVED`/200. Whatever status is chosen, the durable row and the
response must not disagree — right now a partial batch looks like a clean success to every instrument
except the application log.

---

## Fix list, in the order I would do it

1. **H1** — correct the comment (unconditional), move `createMessage` below the `errors` check, add the
   captor assertion to the AC-6 test. If the status *value* is held for prereq 6, ship the comment fix and
   put the open item on the ticket.
2. **M1** — add AC-7's `InOrder` assertion, confirm the hoist mutant goes red by hand, add the SBDEV-3316
   sentence to the production comment.
3. **M2** — carry `errors` into the `WebserviceBusinessExceptionClientSide` exit; add the mixed-batch test.
4. **L1** — add the third `never()` to AC-4, plus a one-line "green pre-fix, kept as a regression guard"
   note on the test.
5. **L3** — add the counter, or dispatch it onto the ticket with the reason.
6. **L2** — dispatch onto §5.6 item 1's extraction ticket; narrow AC-1's assertion message to
   "directly on the tote".

Re-run the four-class lane after each; the figure to beat is **321 / 0 / 0 / 0**.
