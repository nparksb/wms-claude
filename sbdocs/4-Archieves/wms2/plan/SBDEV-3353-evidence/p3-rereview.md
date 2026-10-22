head: ee40d348

# SBDEV-3353: P3 scoped re-review #2 of the re-review fix commit

- **Scope:** `git diff 69de9e8e..ee40d348` only (15 files, +338/−60). The wording sweep (item 7) covers `5fa9bef0..ee40d348`.
- **Tree:** `.claude/worktrees/wms2-api/SBDEV-3353-review`, detached at `ee40d348`. It was clean before and after. The one mutant was copied from the scratchpad, restored from that copy under an EXIT trap, and `cmp` confirmed the restored file identical to the original.
- **Reviewer:** an independent lane (code-reviewer). It did not author `ee40d348` or `p2-fixes.md`.
- **Verdict: APPROVE (with Lows).** N1 is closed on every arm where the guard could have caused it. N2–N5 are closed. N6 is closed by the decision to leave it. There are 4 new findings, all LOW and all wording or pin-hygiene. Two of them repeat the "every copy was swept" miss that N2 and N5 were about.

## Instruments run

| What | Result |
|---|---|
| `pgrep -fl "surefire\|failsafe"` | The first check was **not empty**: the `SBDEV-3353-security` lane was running a full `mvn clean test`. My run was scripted to wait until pgrep was empty. It cleared at 17:14:06. |
| Baseline: `mvn -o -ntp test -Dtest=StockunitServiceParcelSourceRefusalUnitTest` at `ee40d348` | **43 / 0 / 0 / 0**. Matches p2-fixes (43, was 38). |
| **Mutant m1**: restore `SourceContainerGuard.assertStockNotInParcel(stockunitRepository.findById(stockUnit.getId()).orElse(stockUnit), …)` at `StockunitService:345-347` | **2 red, 0 error**: `transferStock_shouldNotLoadTheSourceEntitiesBeforeTheLockRead[1]` and `[2]` at `:794`, each with the named message *"SBDEV-3353 N1: transferStock must not load the source Stockunit ENTITY (findById) before …"*. This matches the claim exactly. |
| Not re-run | m2, m3, m4, PIT, the full suite (claimed 7111/0/0/1) and the two RTS ITs. |

## Per-finding table (p2-rereview N1–N6)

| Finding | Status | Evidence |
|---|---|---|
| **N1** (Medium): a managed entity before the lock read inside `@Transactional transferStock` | **CLOSED** | See the §N1 trace below. The guard now reads `findUnitloadIdsByIdIn` (a JPQL scalar) and then `findParcelGuardViewById` (a JPQL interface projection). Neither puts a `Stockunit` or a `Unitload` into the persistence context. On the two arms that previously touched no source row before the lock (existing non-pallet container, and flow bin), the source SU and the source UL are now both first-touched under `findByIdForUpdate` again. The fix also closes the unit-load half that nobody had flagged; it was present since `d7c77870`. It is graded by a non-vacuous test (m1 reproduced). |
| **N2** (Low): "backstop … fail-closed" | **CLOSED in `src/main`, but NOT fully closed in the branch** | `UnitloadService:716-722` is correct now. One SBDEV-3353 copy remains, which contradicts "0 hits remain in SBDEV-3353 text". See **P3-1**. |
| **N3** (Low): two p1-fixes claims | **CLOSED** | `p1-fixes.md` has a Corrections section with 6 rows. The mobile comment (`MobileTransferOrderService:392-395`) now gives the transaction reason. I verified that reason: `TransferOrderController` has 0 hits for `Transactional`. `MobileTransferOrderService` has exactly 1, and it is the new comment itself; at `69de9e8e` it had 0. |
| **N4** (Low): the `setLockDamaged` guard pre-empted lock messages | **CLOSED** | See §N4 below. Every statement between the switch and the guard only reads or throws. The new 3-case test asserts the fragment, a key other than `transferStockSourceIsParcel`, `never()` on the guard read, `never()` on the mint and `never()` on the move. The `never(findParcelGuardViewById)` is non-vacuous, because the guard does call that method when it is reached. |
| **N5** (Low): "writes nothing" | **CLOSED at the one site named, NOT swept** | `CancellationReversalService:276-283` is accurate now ("COMMITS nothing … rolled back with it"). The sibling copy in `StockunitService:330-331` still says "writes nothing". See **P3-2**. |
| **N6** (Low, optional): `lenient()` Tote stubs | **CLOSED (by decision)** | The Tote pin now has a strict `verify(unitloadRepository).findParcelGuardViewById(TOTE_UNITLOAD_ID)` and `verify(unitloadRepository, never()…).findById(any())`. So a pre-validate that stops reaching the guard turns it red, as claimed. |

