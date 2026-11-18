head: 334a8187

# SBDEV-3999 — scoped second review of fix commit 334a8187

- Worktree `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3999`, branch `fix/SBDEV-3999-fla-bin-departure-guard`, HEAD `334a8187` (parent `3186cff5`). Responds to `review-code.md` (head `3186cff5`).
- Instruments: `git show 334a8187`, `git grep` on the worktree, targeted reads. Mvn NOT run (a suite is in flight in this worktree); no compile or test verdict here, that belongs to the running suite. Read-only; nothing was edited.
- Reviewer authored none of this change.

## Verdict: APPROVE (0 High · 0 Medium · 5 Low)

The rebuttal of the first review's Medium holds. The bulk-delete pre-scan is read-only and leaks nothing raw. The guard edits and the new test pins are correct. What remains is comment drift and one coverage gap on a query the delete side now leans on entirely.

## 1. Rebuttal of the first review's Medium: HOLDS

`src/main/java/net/aim_ai/wms/repo/jpa/FixLocationAssignmentRepository.java:63-65`:
```java
@RestResource(path = "findDistinctByState", rel = "findDistinctByState")
@Query(value = "select * from fix_location_assignment f where f.assignedunitload_id in :unloadIdlist", nativeQuery = true)
List<FixLocationAssignment> findByAssignedlocationIdIn(@Param("unloadIdlist") List<Long> unloadIdlist);
```
The explicit native `@Query` overrides derivation, so the method matches `assignedunitload_id`. Unit-load ids in, container column matched: the call at `UnitloadService.java:569` is correct. The first review's Medium was wrong. I retract it.

The first review's L1 ("single/recursive delete answers with a 'move' message") falls with it. All three handlers call the pre-run before the delete:
- `UnitLoadController.java:111-112` `/deleteContainer`: `deleteUnitLoadRecursivePreRun(unitLoad, null)` → `deleteUnitLoad`
- `:179` (pre-scan) → `:188` `/bulkDeleteContainer`
- `:217` → `:221` `/deleteContainerRecursive`

`git grep` finds no other `src/main` caller of `deleteUnitLoad(` or `deleteUnitLoadRecursive(` outside `UnitloadService`'s own recursion. In the normal path an FLA container therefore gets "Can not delete. Fix assignment exists for …" from the pre-run. The bin-departure "move" text can appear only if an FLA is created between the pre-run and the delete, which is a race and acceptable.

Note: the pre-run refuses stranded FLA containers too (no on-bin filter). So "a stranded container stays retirable" now holds only for BOL build-truck, not for manual delete. That was already true before 3186cff5 (the pre-run has always refused them), so it is not a regression. The workflow doc row (`wms2-move-stock-unitload-workflow.md:125`) states this correctly ("refuses any FLA container").

## 2. Bulk delete pre-scan

- **Side-effect free: yes.** `deleteUnitLoadRecursivePreRun` (`UnitloadService.java:551-593`) only calls `findByCarrierunitloadId`, `assertCarrierChainIsAcyclic` (`:521`, which only does `findById` walks and throws), `findByAssignedlocationIdIn`, `findById`, `stockunitRepository.findByUnitloadIdIn`, and the static `assertNoGoodsOutStock` (`:719`, which only reads the list and throws). There are no saves, setters on managed entities or locks.
- **Non-BusinessException escape.** The pre-scan catches only `BusinessException`. `EntityNotFoundException` extends `RuntimeException`. Inside the pre-run it is thrown only from `findById(fla.getAssignedunitloadId())` on an id that was just found in `unitLoadIdList`, so it is practically unreachable. If it were thrown, it now escapes before any delete, where it used to escape after the earlier ids were deleted. That is strictly better. The pre-run does not declare `FacadeException`. The escape behaviour is otherwise unchanged from the old in-loop call.
- **Leak (SBDEV-3993 class): none.** Each collected text is a `BusinessException` message the pre-run built from domain data: labels, stock unit id, lock description. No `e.toString()`, cause or SQL text. The outer `new BusinessException(String)` goes through the `placeholder=%1$s` format with the joined text as an argument, so `%` or `{` in a label is not re-interpreted.
- **Ordering.** The To-Delete exit (`:169-172`) still runs before the pre-scan, and the SBDEV-3500 test `refusesTheWholeBatchWhenAnyContainerIsToDelete` pins it with `never().deleteUnitLoadRecursivePreRun(any(), any())`. Keeping it first is acceptable: a To-Delete container sits on Nirwana and its pre-run would only add noise. The cost is first-review Low #6: a mixed batch reports the To-Delete list only.

## 3. Leftover references to `isFixedAssignmentContainerOnItsBin`

`git grep isFixedAssignmentContainerOnItsBin` on the worktree finds nothing in src/main or src/test. In `sbdocs/` the only hit is the first review file. `wms2-move-stock-unitload-workflow.md` does not mention it. Its SBDEV-3999 text at `:125` already describes the pre-run path and the misnamed finder. Clean.

