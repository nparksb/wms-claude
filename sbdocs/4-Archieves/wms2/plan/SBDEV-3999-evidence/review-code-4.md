head: 9b4a24d7

# SBDEV-3999: scoped fourth review of commit 9b4a24d7

- Worktree: `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3999`. The commit under review is `9b4a24d7` (parent `57c1253a`). It answers `review-code-3.md` (1 Medium, 3 Low).
- How I checked: `git show 9b4a24d7`, `git diff 334a8187 9b4a24d7 -- src/main`, `git show 9b4a24d7:<file>` and `git show origin/develop:<file>` dumped to scratch, then grep and targeted reads. The working tree was not touched (`git status --short` empty). Mvn was not run (a suite is in flight), so this report gives no compile or test verdict. Nothing in this report was executed. The behaviour claims come from reading the code.
- The reviewer authored none of this change.

## Verdict: APPROVE (0 High · 0 Medium · 3 Low)

The commit removes the child pre-check and its test, and rewrites the comment. It restores 334a8187's controller logic exactly, which is develop's batch semantics plus the up-front pre-run. The rewritten comment is accurate on every checked claim. The Lows are about comment precision and an optional regression pin. None of them blocks.

## 1. Logic parity with 334a8187

`git diff 334a8187 9b4a24d7 -- src/main` touches one file, `UnitLoadController.java`. I filtered the diff with `grep '^[+-]' | grep -v '^[+-]\s*//'`, which keeps changed lines that are not comments. **The filter returns nothing: every changed line in src/main is a `//` comment.**
- The two hunks are the long SBDEV-3500/3999 comment at `:145-153` and the one-line comment `// SBDEV-3999: the pre-run only reads. Every refusal is collected, …` at `:177`.
- The code at 9b4a24d7 is the same as at 334a8187:
  - load and de-dup;
  - the To-Delete refusal;
  - the pre-run loop collecting `refused`;
  - `"Nothing was deleted: "` + join;
  - the delete loop.
- The removed block was 57c1253a's `findByCarrierunitloadId` pre-check. It is gone entirely, including its `continue`.

The src/test side, compared with 334a8187, now differs only by 57c1253a's FLA IT (+28 lines) and the inventory edit. The child-container unit test was deleted with the check, which is correct: kept, it would assert the removed behaviour and go red.

## 2. Accuracy of the rewritten comment (`UnitLoadController.java:145-153`)

**How I enumerated the refusals:** `grep -n "throw "` over the delete path at 9b4a24d7, then I read every hit.
- `UnitloadService`:
  - `assertCarrierChainIsAcyclic` `:521-549`;
  - `deleteUnitLoadRecursivePreRun` `:551-593`;
  - `assertNoGoodsOutStock` `:719-734`;
  - `deleteUnitLoad` `:744-814`.
- `UnitloadBusinessService`:
  - `transferUnitLoadToLocation` `:221-345`;
  - `refuseFixedAssignmentBinDeparture` `:596-612`;
  - `sendToNirvana` `:615-645`.
- `StockunitBusinessService` `STOCKUNIT_HAS_RESERVATION` `:578`, `:626`.

**Blind spots:**
- I did not descend into `processTransfer` (`UnitloadBusinessService:512+`), `unitloadRecordService`, `sharedService`, `itemdataService` or `messageService`.
- I did not trace whether `transferUnitLoadToLocation`'s destination checks (`:253`, `:263`, `:270`, `:323`) are reachable for the Nirwana destination with `ignoreLock=true`.
- Runtime exceptions (`EntityNotFoundException`, optimistic-lock failures at commit) are not caught by this handler, and the comment does not try to cover them.

| Claim | Verified |
|---|---|
| "Checked up front: unknown ids" | ✔ `:167` `orElseThrow(EntityNotFoundException)`, inside the load loop, before any delete |
| "To Delete" | ✔ `:168-176` |
| "every deleteUnitLoadRecursivePreRun refusal (a fix assignment's container, goods-out stock, a carrier cycle)" | ✔ The pre-run's only `throw` sites are `:538`/`:546` (cycle), `:576` (FLA) and `:580` → `assertNoGoodsOutStock` (goods-out). The `EntityNotFoundException` at `:573` is a label lookup on an FLA that exists, so it is unreachable in practice |
| "NOT checked up front … deleteUnitLoad's own refusals (a container that still has children, a stock unit moved or removed concurrently)" | ✔ `UnitloadService:762-765` `"Container has child container! Please delete them first."`; `:782-786` `"Stock unit … was moved or removed …"`. Not exhaustive, see L2 |
| "anything the retire itself throws (a reserved stock unit, a FacadeException)" | ✔ `StockunitBusinessService:578` `throw new FacadeException("STOCKUNIT_HAS_RESERVATION", …)`. "Anything the retire throws" also covers the bin-departure guard (`UnitloadBusinessService:610`) and `sendToNirvana`'s `:619`/`:623`/`:630` |
| "a carrier selected together with its own children deletes when the children come first in the batch" | ✔ by reading, with an edge case (L1). Mechanism below |
| "each child's delete clears its carrier link" | ✔ on the normal path. ✘ on `sendToNirvana`'s early return (L1) |
| (implied) the pre-run itself does not refuse a carrier whose children are in the batch | ✔ No throw in `deleteUnitLoadRecursivePreRun` asks "has children". It walks the children (`:558-564`) to collect the subtree for the FLA and goods-out checks. It refuses a carrier only if something in the subtree has an FLA, goods-out stock or a cycle, and the child's own pre-run would refuse that anyway |
| "a pre-check would refuse that batch" | ✔ That is exactly 57c1253a's behaviour (review-code-3 Medium) |

