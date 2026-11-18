head: 0f7a083097510273ffb2301f12baf8a02db452fd

# SBDEV-3999: scoped fifth review of commit 0f7a0830

- Worktree: `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3999`. The commit under review is `0f7a0830` (parent `9b4a24d7`). It answers `review-code-4.md` (0 High, 0 Medium, 3 Low).
- Diff: `UnitLoadController.java` (+6/-5, comment only) and `UnitLoadControllerUnitTest.java` (+23, one new test).
- How I checked: `git show HEAD`, then grep and targeted `sed` reads of the worktree files: `UnitLoadController.java:135-210`, `UnitloadBusinessService.java:330-336, 594-645`, `UnitloadService.java:551-593, 744-815`, the test file's helper and `never()` sites, `NeverMatcherNullBlindnessArchTest.java:799`, and `git show 57c1253a` for the removed pre-check.
- I did not run mvn. Nothing was executed, so this report gives no compile or test verdict, and the mutation claim in the commit message ("expected: DELETED but was: null") was checked by reading only.
- `git status` in the worktree was clean. The reviewer authored none of this change.

## Verdict: APPROVE (0 High · 0 Medium · 3 Low)

The comment is now accurate and no longer reads as a closed set. The new test pins the controller-level decision it says it pins. All three review-4 Lows are answered: L1 and L2 fully, L3 in substance, though without the suggested `InOrder`. What remains is test precision and nits.

## 1. Comment rewrite (`UnitLoadController.java:149-154`)

```java
// cycle). Everything else can still stop a batch part-way — for example deleteUnitLoad's own refusals
// (a container that still has children, a stock unit moved or removed concurrently) and FacadeExceptions
// from the retire (such as a reserved stock unit). Children are deliberately not pre-checked: a carrier
// selected together with its own children deletes when the children come first in the batch, because
// each child's retire normally clears its carrier link (not when that child already sits on Nirwana,
// where sendToNirvana returns early), and a pre-check would refuse the whole batch.
```

| Claim | Verified |
|---|---|
| Closed set avoided | ✔ "Everything else … for example" makes both parentheticals illustrative. "Everything else" is itself universal, and it is true: anything outside the up-front list can surface inside the delete loop. That includes uncaught runtime exceptions such as `EntityNotFoundException` at `UnitloadBusinessService:640` or optimistic-lock failures at commit, which escape the handler as a 5xx, still part-way |
| "a container that still has children" | ✔ `UnitloadService` deleteUnitLoad `"Container has child container! Please delete them first."` (method line +21, about `:764`). `sendToNirvana:622-624` `"… is carrier!"` is a second instance |
| "a stock unit moved or removed concurrently" | ✔ `"Stock unit " + stockUnitId + " was moved or removed from container "` (about `:782`) |
| "FacadeExceptions from the retire (such as a reserved stock unit)" | ✔ `StockunitBusinessService:578` `FacadeException("STOCKUNIT_HAS_RESERVATION", …)`. Review-4 L2's "two disjoint cases" wording is fixed |
| "each child's retire normally clears its carrier link" | ✔ `deleteUnitLoad` → `unitloadBusinessService.sendToNirvana(…)` (about `:805`) → `transferUnitLoadToLocation(unitload, nirvanaLocation, true, …)` (`:638`) → `unitload.setCarrierunitloadId(null); unitload = unitloadRepository.save(unitload);` (`:334-335`). "Retire" is used consistently with the rest of the comment and with the error text ("retired to Nirwana") |
| Nirwana exception: "not when that child already sits on Nirwana, where sendToNirvana returns early" | ✔ `UnitloadBusinessService:633-636`: `if (nirvanaLocation.getId().equals(unitload.getStoragelocationId())) { LOG.warn(…); return; }`. This return comes before `transferUnitLoadToLocation` at `:638`, the only place the link is cleared, so the link survives. deleteUnitLoad's own SBDEV-3500 comment already names the same early return, so the two are consistent |
| "a pre-check would refuse the whole batch" | ✔ 57c1253a's block: `if (!unitloadRepository.findByCarrierunitloadId(unitLoad.getId()).isEmpty()) { refused.add(…); continue; }` was followed by `"Nothing was deleted: "` |

**Side check: is the SBDEV-3999 bin-departure guard covered up front?** "FacadeExceptions from the retire" no longer names the retire's BusinessExceptions. The relevant one is `refuseFixedAssignmentBinDeparture` (`UnitloadBusinessService:596-612`), which refuses an FLA container leaving its own bin. The pre-run's `findByAssignedlocationIdIn` (by container, `UnitloadService:571-579`) refuses every FLA container in the subtree, so the guard's case is a subset of the pre-checked one. The narrower wording therefore hides nothing the operator would hit outside a race. ✔

## 2. New test `doesNotPreRefuseACarrierBatchedWithItsOwnChild` (`UnitLoadControllerUnitTest.java:307-328`)

