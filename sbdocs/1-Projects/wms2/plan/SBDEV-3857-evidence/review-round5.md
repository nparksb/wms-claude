# SBDEV-3857 review round 5: commit 1b8ce0ad (on develop as 56797fed)
Scope: `git show 1b8ce0ad`, 1 file, +5/-2, `MobileCycleCountServiceUnitTest.java`. Read only, Maven not run.

## N4-1: FIXED
- The added lines are `:1955-1957`, `inOrder(stockunitRepository, entityManager)`, then `findByIdForUpdate(10L)`, then `refresh(stored)`. They are identical to the SKU sibling at `:1926-1928`.
- Same instance: yes. `countCycleCountStockUnit` (`MobileCycleCountService.java:414-415`) passes `openPosition(...)` to `lockStockUnitOf`. That is `cyclecountPositionRepository.findById(5L)`, stubbed to return `stored` (`:1938`). `lockStockUnitOf` refreshes that exact object (`:319`).
- The author's mutant claim holds. If `refresh(position)` moves above the `LockReads.forUpdate` call (`:317`), the single refresh runs before the finder, and `inOrder.verify(entityManager).refresh(stored)` has nothing left after `findByIdForUpdate`, so the test goes red. The throw assertion alone would stay green under that mutant, because the `doAnswer` still finishes `stored`. The InOrder is therefore the instrument that kills it.

## N4-2: FIXED
- `:1711-1712` matches the code. The mock `entityManager` is set in `setUp` (`:100-113`, `ReflectionTestUtils.setField`). A mock's `unwrap` returns null, which sends `LockReads.forUpdate` (`LockReads.java:87-90`) straight to `lockingFinder.apply(id)`. The test stubs `refresh` with `doAnswer` (`:1940-1943`). Both clauses are accurate, and the javadoc agrees with the field comment at `:98-99`.

## Other findings (follow-up only, nothing blocks)
- [LOW, conf HIGH] N5-1 `:1943`, `:1957` (and `:1916`, `:1927` in the sibling): Mockito matches `refresh(stored)` with `equals`, not identity. `AbstractBaseEntity.equals` (`:70-75`) is id-based, so a posted copy with id 5 would also satisfy both the stub and the verify. Suppose a mutant refreshed a different `CyclecountPosition` with id 5 but checked `stored`. The stub would still finish `stored`, and the test would stay green. Today `lockStockUnitOf` has only the stored instance in scope, so the mutant needs a signature change and is unlikely. Fix (optional): use `same(stored)` in the `doAnswer` stub and in the `inOrder.verify` of both race tests.
- No other issues. The diff is test-only, with no production change and no new imports (`InOrder` is at `:18`, `inOrder` comes from `Mockito.*` at `:33`).

## Positive observations
- Each race test now pins its own lock-then-refresh order, so neither depends on a sibling to kill the reorder mutant.

**APPROVE.** N4-1 and N4-2 are fixed. N5-1 is an optional Low hardening for a later pass.
