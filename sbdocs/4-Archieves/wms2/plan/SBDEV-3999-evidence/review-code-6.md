head: 2e42001759dd4fbdd36b247ef96fc4db055688a6

# SBDEV-3999: scoped sixth (final) review of commit 2e420017

- Worktree: `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3999`. The commit is test-only: `UnitLoadControllerUnitTest.java` (+9/-5). It answers `review-code-5.md` (0 High, 0 Medium, 3 Low).
- How I checked: `git show HEAD`, the file's import block, `grep -n "never()"` and `grep -n anyBoolean` on the test, `NeverMatcherNullBlindnessArchTest.java:799`, and the controller's `bulkDeleteContainer` loop (`UnitLoadController.java:132-200`).
- I did not run mvn, so this report gives no compile or test verdict. The reviewer authored none of this change.

## Verdict: APPROVE (0 Critical, 0 High, 0 Medium, 0 Low)

## 1. Does InOrder + same() pin child-first order and container identity?

```java
InOrder order = inOrder(unitloadService);
order.verify(unitloadService).deleteUnitLoad(same(child), any(), eq(true), any());
order.verify(unitloadService).deleteUnitLoad(same(carrier), any(), eq(true), any());
```

- **Identity.** The controller loads each id with `unitloadRepository.findById(containerId).orElseThrow(...)` and adds that instance to `batch`. It then calls `unitloadService.deleteUnitLoad(unitLoad, comment, true, principal)` for each element of `batch`. The stubs return the `child` and `carrier` instances themselves, so `same(...)` matches by reference. That is the right choice, because `Unitload.hashCode()` returns `getClass().hashCode()` and an `eq()`-based match would be weaker. ✔
- **Order.** `batch` keeps the request order (`ids` = "41,42"). If the delete loop is reversed (carrier first), the first in-order verify consumes the child call at position 2, and the second verify finds no carrier call after it, so the test goes red. ✔
- **Duplicates.** Dropping `times(2)` loses nothing. An in-order `times(1)` fails when the matching chunk has more than one invocation, so a duplicate delete of the same container still goes red.
- **deleteUnitLoadRecursivePreRun calls on the same mock.** These do not interfere. InOrder checks only the relative order of the invocations it verifies, and other methods on the same mock are ignored. The pre-run calls also all happen before the delete loop. ✔
- **Strict stubs.** The class uses `@ExtendWith(MockitoExtension.class)` with no `@MockitoSettings`, so strict stubs apply. InOrder adds no stubbing. The three stubs keep their status: the two `findById` stubs are used, and `findByCarrierunitloadId` stays `lenient()`. No `UnnecessaryStubbingException` or `PotentialStubbingProblem` can come from this change. ✔
- **Static imports.** `inOrder` and `same` resolve through the existing `import static org.mockito.Mockito.*;` and `import static org.mockito.ArgumentMatchers.*;`. ✔

## 2. Import placement

`import org.mockito.InOrder;` sits after `java.util.*`. The file's import block was already unordered: `org.mockito.Mockito`, `java.util.HashMap` and `org.springframework.data.domain.Sort` sit at the top, ahead of the project imports. The new line follows the file's existing style. The import is used, it does not clash with anything, and nothing in the build enforces import order. This is not a defect.

## 3. Disposition of review-5's Lows

| Review-5 | Status at 2e420017 |
|---|---|
| L1: the DisplayName overstated what a mocked service shows, and the pin arms only the `findByCarrierunitloadId` mutant | **Resolved.** The new DisplayName, "…not refused up front; both are deleted, child first", claims only the controller calls the mock records. The comment now names the armed mutant explicitly ("it catches a pre-check asked through findByCarrierunitloadId"). The residual mutant space was accepted as optional |
| L2: the verify did not pin order or identity | **Resolved.** InOrder plus `same()`, as suggested (§1) |
| L3: fully qualified `java.util.List.of`, and "On develop" | **Resolved.** `Collections.singletonList(child)` is covered by `java.util.*`, and the comment now says "In production" |

## 4. NeverMatcherNullBlindnessArchTest "UnitLoadControllerUnitTest:3"

`grep -n "never()"` returns `:251`, `:274`, `:275` and `:305`. Of those, `:251`, `:274` and `:305` carry `anyBoolean()`. That is still 3 (the line numbers moved by +1 from the added import). The new verifies use `eq(true)` and no `never()`. The inventory entry at `NeverMatcherNullBlindnessArchTest.java:799` is unchanged and still correct. ✔

## Issues

None.

## Positive observations
- `same()` is the correct matcher for an entity whose `hashCode` is class-constant. It pins identity, not just equality.
- The comment now states exactly which mutant the test arms, so its limits are visible to the next maintainer.

## Recommendation
**APPROVE.** The SBDEV-3999 review loop can close on this commit.