- **What it pins.** `ids = "41,42"`, the child carried by 42, and `findByCarrierunitloadId(42L)` stubbed to `[child]`. It asserts `message == "DELETED"` and two `deleteUnitLoad(…, eq(true), …)` calls. With 57c1253a's block re-added, 42 hits the non-empty branch, `refused` is non-empty, and the body becomes `{"errors": …}`. `body.get("message")` is then `null`, so the test goes red with the message the commit quotes. Call 41 is unstubbed and gets the RETURNS_DEFAULTS empty list, so the test refuses for 42 only, for the right reason. ✔ It pins "no up-front refusal of a carrier batched with its child" for this mutant.
- **Is `lenient()` the right lever?** Yes.
  - The class runs `@ExtendWith(MockitoExtension.class)` with no `@MockitoSettings`, which means STRICT_STUBS by default.
  - The correct controller never calls `findByCarrierunitloadId`, because the pre-run is mocked. A strict stub would therefore fail the green build with `UnnecessaryStubbingException`.
  - `lenient()` is the standard way to arm a stub that only the mutant consumes.
  - `child.setCarrierunitloadId(42L)` also arms a second mutant shape: a child-side check reading the entity.
  - The limits are in L1 below.
- **NeverMatcher inventory.** The new test adds no `never()`. Its only verify is `verify(unitloadService, times(2)).deleteUnitLoad(any(), any(), eq(true), any())`, with no `anyBoolean()`. `grep -n "never()"` still returns exactly `:250`, `:273`, `:274` and `:304`, and 3 of those carry `anyBoolean()`. `"UnitLoadControllerUnitTest:3"` (`NeverMatcherNullBlindnessArchTest.java:799`) is unchanged and correct. ✔ No movement.

## 3. Disposition of review-4's Lows

| Review-4 | Status at 0f7a0830 |
|---|---|
| L1: carrier-link claim vs sendToNirvana's early return | **Resolved**: the comment names the exception explicitly |
| L2: parentheticals read as complete, and the reservation was listed beside FacadeException as if disjoint | **Resolved**: "for example", and "FacadeExceptions from the retire (such as a reserved stock unit)" |
| L3: no pin against re-adding the child pre-check | **Resolved in substance**. The suggested `InOrder` (child then carrier) was not adopted; see L2 below |

## Issues

### [LOW] L1: the pin arms only the `unitloadRepository.findByCarrierunitloadId` mutant
File: `src/test/java/net/aim_ai/wms/unit/controller/UnitLoadControllerUnitTest.java:320`
Confidence: HIGH

```java
lenient().when(unitloadRepository.findByCarrierunitloadId(42L)).thenReturn(java.util.List.of(child));
```

A re-added "has children" refusal that asks the question some other way would stay green:
- a different repository method, for example a future `existsByCarrierunitloadId` or `countBy…`. The mock default is `false`/`0`, so the refusal never fires. None of these exists in `src/main` today.
- a check placed inside `deleteUnitLoadRecursivePreRun`, which is mocked here.

The DisplayName "(child-first deletes it)" also overstates what a mocked service can show. The in-body comment is honest about this ("this pins only that the controller does not refuse the batch").
- Fix: optional.
  - Trim the DisplayName to "…is NOT refused up front".
  - The service-level guarantee needs the real-PG IT noted in review-4 §3, using `DeleteContainerWithStockIT.childUnitload(...)`.
  - Accept the residual mutant space as is: it is the shape 57c1253a actually took.

### [LOW] L2: the verify does not pin the order or the identity of the two deletes
File: `UnitLoadControllerUnitTest.java:326`
Confidence: HIGH

```java
verify(unitloadService, times(2)).deleteUnitLoad(any(), any(), eq(true), any());
```

- Review-4 L3 suggested `InOrder` 41 then 42. As written, the test passes for a controller that reorders the batch (carrier first, which would fail in production on `deleteUnitLoad`'s child guard) and for one that deletes the same container twice.
- Neither is a pre-refusal, so the test's stated claim holds. But the comment's mechanism, "deletes when the children come first", rests on the controller preserving the request order, and nothing pins that.
- Fix:

```java
InOrder o = inOrder(unitloadService);
o.verify(unitloadService).deleteUnitLoad(same(child), any(), eq(true), any());
o.verify(unitloadService).deleteUnitLoad(same(carrier), any(), eq(true), any());
```

  Keep `times(2)` or add `verifyNoMoreInteractions` on the delete. About 3 lines.

### [LOW] L3: nits in the new test
File: `UnitLoadControllerUnitTest.java:310, 320`
Confidence: HIGH

- `java.util.List.of(child)` is fully qualified, although the file imports `java.util.*` and uses bare `List.of(...)` at `:434`, `:533` and `:572`. Use `List.of(child)`.
- The in-body comment "On develop the child's delete clears its carrier link" describes production code by branch name. Once this merges it reads oddly. Something like "In UnitloadBusinessService.transferUnitLoadToLocation the child's delete clears…" would say it better.

## Positive observations
- The comment now carries its own exception list, with the precise mechanism (`sendToNirvana` returns early). That is exactly the information a future maintainer needs to avoid reintroducing the 57c1253a pre-check.
- `lenient()` is used deliberately and narrowly, with the one stub that only the mutant consumes, and the test comment states the limit of a mocked service.
- The commit message records the mutation result ("expected: DELETED but was: null"), which matches the red that reading the code predicts.
- The arch-test inventory is untouched and still correct. The new verify uses `eq(true)` rather than `anyBoolean()`, which keeps it out of the null-blindness scan by construction.

## Recommendation
**APPROVE.** No High or Medium findings. All three of review-4's Lows are answered. L2 (the `InOrder` and `same(...)` verify) is the one Low worth doing under the house "address Lows" rule: about 3 lines, and it pins the order dependency the comment relies on. L1 and L3 are optional.