## §N1: repository calls in order, from the method top to the first source lock read, per arm

The first source lock reads are both in `StockunitBusinessService.transferStockToUnitLoad`: SU `findByIdForUpdate` at `:201` and source UL `findByIdForUpdate` at `:237`. Before them it runs `lockOwningPickingorders` at `:196`, which reads `PickingorderPosition` and locks `Pickingorder`. It loads no Stockunit and no Unitload (`PickLineRealignmentService:145-156`). Between `:201` and `:237` it runs `unitloadTypeRepository.findById(dstUlTypeId)`, `findByUnitloadId(destination)` and itemdata reads. None of them manages the **source** UL, unless the destination is the source (see P3-4).

The common prologue (`StockunitService:345-347`) runs `stockunitRepository.findUnitloadIdsByIdIn(List.of(id))`, a JPQL `SELECT DISTINCT s.unitloadId` that returns `List<Long>`. It then runs `unitloadRepository.findParcelGuardViewById(ulId)`, and then `unitloadTypeRepository.findById(typeId)`, which manages a `UnitloadType`. Nothing locks `unitload_type`: `UnitloadTypeRepository` has no `ForUpdate`/`PESSIMISTIC`, and `git grep` finds no `LockModeType` use on it.

| Arm | Reads after the prologue, before `transferStockToUnitLoad` | Source SU managed before `:201`? | Source UL managed before `:237`? |
|---|---|---|---|
| Existing container, **pallet** (`:376-402`) | `findByLabelid(dest)`, `assertCanReceiveStock(dest)` (reads the dest location only, `DestinationEligibilityService:227`), `findByName(Pallet)`, **`unitloadRepository.findById(stockUnit.getUnitloadId())` at `:379`**, itemdata, type, `locationRepository.findById`, `createUnitload` (a write) | No (first touch) | **Yes, at `:379`. This predates SBDEV-3353.** p2-fixes says so. It is not an N1 regression. |
| Existing container, **non-pallet** (`:403-406`) | `findByLabelid(dest)`, eligibility, `findByName(Pallet)` | **No** | **No** (fixed by `ee40d348`) |
| New container, **flow bin** (`:424-451`) | `findByAssignedlocationId`, `itemdataService.getById`, then either `findByItemdataId` + `createFixedLocationAssignment` (a write) + `findById(newFla UL)`, or `findById(fla UL)`. Both of those are the **destination** UL. | **No** | **No** (fixed by `ee40d348`) |
| New container, non-flow-bin, **whole-UL** (`:539-569`) | `findById(source UL)` at `:454`, `findByUnitloadId(source UL)` at `:457` (a JPQL query; manages every SU on it, **including the source**), then SBDEV-3341's `findById(stockUnit.getId())` at `:562` | Yes (`:457`). The `:562` "fresh read" then hits the L1 cache and returns the `:457` instance with no SQL. It is still an in-transaction read, so it remains fresher than the controller snapshot. | Yes (`:454`) |
| New container, non-flow-bin, **split** (`:570-…`) | same `:454`/`:457` | Yes, predates SBDEV-3353 | Yes, predates SBDEV-3353 |

- **The whole-UL arm has no SU or UL lock read at all.** `transferUnitLoadToLocation` locks only the destination `Location` (`UnitloadBusinessService:245`), plus the Pickingorder tree at `:237`. So the SBDEV-3341 `findById` re-read predates this work (SBDEV-3341), and it cannot be a lock-upgrade trigger on this arm. **It does not matter for N1.**
- **The split arm** (and the rack arm the p2 reviewer named) had a lock-upgrade exposure on the source SU and UL before SBDEV-3353, through `:454`/`:457`. `ee40d348` neither adds nor removes it. The new code comment scopes its claim correctly to "the existing-container and flow-bin arms, which otherwise touch the row first under the lock".

