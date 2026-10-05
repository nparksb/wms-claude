head: 723e1ba0267ff93d689a0a1d3a154f692ab40419

## SBDEV-3381 Phase 1 code review (lane 3b)

**Verdict: APPROVE.** I found no High issues. There are two Medium test gaps and seven Low issues. The two Mediums should be fixed in this pass, since the repo fixes every finding including Lows.

**What I checked:** 23 files (10 production, 13 test), `git diff 91789cc7...HEAD` in the worktree only. Plan §3.2–§3.4 and the settled decisions (D-a, Q1, Q2, Q3, Q5, F3, F4) were treated as fixed and not re-argued.

**What I did not run:** mvn (as instructed), PIT and LSP. So the two "mutant survives" claims below come from reading every fixture, not from running the mutants. Mark them **UNVERIFIED by PIT**.

### By severity
- High: 0
- Medium: 2 (both test gaps; the production code there is correct)
- Low: 7

---

### Medium

**M1 — No test tells a *completed* row apart from a *waived* row, in either the ownership sum or the waived-share sum.**
- **Files:**
  - `src/main/java/net/aim_ai/wms/service/CancellationReversalService.java`, `ownsAllStock`: `all.stream().filter(CustomerorderCancellationLog::isReversalWaived)`
  - same file, the `completeReversal` waived-share loop: `if (!l.isReversalWaived() || l.getPicktostockunitId() == null) { continue; }`
- **Claim:** Q2 makes `reversal_waived` the only thing that separates a waived row from a completed one, because both carry `reversal_completed_at`. But every fixture that feeds these two filters is either pending or waived-and-stamped:
  - T3's already-waived sibling uses `waivedLog`, which sets both fields.
  - T22a–d and IT T22 also use waived rows only.
  - In IT T18 the completed row sits on a different stock unit.
  - So the mutant `isReversalWaived` → `l.getReversalCompletedAt() != null` gives the same answer on every fixture and survives in both places.
- **Failure scenario (the mutant):**
  - Row A was completed normally and moved 2 units off stock unit X. X now holds 3 units that belong to another order.
  - The operator waives B (amountPicked 1, on the tote).
  - The mutant sums A + B = 3, finds X's 3 ≤ 3, and releases another order's goods-out lock (100 → 0).
  - This is exactly the release the plan's "completed rows are excluded" sentence forbids.
- **Fix:** add a unit fixture with a completed, non-waived sibling on the same stock unit (`waiveLog` + `setReversalCompletedAt`, `reversalWaived=false`). Assert the lock is kept in `waiveReversal`, and that the residue is re-locked in `completeReversal`.
- Confidence the gap exists: HIGH. Mutant survival: UNVERIFIED.

