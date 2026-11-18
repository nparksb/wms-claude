head: 57c1253a

# SBDEV-3999: scoped third review of commit 57c1253a

- Worktree: `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3999`. The commit under review is `57c1253a`, whose parent is `334a8187`. It answers the five Lows in `review-code-2.md`.
- How I checked: `git show 57c1253a`, `git show origin/develop:<file>`, `grep`/`awk` over the worktree, and targeted reads. Mvn was not run (a suite is in flight in this worktree), so this report gives no compile or test verdict. I edited nothing.
- The reviewer authored none of this change.

## Verdict: COMMENT (0 High · 1 Medium · 3 Low)

All five second-review Lows are addressed. The new IT is a sound pin. The inventory count is right. The child-container pre-check, though, refuses a batch that develop and 334a8187 deleted successfully: a carrier selected together with its own children. The comment's list of what can still stop part-way is also incomplete.

## 1. Child-container pre-check (`UnitLoadController.java:177-182`)

```java
if (!unitloadRepository.findByCarrierunitloadId(unitLoad.getId()).isEmpty()) {
    refused.add("Container " + unitLoad.getLabelid() + " has child container! Please delete them first.");
    continue;
}
```

- **Message parity: yes, with the label added.** `UnitloadService.java:764` reads `"Container has child container! Please delete them first."`. The pre-scan text is the same sentence with the label inserted, which is better for a batch. It uses `getLabelid()` rather than `originalLabel(...)`. That is fine here: To-Delete containers already left at `:171-174`, so no `-X-<id>` label can reach this line.
- **Same predicate: yes.** Both call `findByCarrierunitloadId(id).isEmpty()`, the same repository method and the same question.
- **`continue`: correct.** It skips the pre-run for a refused carrier, so a carrier does not also report its subtree's FLA or goods-out. The cost is minor lost information. No test pins `continue`: dropping it leaves the new unit test green, because the pre-run mock does nothing. This is cosmetic.
- **Existing SBDEV-3500 tests: unaffected.** `unitloadRepository` is a plain `@Mock` (`UnitLoadControllerUnitTest:46`). Mockito's RETURNS_DEFAULTS returns an empty `List` for an unstubbed `List`-returning method, so `deletesAllContainersSuccessfully` and the other bulk tests see "no children" and follow their old path. The other test classes that call `bulkDeleteContainer` (`BatchEndpointPerIdLookupUnitTest:513`, `UnitLoadControllerAuditCommentUnitTest:57`) also use a plain `@Mock UnitloadRepository`, so the same holds for them.
- **New test** `refusesTheWholeBatchWhenAnyContainerHasChildren` (`:307-327`) kills the "pre-check removed" mutant. With the pre-check gone, the loop calls the mocked `deleteUnitLoad(plain)` and `never()` goes red. Both `lenient()` stubs are exercised, so `lenient()` is unnecessary again. That is cosmetic.

### [MEDIUM] A carrier batched together with its own children is now refused; develop and 334a8187 deleted it
File: `src/main/java/net/aim_ai/wms/controller/UnitLoadController.java:178`
Confidence: HIGH that the mechanism works this way (code read, not executed). MEDIUM on how often operators do this.

The pre-scan runs against the database **before any delete**. A child C that is itself in the batch therefore still points at P, and P is refused: "Nothing was deleted: Container P has child container!".

On `origin/develop`, the bulk loop was `preRun(ul); deleteUnitLoad(ul)` per id. A batch ordered `[C, P]` succeeded there:
1. `deleteUnitLoad(C)` → `sendToNirvana(C)` → `transferUnitLoadToLocation` clears the carrier link (`UnitloadBusinessService.java:330-335`: `unitload.setCarrierunitloadId(null); unitload = unitloadRepository.save(unitload);`).
2. `deleteUnitLoad(P)` then finds no children and deletes P.

334a8187 kept that behaviour, because the pre-run does not check children. 57c1253a turns a whole-success case into a whole refusal. The `[P, C]` order was already refused on develop, with nothing deleted, because P came first. The old behaviour depended on order, and the new behaviour refuses both orders.

Fix:
- Refuse only children that are **not in the batch**: `children.stream().anyMatch(c -> !batchIds.contains(c.getId()))`.
- Delete in-batch children before their carriers, for example by sorting the batch by carrier depth, deepest first.
- Pin both `[C, P]` and `[P, C]` with a unit test.

If that is out of scope, keep the refusal and say in the message that the children were selected too, and point the operator at "Delete Recursive". In that case also note the regression on the ticket.