**Projection semantics.** `findParcelGuardViewById` is `@Query("SELECT u.id AS id, u.labelid AS labelid, u.typeId AS typeId FROM Unitload u WHERE u.id = :id")` returning `Optional<UnitloadParcelGuardView>`, an interface with `getId`/`getLabelid`/`getTypeId`.
- Spring Data JPA treats an interface return type on a JPQL query with a scalar select list as a closed interface projection. It runs the query as a `Tuple` query and wraps each tuple in a proxy backed by a map from alias to value.
- Hibernate materialises only the three selected attribute values. It does not instantiate a `Unitload`, and nothing enters the persistence context. Selecting attribute paths is not selecting the entity alias.
- The aliases match the getter property names (`labelid`, `typeId`), and the entity fields are `labelid` and `typeId` (`@Column(name="type_id")`, `Unitload.java:14,18-19`).
- The only real-database evidence is the RTS IT refusal, claimed at 2/2 and not re-run by me. A refusal there requires `typeId` to resolve through this query on Postgres.

**AUTO flush.** Both new reads are HQL/JPQL. Under `FlushMode.AUTO`, Hibernate flushes before an HQL query only when a dirty managed entity maps to a table in the query's spaces: `stockunit` for the first read, `unitload` for the second. Here is what is in the persistence context at each call:
- **Web `transferStock`, `/bulkTransferStock`, mobile, `setLockDamaged`:** a fresh transaction or the repository's own read transaction, so the persistence context is empty. No flush is possible.
- **RTS pre-validate (`CancellationReversalService:288`):** the possibly-dirty entity is the `CustomerorderCancellationLog` from the SBDEV-3316 recovery `setPicktostockunitId` + `save`. It is in a different table, so no auto flush is triggered. Even if one were, it would be the same write in the same transaction, and `rollbackFor` undoes it on the refusal.
- **RTS second layer (`transferStock` from `:378`):** the source SU is dirty only when `clearNeeded`, and then `:369` has already run `entityManager.flush()`.

So nothing is written earlier than before in a way that matters. **No finding.** One nuance: the old entity `findById` (`em.find`) never auto-flushed, and the new JPQL reads can. That is the only behavioural difference, and it is benign on every current caller.

**The fallback "empty ⇒ snapshot's id".** `findUnitloadIdsByIdIn` filters `s.unitloadId IS NOT NULL`, so the result is empty only when (a) the row has been deleted, or (b) the row's `unitload_id` is null.
- **(b) cannot happen in practice.** The column is NOT NULL, as the guard test javadoc says: "NOT NULL columns, 0 orphans".
- **For (a),** the guard judges the snapshot's last known container. If that container was a Package it refuses, which is harmless because the row is gone anyway. Otherwise it proceeds, and every draining arm then throws `"Source stock unit … not found"` at `findByIdForUpdate` (`StockunitBusinessService:201-202`).
- This behaves exactly like the old `.orElse(stockUnit)`. It is **fail-open only toward a row that no longer exists**, which cannot drain a parcel. **No finding.** One pre-existing edge: `List.of(null)` would NPE on a null id where the old `findById(null)` threw `InvalidDataAccessApiUsageException`. Every caller passes a persisted id, so this is not reachable.

## §2: "the guard never loads a unit load entity", at each of the 6 call sites

| Call site | Entry | What the guard reads | Holds? |
|---|---|---|---|
| `StockunitService:347` (`transferStock`, tx) | `assertUnitloadNotParcel(scalarId, …)` | projection + type row | Yes |
| `StockunitService:811` (`setLockDamaged`, no tx) | `assertStockNotInParcel(findById re-read)` | projection + type row. The SU entity re-read is detached as the repository returns. | Yes |
| `MobileTransferOrderService:396` (no tx) | `assertStockNotInParcel(findById re-read)` | projection + type row | Yes |
| `CancellationReversalService:288` (tx) | `assertStockNotInParcel(managed SU from :255)` | projection + type row | Yes |
| `MobileMoveUnitloadService:636` | `assertNotParcel(sourceUnitLoad)` | type row only. The **caller** already holds the entity. | Yes for the guard. The caller's own entity read predates SBDEV-3353. |
| `MobilePutAwayService:552` (tx) | `assertNotParcel(unitLoad)` | type row only. The caller read the UL in-transaction at `:512-518`, before `transferStockToUnitLoad(…, true)` locks it. | Yes for the guard. The caller's managed UL is an exposure that predates SBDEV-3353. |

The claim is true as a property of the guard. I also verified the "not transactional" premise for `setLockDamaged`'s third caller: `ReturnAdviceAutoReceiveService.execute` is not `@Transactional` (`:672`, `:678`), `applyDamage` is private (`:979`), and `AdviceRestController.create` is non-tx (`:760` comment).

