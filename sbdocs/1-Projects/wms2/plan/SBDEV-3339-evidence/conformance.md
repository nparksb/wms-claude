---
title: "SBDEV-3339 — conformance verification (independent lane)"
ticket: "SBDEV-3339"
type: verification
lane: conformance
date: "2026-09-14"
verdict: "PASS — conditional on 2 must-fix items before merge"
graded_commit: "c84c799f"
base: "origin/develop @ 221caed1"
---

# SBDEV-3339 — conformance verification

**Question asked:** does the implementation build what the plan specified?

**Verdict: PASS, conditional on two must-fix items before merge.**
Seven of eight acceptance criteria are VERIFIED; **AC-7 is PARTIAL**. No criterion is
behaviourally unmet, and nothing was ungradeable — so this is neither FAIL nor INCOMPLETE.

Everything below was re-derived in this lane. No number from the task brief was accepted as given.

- **Worktree graded:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3339`,
  branch `feature/SBDEV-3339-cancelorder-picking-tote-teardown`, commit `c84c799f`, base
  `origin/develop` @ `221caed1`. The stale `v2/wms2-api` checkout and the `-baseline` worktree
  were never read or built.
- **Working tree was clean at start and is clean at end** (`git status --porcelain` empty).
  Every mutant below was reverted and each revert confirmed byte-exact.

---

## 1. Measured results — claims confirmed

| Lane | Command | Result | Claim | Verdict |
|---|---|---|---|---|
| compile | `mvn -o clean compile` | exit 0 | clean | **confirmed** |
| unit | `mvn -o test -Dtest='CustomerorderServiceUnitTest,OrderRestControllerUnitTest,CustomerorderPositionServiceUnitTest,PickingorderBusinessServiceUnitTest'` | **321 run, 0 failures, 0 errors, 0 skipped** | 321/0 | **confirmed** |
| failsafe | `mvn -o verify -Dit.test='TransferLaneLeakOnCancelIT,CustomerorderOutboxIntegrationTest,CancelOrderRollbackIntegrationTest' -Dtest=ZzzNone` | **9 run, 0 failures**, BUILD SUCCESS | 9/0 | **confirmed** |

**The failsafe selector was not a silent no-match.** All three classes produced their own
`target/failsafe-reports/*.txt`: `CancelOrderRollbackIntegrationTest` 4,
`CustomerorderOutboxIntegrationTest` 3, `TransferLaneLeakOnCancelIT` 2 — and 4+3+2 reconciles
with the lane total of 9. This is the check that catches the `Tests run: 0` / BUILD SUCCESS trap.
The standalone `failsafe:integration-test` goal was never used.

### Test-count delta reconciles exactly

13 tests added; `321 − 13 = 308` = the plan's declared baseline. Composition:

- `Sbdev3339_CancelOrderToteTeardown` — **11** (7 `@Test` + one `@ParameterizedTest` × 4 parameters)
- `Sbdev3339_ToteTeardownExceptionContract` — **1**
- `OrderRestControllerUnitTest$CancelPositionsEndpoint` — **1** (9 → 10; class total 92 → **93**)

*Deriving method:* `git diff origin/develop...HEAD -- src/test | grep -cE '^\+\s*@(Test|ParameterizedTest|RepeatedTest|TestFactory)'` → **9** `@Test`, 0 of the other three
forms; the 4 extra executions come from the `@MethodSource` parameterisation, whose four cases
are named individually in the surefire XML (`...[1]`…`[4]`). **0 deletions in any test file**
(`git diff … -- src/test | grep -c '^-[^-]'` → 0), so nothing was removed to make room.

> ⚠ **One surefire report file lies, and it is not a defect in this change.**
> `...$Sbdev3339_ToteTeardownExceptionContract.txt` reads `Tests run: 3`, but its XML lists
> `emptyAndUnsupportedPriorityRequestsDoNotWriteAnyOrders` and
> `loweringPriorityToZeroUpdatesEveryUnfinishedPickingGroup` — two unrelated pre-existing tests
> surefire assigned to that report file. **Per-nest `.txt` counts are not authoritative here;
> the lane total is.** Reading that file alone would have produced a 2-test phantom discrepancy.

---

## 2. Mutation verification — 9 mutants, 8 killed, **1 survived**

Every mutant was hand-applied to a single site, run, then reverted from a `/tmp` copy taken
beforehand. Revert was confirmed two ways each time: `diff` against the copy, **and**
`git status --porcelain` returning empty (independent of my own backup). No `git checkout --`,
`git restore` or `git stash` was used at any point.

| # | Mutant | Expected | Observed | Verdict |
|---|---|---|---|---|
| 1 | **AC-8** — narrow `catch (Exception e)` → `catch (BusinessException \| FacadeException e)` | both unchecked params red | **2 failures, exactly `[3]` `EntityNotFoundException` and `[4]` `DataAccessException`**; `[1]`/`[2]` checked stayed green | **KILLED** |
| 2 | **AC-2** — move `sendToClearing` below `saveAll` | `InOrder` red | 1 failure: `cancelOrder_shouldSendToClearingBeforeClearingStockLocks…` | **KILLED** |
| 3 | **AC-7 fields** — delete `pickingUnitLoad.setUnitloadId(null)` | red | 1 failure: `cancelOrder_shouldRetirePickingorderUnitload…` | **KILLED** |
| 4 | **AC-1 lock** — delete `toteStock.forEach(su -> su.setEntityLock(NOT_LOCKED))` | red | **2** failures: the AC-1 test *and* the amended `shouldSkipRapidPickingCleanupWhenNotStarted` | **KILLED** |
| 5 | **AC-1 binding** — delete `customerOrder.setPickingtoteId(null)` | red | **2** failures: same pair | **KILLED** |
| 6 | **AC-6** — delete the `catch (ToteTeardownException)` arm | red | 1 failure: `cancelPositions_ToteTeardownFailureOnOneOrder_ContinuesBatch` | **KILLED** |
| 7 | **AC-5** — restore `!= <int constant>` | red | 1 failure: `forceCancelOrder_shouldNotThrow_whenToteEntityLockIsNull` | **KILLED** |
| 8 | **AC-4** — neutralise the null guard (`if (true)`) | red | **19** red (1 failure + 18 errors), including `cancelOrder_shouldSkipTeardown_whenNoPickingTote` | **KILLED** |
| 9 | **AC-7 ordering** — hoist the whole teardown block **above** the `cancelOrderPosition` loop | red (plan §8.1 says so) | **134 run, 0 failures — nothing detected it** | ⚠ **SURVIVED** |

### AC-8 is the criterion this ticket's risk sits on, and it holds

The mutant produced exactly the two specified reds, with the stack confirming the escape route:

```
but was: net.aim_ai.wms.exceptions.EntityNotFoundException: Location not found by name: Clearing
    at net.aim_ai.wms.service.UnitloadBusinessService.sendToClearing(UnitloadBusinessService.java:604)
    at net.aim_ai.wms.service.CustomerorderService.cancelOrder(CustomerorderService.java:856)
```

`CustomerorderService.java` catches `Exception`, not an enumerated list, exactly as §5 Fix 3 and
round 2's H1 finding require:

> `} catch (Exception e) {` … `throw new ToteTeardownException("tote teardown failed for order " + customerOrder.getNumber(), e);`

**Revert confirmed byte-exact** — MD5 `9699c9f454a8ee74191556ad4ade8f79` before and after, `diff`
empty, `git status` empty.

*Blind spot on this whole section:* these are hand-applied single-site mutants. They prove each
named assertion is load-bearing; they do **not** substitute for the PIT run §7 step 5 specifies,
and they cannot reveal *other* surviving mutants elsewhere in `CustomerorderService`. **PIT was
not run in this lane.**

---

## 3. Acceptance criteria

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| **AC-1** | tote stock `NOT_LOCKED`, `pickingtote_id` null, `historytote` set, tote sent to Clearing | **VERIFIED** | 3 dedicated tests; mutants 4 & 5 each kill two tests. `sendToClearing` is asserted by a direct `verify(unitloadBusinessService).sendToClearing(eq(tote), eq(CODE_TRANSFER), isNull(), eq(testOrder.getNumber()))` and is additionally observed by mutant 2. *Not separately mutated* (a bare `verify` is trivially broken by removal). |
| **AC-2** | `sendToClearing` **before** the stock-lock clear | **VERIFIED** | Source order: `sendToClearing(...)` then `findByUnitloadId` / `forEach` / `saveAll`. `InOrder` assertion present; mutant 2 kills it. Teardown also sits after the `cancelOrderPosition` loop — see AC-7. |
| **AC-3** | `CustomerorderPositionService` **absent** from the diff | **VERIFIED** | `git diff --name-only origin/develop...HEAD` → exactly 5 files: `CustomerorderService.java`, `OrderRestController.java`, `ToteTeardownException.java`, and the two test classes. *Deriving method:* name-only diff over the commit range — complete for committed changes; *blind spot:* uncommitted work (tree is clean) and a change made then reverted inside the range. |
| **AC-4** | no-tote order still cancels, no `findById(null)` | **VERIFIED — and no longer vacuous** | §15.1 correctly flagged this as passing pre-fix. Mutant 8 now kills it (19 red), so the null guard is genuinely graded post-fix. |
| **AC-5** | `forceCancelOrder` no longer NPEs on null `entity_lock` | **VERIFIED** | `!Integer.valueOf(GOING_TO_DELETE).equals(pickingTote.getEntityLock())`; reflection test; mutant 7 kills it. The source comment correctly carries §15.2's correction that the branch is unreachable in production. |
| **AC-6** | teardown failure contained; batch continues; order named in body; not a bare 200; rejection contract unchanged | **VERIFIED** (one sub-clause ungraded) | Test asserts siblings still cancelled, `status == "partial"`, `errors` contains `ORD002`. Mutant 6 kills it. Rail `shouldReturnBadRequestWhenOrderInWrongState` present and green (XML has no `<failure>`/`<error>` child). **Ungraded:** the "ERROR log carries its `unique_id`" clause — the `LOG.error(… order={} …, order.getUniqueId(), e)` statement exists but no test asserts it. |
| **AC-7** | `pickingorder_unitload` retired (`unitload_id` null, `state` CANCELED, `historytote` set) **and retired after the `cancelOrderPosition` loop** | ⚠ **PARTIAL** | **Field retirement VERIFIED** — all three asserted, mutant 3 kills it, and it correctly uses `findLatestByUnitloadLabelid`, **not** `PickingorderUnitloadService.getByLabel`. **Ordering clause UNGRADED** — see §4.1. |
| **AC-8** | every teardown throw, checked *and* unchecked, becomes `ToteTeardownException` | **VERIFIED** | Mutant 1, above. The single strongest result in this lane. |

---

## 4. Must-fix before merge

### 4.1 AC-7's ordering clause is not graded, and the plan's own mutant survives

AC-7 has two clauses. The second — *"the retirement happens **after** the `cancelOrderPosition`
loop, preserving the SBDEV-3316 constraint"* — is **correct in the code but pinned by nothing.**

The plan is explicit that it should be pinned. §8's test table specifies for this test:

> *"`InOrder` — the block-2 `save` **after** the `cancelOrderPosition` loop (AC-7)"*

and §8.1's AC-7 row lists the mutant:

> *"hoist block 2 above the loop (confirm the `InOrder` assertion goes red)"*

Neither exists. *Deriving method:* the only `inOrder(...)` in `Sbdev3339_CancelOrderToteTeardown`
is in the AC-2 test; `cancelOrder_shouldRetirePickingorderUnitload_whenSuccessBranchHasTote`
asserts only field values plus `verify(pickingorderUnitloadRepository).save(pul)`.

**I ran the specified mutant.** Hoisting the entire teardown block above the loop —

```
LOG.debug("cancelOrder: cancelling order positions");
if (customerOrder.getPickingtoteId() != null) { … }      // hoisted
for (CustomerorderPosition customerOrderPosition : coPositions) { … }
```

— produced **134 tests run, 0 failures.** The placement the source comment calls *"load-bearing"*
(*"Placement after the loop is load-bearing"*) can be inverted with no test noticing.

**Impact:** no behavioural defect today — the shipped order is correct. The risk is regression:
a future refactor can move this block and the suite stays green. Given SBDEV-3316's pin is the
stated reason for the placement, this is worth the three lines.

**Fix:** add to the AC-7 test —
`InOrder o = inOrder(customerorderPositionService, pickingorderUnitloadRepository);`
`o.verify(customerorderPositionService).cancelOrderPosition(position);`
`o.verify(pickingorderUnitloadRepository).save(pul);`
then re-run the hoist mutant and confirm red.

### 4.2 A source comment states something the code does not do

`OrderRestController.cancelPositions` carries this claim:

> *"what IS settled is that a partial batch does not report "success" **and does not write a clean
> RECEIVED/200 service-log row**, because that row is the forensic trail this defect was originally
> diagnosed from."*

**The second half is false.** The service-log write is unconditional and sits **above** the
partial-batch check:

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

A partially-failed batch **does** write `ORDER_BATCH_CANCELLED_FROM_PSD` / `RECEIVED` / `200`.

This is precisely the §9 risk row *"The `ORDER_BATCH_CANCELLED_FROM_PSD` service-log row keeps
saying `RECEIVED`/200 for a partially-failed batch, destroying the forensic trail §1 relied on —
likelihood **certain unless decided**"*, and it is prerequisite 6's third item, which §5.1 says
**"Do not guess any of the three"** and §7 step 7 says must be answered **before merging**.

The response-shape half of prereq 6 was handled honestly: the body is `{"status":"partial","errors":…}`
at HTTP 200, and the comment openly flags 207-vs-200 as unsettled. Only the service-log half is
both unresolved **and** described as resolved.

**Fix (either):** correct the comment to say the service-log row is a known-open prereq-6 item; or
move/condition the `createMessage` call so a partial batch records `FAILED` — but that is an
OMS-facing contract change and needs Nam's prereq-6 answer, not an implementer's judgement.

---

## 5. §0 in-scope rows

| §0 row | Scope | Covered? |
|---|---|---|
| 1 — `cancelOrder` success branch | **In** | **Yes** — Fix 1, both blocks, graded by AC-1/2/4/7/8 |
| 10 — `wms2-cancel-cascade-workflow.md` D-1, D-2 | **In** | **Yes** — §6 below |
| 2 `cancelBatch` · 4 `cleanUpCancelledOrder` · 5 `PickingorderUnitloadRepository` · 7 `cancelOrderPosition` · 8 `CustomerorderRepository`/`BillofladingService` · 9 `StockunitService` · 11 state-machine catalog | Out | **Correctly untouched** — none appears in the 5-file diff |
| 3 — `forceCancelOrder` | see note | **One line changed**, as §5 Fix 2 and §7 require |

⚠ **Plan-internal inconsistency, not an implementation fault.** §0 row 3 marks `forceCancelOrder`
*"No (read-only)"*, while §5 Fix 2, §6 and §7 step 3 all direct a one-line change there. The
implementation follows §5/§7 and changes exactly that one line (the diff's **only** deletion —
`532 insertions(+), 1 deletion(-)` across the whole change). §0's row should be reconciled.

### Non-goals — all honoured

`cancelOrderPosition` untouched · `cancelBatch` untouched · `forceCancelOrder` touched only by
Fix 2's one line · `cleanUpCancelledOrder`'s SBDEV-3316 pin not moved (`PickingorderBusinessService`
absent from the diff) · `markedforcancellation` not reopened · the `sendToClearing` argument
transposition **not** "corrected" (called as `(tote, CODE_TRANSFER, null, getNumber())`, matching
the sibling) · `OPERATOR_REMOVABLE` not widened · `cleanUpCancelledOrder`'s finder unchanged.

### §5.3 decision honoured — the lock clear is unconditional

`toteStock.forEach(su -> su.setEntityLock(WmsConstants.BusinessObjectLockState.NOT_LOCKED));`

No predicate, no `QUALITY_FAULT`/`ON_HOLD` exclusion. This **matches** the §5.3 decision
(copy `cleanUpCancelledOrder`) and was **not** quietly narrowed. The deliberate exposure §5.3
names — operator holds on tote stock now cleared on this branch too — is what ships.

### Benign deviation from the §5 snippet

The plan's snippet places `setHistorytote` / `setPickingtoteId(null)` **before** block 2; the
implementation places them **after**. No functional difference: block 2 reads `tote.getLabelid()`,
never the order's fields. Worth a line in the PR body, nothing more.

---

## 6. Doc corrections — both landed, and I agree with holding `last_verified`

`sbdocs/3-Resources/workflows/wms2-cancel-cascade-workflow.md`:

- **D-1 (§5 diagram)** — corrected. The diagram now reads *"⚠ it does NOT release entity locks —
  see the correction below"*, followed by a block quoting the withdrawn claim and its deriving
  method.
- **D-2 (§2 entry-point row)** — corrected. Trigger is now *"⚠ **NONE — unreachable**"*, and it
  records that the previous *"REST `/clubLine/...` + admin"* named a route that does not exist.
  `git grep -n 'clubLine'` over the doc returns only the correction text and the log row.

**I re-derived every factual claim these corrections make**, against `origin/develop`:

| Claim | Check | Result |
|---|---|---|
| 0 `setEntityLock` in `CustomerorderBatchService` | `git grep -c setEntityLock origin/develop -- …/CustomerorderBatchService.java` | no match ✓ |
| *positive control:* 4 in `CustomerorderService` | same grep, other file | **4** ✓ |
| `cancelBatch` is declaration-only in `src/main` | `git grep -n cancelBatch origin/develop -- 'src/main/**/*.java'` | exactly 1 hit, the declaration at `:398` ✓ |
| *(new claim)* it nulls `pickingtote_id` and sets the `pickingorder_unitload` row CANCELED | grep of the same file | `poul.setState(…CANCELED)` at `:502`, `customerOrder.setPickingtoteId(null)` at `:506` ✓ |

