# SBDEV-3857 — round-3 review of HEAD 82212802 (code-reviewer lane, read-only, nothing built or run)

Scope: `git show HEAD` in `.claude/worktrees/wms2-api/SBDEV-3857` (2 files, +9/-5). Answers round-2 N-1 / N-3.

## Round-2 findings
| # | Status | Evidence |
|---|---|---|
| N-1 | **FIXED** | `MobileCycleCountServiceUnitTest.java:1889` and `:1939`: `findByIdForUpdate(10L)` is now a strict `when`. Both are reached: `openPosition` → `lockStockUnitOf` → `LockReads.forUpdate`, where the mock `unwrap` gives null, so the call goes through the finder with arg 10L. That means no UnnecessaryStubbing and no PotentialStubbingProblem. The dropped `lenient findById(10L)` was dead, because the refusal fires before any `findById` on the stock unit. New InOrder at `:1950-1952`: (a) drop `entityManager.refresh(position)` → "wanted but not invoked" → red; (b) refresh before lock → red; (c) state check moved back to `openPosition` before the lock → no lock call → red (strict stub plus InOrder). The author's mutant claim holds: the race test at `:1906` also goes red, through its `doAnswer` refresh. |
| N-2 | **CONFIRMED unreachable** (no change needed) | `git grep` of src/main finds no `stockunitRepository.delete*` and no `DELETE FROM stockunit`. GOING_TO_DELETE is a lock-state flag only (`StockunitBusinessService.java:595`), not a purge. SDR: `StockunitRepository` is exported, but `Stockunit.class` is in `SDR_WRITE_WITHDRAWN` (`RestConfiguration.java:556`), and `:567-572` disables POST/PUT/PATCH/DELETE for item and collection. So no hard delete path exists. |
| N-3 | **NOT FIXED: the new text is false** | See R3-1. |

## New findings

### [LOW] R3-1: the javadoc says "HTTP 500"; the response is actually 409
- File: `MobileCycleCountService.java:311-313`. Confidence: HIGH.
- It is true that `CycleCountLosController` does not catch it: `:264` catches only `BusinessException`, and `:287/:289` catch only Business/Facade.
- But the exception still reaches `RestExceptionHandler` (`@Order(0)`, unscoped `@ControllerAdvice`, `:47-48`). Its `@ExceptionHandler(ObjectOptimisticLockingFailureException.class)` at `:384-391` returns **409 CONFLICT**, as a ProblemDetail with `retryable=true` and the text "The record was modified by another user. Please retry."
- This handler outranks `MobileEndpointExceptionHandler` (`LOWEST_PRECEDENCE`). That class's own javadoc (`:51-55`) says "optimistic/pessimistic lock → 409 keep winning".
- Round-2 N-3 itself said "a 500", so the author copied the reviewer's error. This is the "fixing a false claim makes a new one" trap.
- Fix: "...fails this count at flush with ObjectOptimisticLockingFailureException. CycleCountLosController does not catch it, so RestExceptionHandler answers 409 (retryable ProblemDetail). Nothing is written; the count rolls back whole."
- The PR-body residual note must say 409 too, not 500.

### [LOW] R3-2: on the first count, the InOrder does not pin that the state is checked after the refresh
- File: `MobileCycleCountServiceUnitTest.java:1936-1952`. Confidence: MEDIUM.
- The stored position is FINISHED before the refresh. So a mutant that runs `requireOpen` between the lock and the refresh still refuses, and stays green on this path.
- This is acceptable today: `requireOpen` sits inside the shared `lockStockUnitOf` (`:315-320`), and the SKU race test at `:1906` pins the refresh→check order for that helper.
- Fix (optional): clone the `doAnswer`-refresh race test for `countCycleCountStockUnit`.

## Positive observations
- The lenient stubs were changed to strict exactly where the post-fix path must go. Shared helper stubs stay lenient, which is defensible.
- The InOrder targets the lock-then-refresh edge, which is the one that matters.
- The N-2 decision to leave the code unchanged is correct, and it is now backed by the SDR write-withdrawal evidence.

## Recommendation
**APPROVE.** No Critical, High or Medium findings. N-1 is fixed and N-2 is confirmed. N-3 needs a one-line javadoc correction (R3-1: 500 → 409), applied in the same pass per the fix-Lows rule. Re-reviewing that comment-only change needs only a glance at the diff.