## 4. Guard changes (`UnitloadBusinessService.java:596-613`)

- `Optional.get()` is gone: it is replaced by `.map(...).orElse(false)`, which is correct and keeps `OptionalSafetyArchTest` clean.
- `unitload.getId() == null` short-circuits before the finder, which closes first-review L5. A transient unit load cannot be an FLA container, so returning early is right.
- The javadoc claim "Deletes are refused earlier, by `deleteUnitLoadRecursivePreRun` …, which all three delete endpoints call first" is **accurate** (see §1).
- The javadoc claim "Decides on the caller's `storagelocationId` snapshot, the same one `processTransfer` records as the move's source" is **accurate**: `:338` `sourceLocation = locationRepository.findById(storagelocationId)` (the caller snapshot) is passed into `processTransfer` and recorded at `:543`. That closes first-review L4 as "documented, accepted".

## 5. Test changes

- **Distinct ids.** The fixture moves to UL 7L ("UL-007") on bin 1L with `fla(bin=1L, ul=7L)`. The column-swap mutant `Objects.equals(fla.getAssignedunitloadId(), sourceLocationId)` now compares 7 to 1 and allows the move, so every refuse case goes red. Killed. That closes L2.
- **Lock-order pins.** `PickLineActivityCodeClassifier.BLOCK_REALIGN_CODES` (`:33-37`) = {MOVE_FIX_ASSIGNMENT, MANUAL_TRANSFER, TRANSFER, ON_HOLD}. Of the five parameterized codes {TRANSFER, MANUAL_REMOVAL, SEND_TO_NIRVANA, MANUAL_TRANSFER, TRUCK_LOADING}, only **TRANSFER and MANUAL_TRANSFER** are BLOCK_REALIGN. The `never().collectStockUnitIdsForUnitloadTree(any())` pin is meaningful for those two and vacuous for the other three, but harmless. The comment says so correctly. Hook A calls `collectStockUnitIdsForUnitloadTree` (`:238`) before `lockOwningPickingorders` (`:239`), so pinning the first call covers both.
- **`never().findByIdForUpdate(any())` on the null-code, ignoreLock=false case.** This is meaningful. `LockReads.forUpdate` (`LockReads.java:85-97`) falls through to `lockingFinder.apply(id)` when `entityManager.unwrap` returns null (a plain Mockito mock) or nothing is managed. So with the guard moved below the lock, `locationRepository.findByIdForUpdate` would be invoked and the pin would go red.
- **`lenient().doThrow(...)` stubs** in `UnitLoadControllerUnitTest:293-296`. Both stubs are exercised, so `lenient()` is unnecessary but harmless. The test kills the important mutant: putting the pre-run back inside the delete loop calls `deleteUnitLoad(plain)` for id 35 first, and `never().deleteUnitLoad` goes red. Asserting both `11-D06` and `11-C09` pins the "collect all refusals" behaviour against a stop-at-first mutant.
- **NeverMatcher inventory 2→3.** `deleteUnitLoad(Unitload unitLoad, String comment, boolean notifyCRM, Principal principal)` (`UnitloadService.java:744`) has a **primitive** `boolean`, so `anyBoolean()` is required and exempt-by-inventory is correct. The three sites are `UnitLoadControllerUnitTest:250, :273, :304`. The `:304` site was introduced in 3186cff5, so the inventory was short by one at that commit. This commit corrects it (see L4 for the comment).

## Findings

### [LOW] Stale SBDEV-3500 comment now contradicts the new pre-scan
File: `src/main/java/net/aim_ai/wms/controller/UnitLoadController.java:145-149`
Confidence: HIGH
```java
// To Delete and unknown ids only; the children / stock / carrier refusals and a FacadeException
// can still stop a batch part-way, exactly as before: ...
```
Issue: the goods-out-stock, carrier-cycle and FLA refusals are now pre-scanned at `:173-186`. Only the `deleteUnitLoad` in-loop refusals can still split a batch: "Container has child container!" (`UnitloadService.java:764`), the stock-moved refusal, and `FacadeException`. A reader of the block comment gets the old story.
Fix: reword to "To Delete and unknown ids here; the pre-run refusals (FLA container, goods-out stock, carrier cycle) just below; only deleteUnitLoad's own refusals (child container, stock moved) and a FacadeException can still stop a batch part-way."

### [LOW] Bulk delete is still not all-or-nothing for a container with children
File: `UnitLoadController.java:173-189` vs `UnitloadService.java:764`
Confidence: HIGH (read; not executed)
Issue: the pre-run passes a container that has children (it collects them and checks only FLA, goods-out and cycle). The non-recursive `deleteUnitLoad` then refuses it inside the loop, after the earlier ids were deleted. The new comment at `:173-175` says "run every container's pre-delete check BEFORE the first delete", which overstates. This is pre-existing (SBDEV-3500 scope), not a regression.
Fix (optional, existing ticket): add `unitloadRepository.findByCarrierunitloadId(id).isEmpty()` to the pre-scan with the same "has child container" text. Otherwise narrow the comment to "the pre-run's checks".