## §N4: statements between the lock switch and the guard (`StockunitService:767-811`)

1. `switch (stockUnit.getEntityLock())`: `break` or `throw`.
2. Two `// TODO` comments.
3. `if (ZERO.compareTo(stockUnit.getAmount()) >= 0) throw …`: a read.
4. `if (stockUnit.getAmount().compareTo(amount) < 0) { LOG.debug; amount = stockUnit.getAmount(); }`: this reassigns a **local parameter**. It is not an entity setter, so nothing is written.
5. `if (stockUnit.getAvailableamount().compareTo(amount) < 0) throw …`: `getAvailableamount()` is `amount.subtract(reservedamount)` (`Stockunit:54-57`), a pure getter.
6. The guard at `:810-812` (comment end, call).

There is no write, no repository call and no service call. The first write is still `mintUnitloadLabel()` at `:821`. **Confirmed.**

## §4: RTS

- **The stock unit.** `stockunitRepository.findById` at `CancellationReversalService:255` has managed it since SBDEV-3326. `transferStockToUnitLoad:201` then takes its lock as an upgrade on **every** RTS arm. This predates SBDEV-3353 and is out of scope. The new comment states it accurately.
- **The pick-to unit load (the tote).** Whether it gets locked later in the same transaction depends on the arm `transferStock(…, false, pickfromlocationname, …)` takes:
  - **Flow-bin destination:** `transferStockToUnitLoad:237` locks it, and no other read in the path manages it. The old guard's entity `findById` would have made that a lock upgrade, so the scalar read **is what removes it**.
  - **Non-flow-bin, split:** `:454` manages it regardless, so the upgrade exposure predates SBDEV-3353 there.
  - **Non-flow-bin, whole-UL:** it is never locked.
- **Is the scalar read enough?** For the guard's decision, yes. It reads `type_id` in-transaction, which is as fresh as the entity read was. The second layer in `transferStock` then re-reads the id and the type again.

## §5: `transferStock_shouldNotLoadTheSourceEntitiesBeforeTheLockRead`

- **Real, not vacuous.**
  - `stockunitRepository.findById(STOCK_UNIT_ID)` and `unitloadRepository.findById(SOURCE_UL_ID)` are both stubbed (`lenient`, `:254`, `:267`), and the pre-fix code reached both. So the `never()`s are satisfiable in both directions.
  - Mutant m1 (above) reproduced **2 red** with the named message.
  - The `inOrder` verifies three calls that do happen (`findUnitloadIdsByIdIn` → `findParcelGuardViewById` → `transferStockToUnitLoad`). So deleting the guard also turns it red, not only a reorder.
- **Scope limit (LOW, P3-3).**
  - The test proves only that `findById` is absent. An entity read through another finder (`findAllById`, `findByIdIn`, or an entity-returning `@Query`) would pass it.
  - The mocked `stockunitBusinessService` means "before the lock read" really means "before the call".
  - Both limits are acceptable for a unit pin, but the test name claims more than it can see.

## §6: spot-checks of p2-fixes.md claims (8 checked)

| Claim | Result |
|---|---|
| "method-level `@Transactional` at `:320`, `:679` and `:889`" | **Stale by one hunk.** At `ee40d348` they are `:320`, `:679`, **`:904`**. The claim was measured before this commit moved the guard block (+15 lines). It has no effect; recorded in P3-4. |
| "`StockUnitController` has 0 occurrences of `Transactional`" | True (0). |
| "0 occurrences in `MobileTransferOrderService`, `TransferOrderController`, `AdminController`" | True at `69de9e8e`. At `ee40d348` `MobileTransferOrderService` has 1, and it is the new comment. |
| PIT line refs `SourceContainerGuard` `:81`, `:108`, `:123`, `:128`, `:141` | All five match the calls or conditionals named. |
| "`UnitloadService:777` belongs to SBDEV-3340" | True. `:775-779` is `restsInStorageLocation`'s null-name note, where "fail-closed" is correct for that predicate. |
| "three fixtures … now stub `findParcelGuardViewById` in place of the entity `findById`" | True: ToteContainerRelocation (strict `when`), TransferStockDestination (strict), StockunitServiceUnitTest (strict `when(…(2L))`). |
| RTS Tote pin "gained `verify(unitloadRepository, never()).findById(any())`" and "asserts `findParcelGuardViewById(TOTE_UNITLOAD_ID)` is called" | True, both present in the diff. |
| "7111 = 7102 + 9 (4 guard, 2 N1, 3 N4)" | Consistent with the diff. `SourceContainerGuardUnitTest` has +4 `@Test`. ParcelSourceRefusal went from 38 to 43 (measured 43), which is +5 = 2 parameterized N1 cases + 3 N4 cases. |
| "`git grep -n "fail-closed\|fail closed"` … **0 hits remain in SBDEV-3353 text**" | **False.** See P3-1. |