**The carrier-link mechanism, traced for a batch `[C, P]` where C is carried by P.** Both pre-runs pass, then:
1. `deleteUnitLoad(C)` (its own `@Transactional`, `:743`, reached through the service proxy from the controller):
   - The child check on C (`:762`) is empty.
   - Its stock is retired.
   - `unitloadBusinessService.sendToNirvana(C)` (`:802`) → `transferUnitLoadToLocation(C, nirvana, true, …)` (`UnitloadBusinessService:640`) → `if (carrierunitloadId != null) { … unitload.setCarrierunitloadId(null); unitload = unitloadRepository.save(unitload); }` (`:330-335`). The transaction commits.
2. `deleteUnitLoad(P)` runs `unitloadRepository.findByCarrierunitloadId(P.id)` (`:762`), a fresh query after C's commit. It returns empty, so P proceeds.
   - P's entity in `batch` was loaded before C's delete (`spring.jpa.open-in-view=false`, so it is detached).
   - C's `processTransfer(C, parentUnitload=P', …)` reads P but does not `save` it. In processTransfer's body, the only `save` is on the moving unit load. P's version is therefore not bumped, and the stale P in `batch` does not cause an optimistic-lock failure.
   - This stale-entity shape is identical on `origin/develop`, which also loads the whole batch up front, so there is no new exposure.
3. Corroboration: production's `deleteUnitLoadRecursive` (`UnitloadService:611-631`) uses the same mechanism. It calls `deleteUnitLoad(child)` for each child and then `deleteUnitLoad(parent)` (`:631`). It runs in one transaction rather than two, but the clearing call is the same.

## 3. Disposition of the third review

| Third review | Status at 9b4a24d7 |
|---|---|
| **Medium**: a carrier batched with its own children was refused | **Resolved**, by a third option the review did not list: remove the pre-check. The two listed options were to let in-batch children through and order the loop children-first, or to keep the refusal deliberately. Removing it restores develop's behaviour: `[C, P]` deletes, and `[P, C]` stops at P (nothing deleted if P is first, part-way otherwise). The order-sensitivity is pre-existing on develop, and the comment states it ("when the children come first"). Acceptable: no regression versus develop, and nothing new is refused |
| **L1**: the "still able to stop part-way" list was incomplete and mislabelled reservations as unknowable | **Resolved** by rewording, which was option 1 of the review's fix. The "cannot be known in advance" framing is gone, and reservations are now named under "NOT checked up front". The optional reservation pre-check was not added. Neither the comment nor the commit message says so, but the fix offered rewording as a full alternative, so this is answered. Small precision residue in L2 |
| **L2**: mixed injection style in the IT field block | Untouched. The review itself said "Optional. Leave it as is." Answered |
| **L3**: no test pins `[child, carrier]` | **Not explicitly answered** in the commit message. The test that would have pinned the refusal design was deleted along with that design. See L3 below |

**Can a controller unit test with a mocked `UnitloadService` cover `[C, P]` meaningfully?**
- **Partly.** It cannot observe the carrier-link clearing: that lives in `UnitloadBusinessService.transferUnitLoadToLocation`, behind the mocked `deleteUnitLoad`. A green mock test would therefore say nothing about whether `[C, P]` actually deletes.
- What it can pin is the controller's own decision: given `findByCarrierunitloadId(39L)` stubbed to return `[UL-040]` and `ids = "40,39"`, the controller adds no refusal and calls `deleteUnitLoad` for 40 then 39 (`InOrder`). That kills the specific mutant "someone re-adds a controller-level child pre-check", which is the exact flip-flop of 57c1253a → 9b4a24d7.
- The end-to-end claim needs a real-PG IT: seed C carried by P, call `bulkDeleteContainer` with `"C,P"`, and assert both are `GOING_TO_DELETE`. `DeleteContainerWithStockIT` already has a `childUnitload(...)` seeder (`:137`).
- **Is the absence acceptable? Yes.** The behaviour is develop's, unchanged, and production's recursive delete exercises the same mechanism daily. The pin is an optional guard against oscillation, not a gap in correctness.

## 4. NeverMatcher inventory `UnitLoadControllerUnitTest:3`

The method was `grep -n "never()"` over `git show 9b4a24d7:…/UnitLoadControllerUnitTest.java`, with the lines checked for `anyBoolean`.
- There are 4 `never()` lines: `:250`, `:273`, `:274` and `:304`.
- **3 of them** carry `anyBoolean()`: `:250`, `:273` and `:304`, each `verify(unitloadService, never()).deleteUnitLoad(any(), any(), anyBoolean(), any());`.
- `:274` (`deleteUnitLoadRecursivePreRun(any(), any())`) has none.
- No `never()` statement spans lines: every `anyBoolean` hit in the file is a single-line statement.

The entry `"UnitLoadControllerUnitTest:3"` (`NeverMatcherNullBlindnessArchTest:799`) matches. The comment, "2 -> 3. One more never() … (bulk delete refuses a batch holding a fix assignment's container before any delete)", is accurate: the third site is `:304` in the FLA-refusal test.
- ✔ No finding.

## Issues

### [LOW] L1: "each child's delete clears its carrier link" does not hold on sendToNirvana's early return
File: `src/main/java/net/aim_ai/wms/controller/UnitLoadController.java:152-153`
Confidence: MEDIUM (I did not establish whether the state is reachable)

```java
// pre-checked: a carrier selected together with its own children deletes when the children come first
// in the batch (each child's delete clears its carrier link), and a pre-check would refuse that batch.
```

`UnitloadBusinessService.sendToNirvana:633-636`:

```java
if (nirvanaLocation.getId().equals(unitload.getStoragelocationId())) {
    LOG.warn("unitLoad={} already on {}", unitload.getId(), nirvanaLocation);
    return;
}
```

This return comes before `transferUnitLoadToLocation`, the only place the link is cleared. A child that sits on the Nirwana location but is not To Delete keeps `carrierunitload_id = P`. Such a child passes the controller's To-Delete check, and its delete is the silent no-op that SBDEV-3500 described. P's delete then refuses part-way with "has child container".
- This is an edge case, and arguably a data anomaly: a carried child would normally share its carrier's location.
- Fix: optional. Either qualify the parenthetical ("each child's delete moves it to Nirwana and clears its carrier link, unless it already sits there"), or leave it as is.

### [LOW] L2: the "NOT checked up front" parentheticals are examples, not the full list, and one item is a subset of the other
File: `src/main/java/net/aim_ai/wms/controller/UnitLoadController.java:149-151`
Confidence: HIGH

```java
// cycle). NOT checked up front, so still able to stop a batch part-way: deleteUnitLoad's own refusals
// (a container that still has children, a stock unit moved or removed concurrently) and anything the
// retire itself throws (a reserved stock unit, a FacadeException).
```

- `deleteUnitLoad`'s own refusals also include goods-out stock locked after the pre-scan, re-checked at `UnitloadService:791`. The category ("deleteUnitLoad's own refusals") covers it, but the parenthetical reads as complete.
- "a reserved stock unit, a FacadeException": the reservation refusal *is* a FacadeException (`StockunitBusinessService:578`). The pair reads as two disjoint cases. "Anything the retire throws" also covers BusinessExceptions: the bin-departure guard at `UnitloadBusinessService:610`, and `sendToNirvana`'s `:619`/`:623`/`:630`, for example the Nirwana unit load itself being in the batch.
- Fix: optional wording, for example "(e.g. children, stock moved or newly goods-out concurrently) and anything the retire throws (e.g. STOCKUNIT_HAS_RESERVATION)". It is accurate as it stands.

### [LOW] L3: no pin against re-adding the controller-level child pre-check
File: `src/test/java/net/aim_ai/wms/unit/controller/UnitLoadControllerUnitTest.java` (bulk-delete nested class, around `:280-305`)
Confidence: HIGH

- The design has now flipped twice: 334a8187 had no pre-check, 57c1253a added one, and 9b4a24d7 removes it. No test notices if it comes back.
- With the pre-check reinstated, every existing bulk test stays green. `findByCarrierunitloadId` is unstubbed, so RETURNS_DEFAULTS gives an empty list, and no test stubs a child.
- Fix: optional.
  - Add a unit test: `ids = "40,39"`, `when(unitloadRepository.findByCarrierunitloadId(39L)).thenReturn(List.of(buildUnitload(40L, "UL-040")))`, assert the success body, and use `InOrder` to verify `deleteUnitLoad` on 40 then 39.
  - Mutation check: re-add the removed block and confirm it goes red.
  - It does not prove the real carrier-link clearing (§3). That needs a real-PG IT if wanted.

## Positive observations
- The fix takes the least invasive resolution available: back to develop's semantics, with no reordering logic added to a bulk endpoint.
- The comment now explains *why* children are not pre-checked, which is the information that prevents the 57c1253a mistake recurring. In effect it is the commit's own regression note.
- The test, the inventory count and its rationale were reverted together and consistently: 4 → 3, with the remaining site named correctly.
- The commit message maps each change to the review finding it answers.

## Recommendation
**APPROVE.** Nothing at High or Medium. The controller logic equals 334a8187's (comment-only diff, mechanically filtered). Every claim in the comment checks out against the code, apart from the L1 edge case. L1 and L2 are optional comment refinements. L3 is an optional anti-oscillation unit pin. Per the house rule ("address Low findings too"), L3 is the one worth doing: it is about 15 lines and mutation-checkable.