**M2 — T22b's comment names a mutant its fixture cannot kill.**
- **File:** `src/test/java/net/aim_ai/wms/unit/service/CancellationReversalServiceUnitTest.java`, T22b: `// Residue sits between A's and B's amounts, so counting the COMPLETED row as "waived" flips it.`
- **Claim:** the waived share is read before the movement loop, so B is still pending at that point. No completed row exists in the fixture.
  - What T22b actually kills is "drop the waived filter altogether" (pending B gets counted: 1 + 3 = 4 ≥ 2).
  - It does not kill "count completed rows" (M1's mutant), which is what the comment says.
- **Failure scenario:** a reader or PIT triage trusts the comment, marks M1's mutant as covered, and the gap stays open.
- **Fix:** reword the comment to "counting a PENDING sibling as waived flips it", and let M1's new fixture cover the completed-row case.

---

### Low

**L1 — The Java reason check and the database CHECK disagree on control characters.**
- **Files:**
  - `CancellationReversalService.java`: `if (reason == null || reason.isBlank()) {` … `final String trimmedReason = reason.trim();`
  - `V2.2.34__cancellation_reversal_waive.sql`: `btrim(reversal_waive_reason) <> ''`
- **Claim:**
  - `isBlank()` only looks for `Character.isWhitespace`, which does not include U+0000–U+0008 or U+000E–U+001B.
  - `trim()` strips everything ≤ U+0020.
  - So `reason = "\u0001"` passes validation, trims to `""`, and is written as an empty reason.
- **Failure scenario:**
  - On PG the flush fails the CHECK (23514) and surfaces as `DataIntegrityViolationException`. The mobile handler turns that into 409 "This change conflicts with another active order… retryable", which is wrong on both counts.
  - The H2 lane has no CHECK and silently stores `""`.
- **Fix:** after trimming, add `if (trimmedReason.isEmpty()) throw new BusinessException("reason required");`, or use `strip()` and then `isEmpty()`. Add a T8 row for `"\u0001"`.

**L2 — `waiveLockRetained` can say false while the waive really did keep the lock.**
- **Files:**
  - `CancellationReversalService.toDetailDto`: `&& su.getAmount() != null && su.getAmount().signum() > 0`
  - plan §3.2 step 5 (N4): "In that case close the row and report `waiveLockRetained`."
- **Claim:** take an empty stock unit at lock 100, on the tote, recovered in this call (case i′ + N4). The waive keeps the lock (it lands in the log line's `lockRetained=[…]`), but the DTO says `waiveLockRetained=false`.
  - The flag is also worked out live each time. A waived row whose stock unit is later reserved again by an unrelated pick shows the warning, even though the waive did not cause it.
- **Failure scenario:** the operator log and the mobile badge disagree about the same stock unit. The follow-up "supervisor release" (plan §10) would use this flag as its input and miss the N4 rows.
- **Why Low:** §3.4 specifies the `amount > 0` rule and T21b pins it. The disagreement is inside the plan, and 0 such rows were measured on PRD.
- **Fix:** accept this and note it in the DTO javadoc, or record the retention on the row in a later ticket.

**L3 — The URL sysprop stays in the Caffeine cache after the IT fixture deletes it.**
- **File:** `CancellationReversalLockClearIntegrationTest.java`, `@AfterEach void removeTheReversalUrlSysprop() { … syspropRepository.deleteById(reversalUrlSysprop.getId()); …}`
- **Claim:**
  - `SyspropService.getSysvalue` is `@Cacheable(… unless = "#result == null")`, with a 2-minute TTL in `CacheConfig:36`.
  - Deleting through the repository does not evict the cache entry.
  - So for up to 2 minutes, later tests in the same H2 context still see the reversal URL as configured.
- **Failure scenario:** a later test in that context expects "URL not configured, no enqueue". It enqueues instead, or throws `EntityNotFoundException` on a missing batch. The result depends on test order.
- **Status:** I found no test that is affected today (UNVERIFIED). `CancellationReversalParcelSourceIntegrationTest` follows the same pattern.
- **Fix:** also evict the `sysprops` cache entry, or clear the cache through `CacheManager`, in the `@AfterEach`.

**L4 — The contract test finds the handler by its method name.**
- **File:** `CancellationWaiveContractUnitTest.java`: `.filter(m -> m.getName().equals("waiveReversal") && m.getParameterCount() == 2)`
- **Claim:** this breaks the repo rule "never key an assertion on a handler method name". The consequence is only a false red on a rename, not a false green, and the MockMvc T11 in `FunctionGuardMockMvcUnitTest` already checks the gate by path (`post("/v3/cancellation/1/waive")`).
- **Fix:** find the handler by its `@PostMapping` path `"/{customerOrderId}/waive"` instead.

**L5 — No test has two targets on one stock unit with different tote states.**
- **File:** `CancellationReversalService.java`: `allTargetsOnTote.merge(suId, state == ToteState.ON, Boolean::logicalAnd);`
- **Claim:** every T2, T3 and T5 fixture puts one target on each stock unit. The mutant `logicalAnd` → `logicalOr` survives.
- **Failure scenario (the mutant):** one row matches the tote label and a sibling row carries an earlier tote label of a multi-tote order. The mutant releases the lock even though one row cannot be proven to be on the tote.
- **Fix:** add a T3 case with two targets on one stock unit, one ON and one UNKNOWN (label mismatch), with the stock unit owned. Expect the lock to be kept.

**L6 — Moved code keeps a misleading error message.**
- **File:** `CancellationReversalService.enqueueReversalCompletedIfClosed`: `} catch (Exception e) { LOG.error("Failed to serialize reversal outbox payload …"); throw new FacadeException("Failed to serialize reversal outbox payload", e);`
- **Claim:** the try block wraps `outboxService.enqueue(...)` as well as serialization. A persistence failure inside enqueue therefore gets reported as a serialization failure. This existed before; the extraction copied it verbatim and now waive uses it too.
- **Fix:** catch only `JsonProcessingException` around `writeValueAsString`, or reword both messages.

**L7 — `waiveReversal` is about 150 lines.**
- **File:** `CancellationReversalService.waiveReversal`, sections `// 1. Validate.` through `// 6. Notify`.
- **Claim:** it is well commented, but it has five phases and a branchy stock-returned predicate, which puts it well past the 50-line guideline and a cyclomatic complexity of 10.
- **Fix (optional):** pull out `validateWaiveInput(...)`, `prevalidateTargets(...)` (returning stock units, on-tote flags and recovered ids) and `decideReleases(...)`. Behaviour stays the same.

---

### Open questions (not blocking)

- **[Low] Possible PG deadlock across orders (confidence LOW).**
  - A waive of order B and a complete of order A could lock stock units X and Y in opposite orders. For the waive the order comes from load order at flush; for the complete it is log order.
  - This needs two reused totes shared by two orders at once. PG would detect it and abort one side. I could not confirm it is reachable.

---

### Checked and clean

- **BigDecimal comparisons:** all use `compareTo` or `signum`, never `equals`. The ownership check is `su.getAmount().compareTo(share) <= 0`, and the residue check is `compareTo(waivedShare.getOrDefault(..., ZERO)) > 0`, ANDed onto the existing terms and never a standalone OR.
- **Null handling:**
  - `isLock(Integer, int)` guards the Integer unboxing.
  - `stockReturned` is rejected when null before the `if (stockReturned)` unbox.
  - A null `amountPicked` fails closed in both `ownsAllStock` and `waivedShareUnknown`.
  - A null amount counts as "has stock" in the refusal check.
  - A missing stock unit or unresolvable id closes the row without touching stock (iii-a).
- **Stock-returned refusal:** it matches every row of the §3.2 stock-effect table: SHIPPED always; amount > 0 with lock 100 or not-OFF refused; amount 0 allowed.
- **Tote state:** four states, fails closed. A null unit-load id, a missing view, a null or unknown type, a label mismatch and a null tote label all read UNKNOWN. It does not reuse the fail-open `SourceContainerGuard.judge`.
- **Entity aliasing:**
  - `pending`, `all` and `targets` share the same managed instances (persistence-context identity).
  - `ownsAllStock` runs before stamping, so targets and already-waived rows never overlap, as its comment says.
  - The recovery's in-memory id change is seen consistently.
- **Flush ordering:**
  - In `completeReversal`, the waived share is read once, before the loop. The only dirty state then is the recovery save, so the residue restore stays unflushed.
  - In waive, the tote-state queries AUTO-flush only the recovery save.
  - The stamps and lock clear flush at `findPendingReversals` inside the enqueue, so the suppression read sees them.
- **Lock order:** FOR UPDATE on the log rows (the same finder as complete) comes before any stock-unit UPDATE. Log UPDATEs flush ahead of stock-unit UPDATEs by load order, and would do so even with `order_updates`.
- **Transactions:**
  - `waiveReversal` has `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`.
  - `EntityNotFoundException` is a RuntimeException, so it rolls back by default.
  - The outbox enqueue runs inside the same transaction.
  - `detail()` is a self-call and joins the waive transaction.
  - Nothing writes outside a transaction.
- **HTTP status mapping:** BusinessException → 422 and EntityNotFound → 404 through the `@Order(0)` `RestExceptionHandler`. An optimistic-lock failure on the stock-unit `@Version` → 409. `MobileEndpointExceptionHandler` only catches what is left over.
- **Edge-triggered waive:** when no target is pending it returns early with no write and no enqueue (T7). Complete stays level-triggered with the whole-order suppression (T19, T19b, T20).
- **Query count:** each target costs one stock-unit find plus two tote-state reads, and `toDetailDto` adds one stock-unit find plus two reads per waived row. PRD has 17 rows or fewer per tenant, so this is not significant.
- **Migration V2.2.34:**
  - Idempotent: `ADD COLUMN IF NOT EXISTS`, a `pg_constraint` guard on the CHECK, and `WHERE NOT EXISTS` on the grants (no ON CONFLICT).
  - The CHECK holds for every existing row.
  - The IT asserts SQLSTATE 23514 and checks the second apply is a no-op, with uniqueness dropped first.
- **Authorization:**
  - The method-level `@RequiresFunction` replaces the class gate. The MockMvc T11 checks by path, with 403 for view-only and 200 past the gate.
  - initDB grants outbound-manager and super-admin only.
  - The arch-test allow-list and the audit SQL step 5 are updated.
- **Log labels:** each matches its enclosing method (`waiveReversal`, `enqueueReversalCompletedIfClosed`, `recoverPicktoStockunitId (for {caller})`).
- **Constants and naming:** `WmsConstants` is used for locks, types, function and sysprops. The one new literal is the named constant `WAIVE_REASON_MAX_LENGTH`. No test name contains a count.
- **IT hygiene:**
  - The H2 `BaseRollbackIntegrationTest` commits, so outbox rows are counted per `aggregate_id`, never globally.
  - Every order, batch and tote is fresh per test.
  - T18 carries a positive control that it can enqueue.
  - T18b rereads through a new transaction, so the "commits nothing" check is real.
  - T15 (`BaseRepositoryIntegrationTest`, `@Transactional("tenantTransactionManager")`) really does roll back, as its comment says, and carries a positive-control row.
- **Unit fixtures:**
  - The pick-to unit-load id never equals the tote's id, which kills the id-comparison mutant.
  - OFF and PARCEL unit loads share the log's label, which kills the label-only mutant.
  - The `<=` boundary, the null guard, the recovered guard, `!= OFF` versus `== ON`, and the `amount > 0` boundary on the DTO flag each have a test that kills them.
- **Comments:** the ones in the new code match what it does (checked the `waiveReversal` javadoc, `ownsAllStock`, the waived-share block, the residue term, the `ToteState` javadocs and the migration header). The only exception is M2.

### Positive observations
- Every decision is made before any write, so a refused waive commits nothing, and the IT proves it (T18b).
- The unknown tote state fails closed instead of reusing the permissive guard.
- One shared enqueue builder means the waive and complete payloads cannot drift (T6 compares them byte for byte).
- The waived share is read before the loop specifically to keep the tested "deliberately NOT flushed" behaviour.
- The IT fixture design is careful: a real Tote, a real pick-to unit load, a batch, counts keyed by id, and positive controls. The migration IT asserts on SQLSTATE rather than message text.
- The security-context cleanup added to `FunctionGuardMockMvcUnitTest` stops one test class from leaking state into the next.

### Recommendation
**APPROVE.** Fix M1 (one new fixture per method) and M2 (a comment edit) in the same pass, along with the Lows.