**On holding `last_verified` at 2026-05-08 and adding a verification-log row instead — I agree,
and I think it is the right call rather than merely an acceptable one.** Bumping it would assert
a full re-sweep of a doc that still carries six known-uncorrected inaccuracies (D-3…D-8) plus the
unaudited line-number drift flagged in the 2026-06-29 row. A bumped date would make the next
reader trust D-3…D-8. The log row states its own scope explicitly — *"Scope: these two claims
only"* — which is exactly the distinction `last_verified` cannot express.

---

## 7. Blind spots in this lane

Named so they are not mistaken for coverage:

1. **PIT was not run.** §7 step 5 specifies PIT scoped to `CustomerorderService`. My nine mutants
   are hand-applied and single-site: they prove the named assertions bite, not that no other
   mutant survives. Mutant 9 is direct evidence that surviving mutants exist in this change.
2. **Only the 7 classes the plan names were run** (4 unit + 3 IT). A regression in an unrelated
   class is invisible to me. The full suite was **not** run and has a known-red baseline
   (~26 red / 132 skipped), so "full suite vs baseline" is not discharged by this lane.
3. **No DB verification.** Prereqs 1–5 and 7 (Clearing row, location constraint, fix assignment,
   duplicate-label pre-check, data migration, ops notification) are environment work and were not
   checked here; §8's note that ports 25060/25062 reject all configured users still stands.
4. **Doc claims graded against `origin/develop` @ `221caed1` only.** A later branch could differ.
5. **AC-6's ERROR-log clause and AC-1's `sendToClearing` call were not separately mutated** —
   both are asserted, but by a bare `verify` / not at all respectively.
6. **The manual test plan (§8) was not executed** — in particular the tote-reuse scenario, which
   is the one Fix 1 block 2 exists for and which no unit test can reach.

---

## 8. Bottom line

The fix does what the plan specified. The teardown is complete on all five axes the §2 table
demands, both blocks are present, `sendToClearing` precedes the stock clear, the correct finder is
used, the wrap is fail-closed on `Exception`, containment is scoped to `ToteTeardownException`, and
the pre-existing 400 `WRONG_STATE` rejection contract is intact and still railed. Measured counts
match the claims exactly and reconcile three independent ways.

Two items should be closed before merge — one three-line test addition (§4.1) and one false source
comment plus its open prerequisite (§4.2). Neither is a behavioural defect in shipped logic.