## 2. Accuracy of the rewritten SBDEV-3500/3999 comment (`UnitLoadController.java:145-151`)

**How I enumerated the refusals:** `grep -n "throw "` over the delete path.
- `UnitloadService.deleteUnitLoad` (`:744-814`)
- `deleteUnitLoadRecursivePreRun` (`:551-593`) and `assertCarrierChainIsAcyclic` (`:521-549`)
- `assertNoGoodsOutStock` (`:719-734`)
- `StockunitBusinessService.sendStockUnitToNirvana` (`:575-600`)
- `UnitloadBusinessService.sendToNirvana` (`:615-645`), plus an `awk` over `transferUnitLoadToLocation` (`:221-345`)

**Blind spots:**
- `transferUnitLoadToLocation`'s FacadeExceptions (`STORAGELOCATION_LOCKED :253`, `CARRIER_NOT_ON_FIXLOC :263`, `WRONG_ITEMDATA_FIXASSIGNMENT :270`) and the type-permitted check (`:323`) are about the Nirwana *destination*. I did not trace whether `ignoreLock=true` or the Nirwana location's configuration makes them unreachable.
- I did not descend into `sharedService`, `itemdataService` or `messageService`.
- Runtime exceptions such as `EntityNotFoundException` are not caught by this handler at all.

| Claim | Verified |
|---|---|
| "checked up front: unknown ids" | ✔ `:165` `orElseThrow(EntityNotFoundException)`, before any delete |
| "To Delete" | ✔ `:166-174` |
| "child containers" | ✔ `:178` (but see the Medium above) |
| "every deleteUnitLoadRecursivePreRun refusal (FLA container, goods-out stock, carrier cycle)" | ✔ `:576`, `:580`, `:538` / `:546`. These are the pre-run's only `throw` sites. Its `EntityNotFoundException` at `:573` is unreachable in practice (second review §2) |
| "still able to stop part-way … a stock unit moved off concurrently" | ✔ `UnitloadService.java:782` |
| "… and a FacadeException from the retire itself" | ✔ but mislabelled, see L1 |
| implied: those two are the **only** remaining part-way stops | ✘ see L1 |

### [LOW] L1: the "still able to stop part-way" list is incomplete, and one item is knowable in advance
File: `UnitLoadController.java:149-151`
Confidence: HIGH

```java
// carrier cycle). Still able to stop a batch part-way, because they cannot be known in advance: a
// stock unit moved off the container concurrently ("was moved or removed"), and a FacadeException
// from the retire itself.
```

Three problems:
- **(a) A reservation is knowable in advance.** `StockunitBusinessService.java:576-578` throws `FacadeException("STOCKUNIT_HAS_RESERVATION", …)` whenever `reservedamount > 0`. That is a static property of the stock, readable before the first delete. The comment files it under "cannot be known in advance", which is wrong. A container holding stock reserved for a picking order is a plausible bulk-delete target.
- **(b) Concurrent changes the comment does not name.** These are race-only, but they stop the batch part-way the same way the named one does:
  - stock locked `PICKED_FOR_GOODSOUT` after the pre-scan (`UnitloadService.java:791` re-checks the locked rows);
  - a child added after the pre-scan (`:764`);
  - an FLA created after the pre-scan (the bin-departure guard, `UnitloadBusinessService.java:609`).
- **(c) The Nirwana unit load itself in the batch.** This is knowable and not pre-checked. Its `sendToNirvana` refuses at `UnitloadBusinessService.java:618` ("has stock!") or `:630` ("Can not delete <id>"). This is an edge case.

Fix: either reword the comment to "Still able to stop part-way: anything that changes between this scan and its delete (stock moved or newly goods-out, a child or FLA added), and deleteUnitLoad's retire refusals, notably STOCKUNIT_HAS_RESERVATION (FacadeException)", or add `reservedamount > 0` to the pre-scan. The second option is the one that matters to an operator. File it on this ticket if you take it.

## 3. IT `deletePreRun_shouldRefuseFlaContainer_onRealPg` (`FixLocationAssignmentServiceIT.java:521-543`)

- **Can the ids coincide? No.** `AbstractBaseEntity` (`:20-25`) gives **every** entity the single sequence `seqentities` with `allocationSize = 1`. `Location` and `Unitload` both extend it. The bin and the container therefore draw consecutive values from one sequence and cannot be equal. The `isNotEqualTo` assertion is belt-and-braces. It fails loudly rather than vacuously.
- **Does it tell the two columns apart?** Yes. The fixture is `fixLocationAssignment(itemId, bin.getId(), container.getId())`, and `PgLaneFixtures.java:222-226` sets location then unitload, so the argument order is correct.
  - Under a by-location mutant (`@Query` removed so that Spring derives `assignedlocation_id IN (:ids)`), the lookup is `assignedlocation_id = container.id`.
  - No location can have that id: it is a fresh value from the shared sequence. The class is `@Transactional` via `BasePostgresIntegrationTest:61`, so it rolls back and leaves nothing behind.
  - The query therefore returns empty, nothing throws, and the test goes red. The mutant is killed.