### [LOW] The delete side's only FLA refusal is now a misnamed native query with no real-DB pin
File: `FixLocationAssignmentRepository.java:63-65`; tests `UnitloadServiceUnitTest.java:866-1136` (all `findByAssignedlocationIdIn(anyList())` stubs)
Confidence: MEDIUM
Issue: with `isFixedAssignmentContainerOnItsBin` removed, every delete endpoint relies on this query to refuse an FLA container. Its name says "location". A tidy-up that deletes the "redundant" `@Query`, so that Spring derives the method from its name, would silently switch it to `assignedlocation_id`. Every unit stub uses `anyList()` and would stay green. The call-site comment at `UnitloadService.java:567-568` is the only guard. The `@RestResource(path = "findDistinctByState")` label is a second misnomer on the same method, also pre-existing.
Fix: rename to `findByAssignedunitloadIdIn` and keep the `@Query`. Update the ~8 stubs, which is a mechanical rename. Optionally add one real-PG assertion (for example in `FixLocationAssignmentServiceIT`, which already builds an FLA) that `deleteUnitLoadRecursivePreRun(container, null)` throws "Fix assignment exists". At minimum, add the rename to the ticket as a follow-up.

### [LOW] NeverMatcher inventory bump has no provenance comment
File: `src/test/java/net/aim_ai/wms/unit/config/NeverMatcherNullBlindnessArchTest.java:792-796`
Confidence: HIGH
```java
// SBDEV-3500: 0 -> 2. Two never() on UnitloadService.deleteUnitLoad ...
"UnitLoadControllerUnitTest:3",
```
Issue: every other bumped entry carries a "SBDEV-xxxx: a -> b" line naming the new site and the primitive parameter. This one still says "0 -> 2" over a value of 3.
Fix: add `// SBDEV-3999: 2 -> 3. never() on deleteUnitLoad in refusesTheWholeBatchWhenAnyContainerIsOnItsFixedAssignmentBin; param 3 is PRIMITIVE boolean notifyCRM.`

### [LOW] IT `@Autowired` field still mid-class (first-review L7, half addressed)
File: `src/test/java/net/aim_ai/wms/service/FixLocationAssignmentServiceIT.java:493`
Confidence: HIGH
Issue: the javadoc was correctly moved back onto `deleteCommitted` (`:544-550`), but `@Autowired private UnitloadBusinessService unitloadBusinessService;` still sits inside the SBDEV-3999 section, not with the other injections at `:67-76`.
Fix: move the field up to `:71`.

### Cosmetic (no severity)
- `UnitLoadControllerUnitTest:293-296`: `lenient()` on both `doThrow` stubs is unnecessary, since both are used. Dropping it would let strict stubs flag a future dead stub.
- The combined message repeats the prefix per id ("Nothing was deleted: Can not delete. Fix assignment exists for 11-D06; Can not delete. Fix assignment exists for 11-C09"). A parent and its child both in one batch would list the child's FLA twice. Readable enough.

## First-review items: disposition

| First review | Status after 334a8187 |
|---|---|
| Medium: wrong column in pre-run | **Withdrawn**: the rebuttal holds (§1). Residual risk recorded as L3 above |
| L1: delete gets the "move" message | **Falls**: all three endpoints pre-run first (§1) |
| L2: fixture id collision | **Fixed** |
| L3: no lock-order pin | **Fixed** (meaningful for TRANSFER, MANUAL_TRANSFER and the ignoreLock=false case) |
| L4: caller snapshot | **Documented** in javadoc, accurate |
| L5: null-id asymmetry | **Fixed** (the twin predicate was removed, and the guard short-circuits) |
| L6: To-Delete reported before FLA | **Kept by design**, pinned by the SBDEV-3500 test. Acceptable |
| L7: IT javadoc placement | **Javadoc fixed; field not moved** (L5 above) |
| L8: javadoc precision on removed predicate | **Moot** (predicate removed) |
| Open Q: FLA on a transfer lane | Unchanged. Still 0 on the three PRD DBs; nywh-shipitez still unqueried |

## Positive observations
- The author checked the native SQL instead of accepting the review. That was the right call, and the call-site comment records why.
- The pre-scan turns "stops part-way" into "nothing was deleted" for the pre-run's refusal classes, and reports every refusal at once. That is a real usability gain over 3186cff5's one-class pre-scan.
- Deleting the third FLA predicate rather than keeping two near-twins removes a drift hazard.
- The new pins target the specific mutants they name, and the comments say which parameterized codes they bind.

## Recommendation
APPROVE. No High or Medium. Address the five Lows in the same pass per house rule. L1 and L4 are comment-only, L5 is a one-line move, and L3's rename is mechanical. L2 is optional scope on this ticket.