## §8: is the new UnitloadRepository method a new REST surface?

**No.** `findParcelGuardViewById` carries method-level `@RestResource(exported = false)` (`UnitloadRepository:43`). That is the same withdrawal form as the other internal finders on this repository: `findByIdForUpdate` (`:37-38`), `findIdsByCarrierunitloadIdOrderById`, `findByLabelidForUpdate`, and the `exported = false` searches `findDetailsByCarrierunitloadId` and `findByLabelidIgnoreCase`.

**SDR tests.** `SDR_WRITE_WITHDRAWN` (`RestConfiguration:441`) lists domain types for write verbs, not search methods, so it does not need to know about this. The SDR inventory rails (`SdrSurfaceInventoryContextTest`, `SdrLockingSearchNotExportedContextTest`, `SdrNonEntityCollectionSearchNotExportedContextTest`) derive the surface from `ResourceMappings` at runtime and pin only floors (`isGreaterThan(20/50/100)`). A non-exported method never enters them. No test enumerates `UnitloadRepository` query methods by name. **No change is needed.**

Residual (folded into P3-3): nothing would notice if `exported = false` were dropped. `SdrNonEntityCollectionSearchNotExportedContextTest` explicitly excludes `Optional` returns (javadoc `:92-96`: "if one is ever added, this rail will not see it"). The method would then publish `/v3/unitload/search/findParcelGuardViewById`. That route only reads (id, label, type id) and takes no lock, so the exposure would be minimal.

## New findings

### [LOW] P3-1: one "Fail-closed" copy survives in SBDEV-3353 text, which contradicts p2-fixes' "0 hits remain"
- **File:** `src/test/java/net/aim_ai/wms/unit/service/StockunitServiceParcelSourceRefusalUnitTest.java:90` (the class javadoc):
  > `{@value #PARCEL_KEY}. Fail-closed: an unresolvable unit load or type is NOT a parcel, so it proceeds.`
- **Confidence:** HIGH.
- **Issue:** This is exactly the naming N2 asked to remove. The same class's section header and `@DisplayName`s were renamed, but the javadoc was not. The p2-fixes N2 row asserts that the sweep found 0 remaining hits. Most likely the grep was case-sensitive (`fail-closed`) and this copy is capitalised (`Fail-closed`).
- **Fix:** Change it to "Fail-open (proceed-unguarded): …". Re-run the sweep with `git grep -in`, and correct the p2-fixes N2 claim.

