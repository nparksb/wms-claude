# SBDEV-3857 — round-4 review of HEAD 8cecb91f (code-reviewer lane, read-only, nothing built or run)

Scope: `git show HEAD` in `.claude/worktrees/wms2-api/SBDEV-3857` (2 files, +29/-1). Answers round-3 R3-1 / R3-2.

## Round-3 findings
- **R3-1: FIXED.** The javadoc at `MobileCycleCountService.java:311-314` now says RestExceptionHandler answers 409 (a retryable ProblemDetail). Re-checked:
  - `CycleCountLosController` (package `controller.mobile`) catches only Business/Facade (`:100-289`) and has no `@ExceptionHandler`.
  - `RestEndpointExceptionHandler` (HIGHEST_PRECEDENCE) is scoped to `controller.rest`, so it does not apply here.
  - `RestExceptionHandler` is `@Order(0)` and unscoped (`:47-48`). Its handler at `:384-391` returns CONFLICT with `retryable=true`, and it outranks `MobileEndpointExceptionHandler` (LOWEST_PRECEDENCE, `:58-59`).
  - JpaTransactionManager's commit translation (HibernateJpaDialect) turns a stale version into ObjectOptimisticLockingFailureException, so that is the type the advice sees.
- **R3-2: FIXED.** The new test is at `MobileCycleCountServiceUnitTest.java:1932-1957`.
  - **Meaningful.** `stored` starts STARTED and only the `doAnswer` on `refresh(stored)` makes it FINISHED. If `requireOpen` runs before `refresh` (`:319-320` swapped), the check passes, and with count 12 equal to amount 12 the happy path saves and returns with no exception. `assertThatThrownBy` then fails. Any other exception also fails, through `hasMessageContaining`. The mutant is red, as the author reported. Dropping the refresh is red too.
  - **Strict stubs.** All three are reached with matching arguments, so there is no UnnecessaryStubbing or PotentialStubbingProblem:
    - `findById(5L)` is reached through `openPosition` (`:303`).
    - `findByIdForUpdate(10L)` is reached through `LockReads.forUpdate`: the mock's `unwrap` returns null, so it uses the finder.
    - `refresh(stored)` gets the same instance that `findById` returned.
  - **Nothing written.** It verifies that `cyclecountPositionRepository.save` and `cyclecountRepository.save` are never called. Those are the only two writes on this path (`:451`, `:469`), so the assertion is sufficient.

## New findings
- [LOW, conf HIGH] N4-1 `MobileCycleCountServiceUnitTest.java:1932-1957`: unlike its SKU sibling (`:1926-1928`), the new test has no InOrder. A refresh-before-lock mutant stays green **in this test**. It is still killed by `:1977-1979`, so coverage holds. Fix (optional): add the same `inOrder(stockunitRepository, entityManager)` pair so each race test pins its own ordering.
- [LOW, conf HIGH] N4-2 `MobileCycleCountServiceUnitTest.java:1711-1712` (outside the HEAD diff, branch-only since 3ebf76d0): the nested-class javadoc still says "constructor-built here, with no EntityManager, so LockReads asks the locking finder directly". 84094313 later injected a mock EntityManager (`:100-113`). The finder path now holds because the mock's `unwrap` returns null. Fix: reword it to match `:98-99`.

## Positive observations
- The javadoc now states the real wire behaviour, and its precedence claim checks out against all three advices.
- The race test reuses the sibling's `doAnswer`-refresh pattern, so its failure mode is the right one.

## Recommendation
**APPROVE.** R3-1 and R3-2 are fixed. Two Low findings remain (N4-1 optional hardening, N4-2 stale comment), to be fixed in the same pass under the fix-Lows rule.