- **Is the message the real one?** Yes. `UnitloadService.java:576` builds `"Can not delete. Fix assignment exists for " + labels.joining(",")`, and the label is resolved by `findById` inside the same transaction. A single FLA means the message contains exactly `container.getLabelid()`.
- **The comment's wording.** "The bin and the container get different ids from the sequence" is accurate, and more precisely so than it reads: it is one shared sequence. No change needed.
- One small note (no severity): the `@DisplayName` names the misnamed method. That is useful, because a later rename will show up in the test's name.

## 4. NeverMatcher inventory `UnitLoadControllerUnitTest:4`

`grep -n "never()" UnitLoadControllerUnitTest.java` finds 5 `never()` lines. Four of them carry `anyBoolean()`: `:250`, `:273`, `:304`, `:326`, each `deleteUnitLoad(any(), any(), anyBoolean(), any())`. `:274` (`deleteUnitLoadRecursivePreRun(any(), any())`) has none.

On `origin/develop` the same grep counts 2, and the develop inventory reads `"UnitLoadControllerUnitTest:2"` (`:796`). The new entry, 4, matches. Its comment, "2 -> 4 … two more never() on the same deleteUnitLoad", is accurate. The third parameter is the primitive `boolean notifyCRM` (`UnitloadService.java:744`), so `anyBoolean()` is required.

✔ No finding.

## 5. Field placement in the IT

`@Autowired UnitloadBusinessService` and `@Autowired UnitloadService` now sit at `:72-73`, inside the field block next to the other repository injections. The stray mid-class field was removed at the old `:493`. ✔

### [LOW] L2: the field block now mixes two injection styles
File: `FixLocationAssignmentServiceIT.java:67-79`
Confidence: HIGH
Issue: the new fields use the one-line `@Autowired private X x;` style, followed directly by the pre-existing two-line `@Autowired\n private FixLocationAssignmentService …;`. This is purely cosmetic and pre-existing in shape.
Fix: optional. Leave it as is.

## 6. Disposition of the second-review Lows

| Second review | Status at 57c1253a |
|---|---|
| L1: stale SBDEV-3500 comment | **Addressed.** The new text is accurate for what is checked, and incomplete for what is not (L1 above) |
| L2: bulk delete not all-or-nothing for a carrier | **Addressed**, with the over-refusal side-effect (Medium above) |
| L3: misnamed query has no real-DB pin | **Addressed** by the IT (§3). The rename was declined because the method is an SDR-exported search (`@RestResource(path = "findDistinctByState")`). I accept that: renaming would change the generated `/search/` URL. The second misnomer (`path = "findDistinctByState"`) remains, as before |
| L4: NeverMatcher provenance | **Addressed** (§4) |
| L5: IT field placement | **Addressed** (§5) |

### [LOW] L3: no regression test for the order-sensitive carrier-plus-children batch
File: `UnitLoadControllerUnitTest.java` (bulk-delete nested class)
Confidence: HIGH
Issue: whichever way the Medium is resolved (allow it or refuse it deliberately), no test pins what `[child, carrier]` does. The new test's child (40) is outside the batch, so it cannot tell the two designs apart.
Fix: add a test with `ids = "40,39"`, where 40's carrier is 39, and assert the chosen behaviour.

## Positive observations
- The pre-check reuses the exact predicate and sentence of the refusal it pre-empts, so the two cannot disagree on what "has children" means.
- The IT is well built. It uses a single shared sequence, so the ids cannot collide, and it runs inside a rolled-back transaction, so no stray row can make the mutant pass. It is the real-PG pin the misnamed query needed.
- The commit message records why the rename was declined (SDR export), so the next reader will not redo that analysis.
- The inventory comment states the signature it relied on, as the other entries do.

## Recommendation
COMMENT. There is nothing blocking at High. Per the house rule, fix the Medium before the PR:
- Either let in-batch children through and order the delete loop children-first (preferred),
- or keep the refusal deliberately, with a message pointing at Delete Recursive, plus the L3 test.

L1 is a comment edit, optionally with a reservation pre-check. L2 is optional.