### [LOW] P3-2: the N5 wording survives in three sibling copies; one is in `src/main`
- **Files:**
  - `StockunitService.java:330-331` (`transferStock`'s guard comment): `"RTS also checks in its own pre-validate, before its lock-100 clear, so a refused reversal writes nothing; this call is the second layer…"`.
  - `CancellationReversalParcelSourceIntegrationTest.java:61-62`: `"…BEFORE it clears PICKED_FOR_GOODSOUT (100) — so the refused reversal writes nothing."`
  - `CancellationReversalServiceUnitTest.java:1037-1038`: `"…so a refused reversal writes nothing: no save, no flush, no move."`
- **Confidence:** HIGH for the `src/main` and IT copies. For the unit-test copy it is MEDIUM: in that single-position fixture no recovery save runs, so it is true of that test, though it is phrased as a general property.
- **Issue:** N5's correction ("COMMITS nothing; the SBDEV-3316 recovery save is rolled back") was applied at the one site named. The two general statements above still say what N5 said was false. (Memory: *fixing a false claim tends to produce a new one: sibling copies*.)
- **Fix:** Reword all three to "commits nothing". In the unit test, "this fixture's refusal writes nothing: no save, no flush, no move" is accurate as it stands.

### [LOW] P3-3: the new pins are name-scoped. They see `findById` only, and nothing pins `exported = false` on the new finder
- **Files:**
  - `StockunitServiceParcelSourceRefusalUnitTest.java:788-798`: `verify(stockunitRepository, never()…).findById(STOCK_UNIT_ID)` and `verify(unitloadRepository, never()…).findById(SOURCE_UL_ID)`.
  - `SourceContainerGuardUnitTest` (`assertStockNotInParcel_shouldNotLoadTheUnitloadEntity`): `never().findById(any())`.
  - `UnitloadRepository.java:43`: `@RestResource(exported = false)`.
- **Confidence:** MEDIUM. This is a coverage-shape observation, not a live defect.
- **Issue:**
  - Suppose a future edit re-introduces an entity read through `findAllById`, `findByIdIn`, `getReferenceById` (a proxy that initialises on access), or an entity-returning `@Query`. That brings back N1 and every pin stays green.
  - The SDR rails exclude `Optional` returns, so dropping `exported = false` would publish an unrequested search route and no test would notice.
- **Fix:** Optional.
  - Add a comment on the pins naming what they cannot see.
  - Or use `verifyNoMoreInteractions(stockunitRepository)` after the expected scalar calls in the N1 test. It is cheap in a mock-only test, but brittle.
  - For the route, a one-line reflection assertion that `findParcelGuardViewById` carries `@RestResource(exported=false)` would do.

### [LOW] P3-4: wording and line-number drift in the new comments and claims
- **Confidence:** HIGH that these are inaccurate; LOW impact.
- **Issues:**
  - `SourceContainerGuardUnitTest.java:40-41` (edited in `ee40d348`): *"Those branches are measured **unreachable** on 6/6 tenants (NOT NULL columns, 0 orphans)"*. A measurement of 0 rows means **absent**, not unreachable. The WARN exists precisely because they are reachable in principle, for example a stock unit whose row is deleted between the controller read and the guard: that makes `findUnitloadIdsByIdIn` empty, or `findParcelGuardViewById` empty for a deleted unit load. It is the same completeness-word pattern as M1 and L9. **Fix:** "measured absent on 6/6 tenants".
  - p2-fixes' "method-level `@Transactional` at `:320`, `:679` and `:889`": the third is `:904` at `ee40d348`.
  - The `SourceContainerGuard` class javadoc paragraph "What it reads. The unitloadId of the stock unit it is handed…" describes only the stock-unit entries. `assertNotParcel(Unitload, …)` is handed an entity by its caller (the mobile putaway and move-UL sites), and those callers' own managed Unitload is a pre-existing lock-upgrade exposure (putaway: `:512-518` then `transferStockToUnitLoad(…, true)`). The guard claim is correct. A reader could take "the guard never manages a Unitload" as covering those two flows as well. **Fix:** add a clause: "for the two `assertNotParcel` callers the unit load is the caller's own, already-loaded entity".
  - A pre-existing edge, not introduced here: on the existing-container arm, if the operator scans the source's own container as the destination, `findByLabelid(dest)` (`:367`) manages the **source** UL before `:237`. That is a pre-SBDEV-3353 lock-upgrade path through a different read. No action is needed for this ticket.

## Open questions (low confidence, not blocking)
- None at HIGH or CRITICAL. The pre-existing lock-upgrade exposures (pallet arm source UL at `:379`; split arm at `:454`/`:457`; RTS source SU at `:255`; putaway's UL) are outside this ticket. If they matter, they belong with the SBDEV-3244 first-touch programme, not with SBDEV-3353.

## Positive observations
- The fix went beyond the finding. It found and closed the **unit-load** half of N1, which had been there since `d7c77870` and which both P1 reviews and the P2 re-review had missed. It also recorded that miss honestly in the p1-fixes Corrections table.
- The fix is placed in the guard, not in one call site. So "no managed Unitload from the guard" holds for all four stock-unit entries without per-caller discipline.
- It reuses the existing SBDEV-3244 scalar (`findUnitloadIdsByIdIn`) instead of adding a second one. The new projection is withdrawn from SDR in the same form as its siblings.
- It rejected `entityManager.detach` for the right reason: detaching would break RTS, which holds the same instance managed.
- m1 reproduced exactly, with the named message. The `inOrder` is non-vacuous in both directions.
- N4 is covered by three cases, one per lock message, and each asserts both "which message" and "nothing written".

## Recommendation
**APPROVE.** No CRITICAL or HIGH finding. N1 is closed. P3-1 and P3-2 are wording fixes of a few lines each. Fold them into the pre-PR commit together with the P3-4 "unreachable" fix, and correct the p2-fixes N2 claim. P3-3 is optional.
