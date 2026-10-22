---
ticket: SBDEV-3755
lane: code-review (independent)
reviewed: 05e8c27c on origin/develop a4fd6490
worktree: .claude/worktrees/wms2-api/SBDEV-3755
date: 2026-10-13
verdict: COMMENT (approve-able; no High at high confidence)
---

# SBDEV-3755 — independent code review (lane: code)

Method: `git show 05e8c27c`, targeted reads of every touched file and the three callers, `git grep` sweeps.
**No build, no mvn, no LSP run** — a `mvn clean verify` was running in the worktree, and jdtls would contend with
it (concurrent Maven/jdtls = false reds). Compile-sanity was checked by reading imports only
(`ReplenishorderHolderView` imported; `ReplenishmentOrderMessages` is same-package for `ReplenishorderService`
and already imported in `MobileMoveUnitloadService:5`; `Optional` still used in `ReplenishorderService`).

## Verdict

**COMMENT** — 0 High, 3 Medium (one pre-existing), 9 Low (12 findings). The two fixes do what the ticket says, the selection
rule is correct for all three callers, and the persistence-context footprint is unchanged for every shape that
did not already 500. The Mediums concern the claim scope (the location/carrier arm still 500s on a multi-holder
stock unit) and a cheap tightening that would stop the new code loading N managed entities when it needs one.

---

## Stage 1 — spec compliance

| Item | Status |
|---|---|
| Fix 2: `existsForStockUnit` no longer throws on 2+ open holders | Done (`ReplenishorderService.java:425-443`) |
| Fix 2: returns first blocking (state >= STARTED) holder in id order, else lowest id | Done; ordering comes from the existing `ORDER BY r.id` in `findHoldersByStateLessThanAndStockunitIdOrderById` (`ReplenishorderRepository.java:230-235`) |
| Fix 3: first-scan banner sees STARTED replens on child unit loads, recursively | Done (`MobileMoveUnitloadService.java:192-195`, `:253-267`) |
| Tests for both | Present; see Stage 2 §4 for gaps |

## Stage 2 — answers to the six questions

### Q1. Behaviour per caller — is "blocking first, else lowest id" right?

| Caller | Before (1 holder) | Before (2+ holders) | After | Assessment |
|---|---|---|---|---|
| `scanUnitLoad` banner (`:255`, via `findBlockingReplen`) | banner iff that holder `blocksMove` | 500 (IncorrectResultSize) | banner iff **any** holder blocks — the blocking one is returned first | Correct. Returning the blocker first is exactly what the banner needs; a non-blocking lowest-id return would have hidden a STARTED sibling. |
| `checkReservedStock` (`:299`, `!= null`) | skip the reservation check | 500 | skip iff any holder exists | Correct. Only non-emptiness matters; order is irrelevant. (But see M2: it loads entities it never reads.) |
| `transferStock` guard (`:774-779`) | throw, message chosen by `blocksMove` | 500 | throw; STARTED holder named with the in-progress message if one exists, else lowest-id named with the holds-stock message | Correct and strictly better than "lowest id always": the operator is told about the order that genuinely cannot be cancelled away. Residual: only ONE of N holders is named (L1). |

Behaviour is identical to before for 0 and 1 holder (the single holder is returned whether or not it blocks), so
no 1-holder regression is possible from the selection rule.

### Q2. Persistence-context side effects

* `scanDestination` **is** `@Transactional(value = "tenantTransactionManager", rollbackFor = …)` (`MobileMoveUnitloadService.java:316`). `existsForStockUnit` is `@Transactional(readOnly = true)` with default REQUIRED, so inside `scanDestination` it joins that read-write transaction and its loads land in the move's persistence context.
* `scanUnitLoad` is **not** transactional, and `spring.jpa.open-in-view=false` (`application.properties:85`), so there each `existsForStockUnit` call is its own short read-only transaction/EM. No cross-call PC leakage on the first scan.
* **Pre-existing, already true before this diff:** the old finder `findByStateLessThanAndStockunitId` loaded the holder entity (managed at READ). In `scanDestination`, `checkReservedStock` (`:404`) calls `existsForStockUnit` for every stock unit with `reservedamount != 0` — which is the normal state of a replen-held SU — and then the location/carrier arm reaches `UnitloadBusinessService.processTransfer:537 → ReplenishmentOrderSourceSyncService.syncForMovedStockUnit`, whose `findByIdForUpdate(probeId)` (`:92`) is therefore a version-checked lock **upgrade** on the same row. The SBDEV-3244 F5 probe-by-id in the sync/maintenance services is undermined on this path by the earlier `checkReservedStock` load. Not introduced here — see M3.
* **1 holder:** old = 1 entity loaded via JPQL; new = projection + `findById` = 1 entity loaded via `em.find`. Same footprint, same lock mode (both plain reads). **No worse.**
* **2+ holders:** old = 500 at `checkReservedStock`, so nothing downstream ran. New = all N holders loaded as managed entities, then (location/carrier arm) the sync's `findIdByStateLessThanAndStockunitId` throws `IncorrectResultSizeDataAccessException` anyway (the known, out-of-scope site). So today no new upgrade is *reachable*; the N managed entities become a real hazard the moment the sync is fixed to iterate holders and lock each one — every one of them would be an upgrade. See M2 for the one-line way to keep the footprint at "at most one entity".
* Verdict on "strictly no worse than before": **yes, for every shape that did not previously 500.** For the 2+ shape it is "no worse today, a trap for the sync follow-up".

### Q3. Recursion — cycles, query count, null ids

* **Cycles:** `findBlockingReplen` has no visited set (unlike `UnitloadBusinessService.processTransfer`, SBDEV-3091, which carries `Set<Long> visited`). A carrier cycle would `StackOverflowError`. However `checkReservedStock(unitLoad)` runs first on the same tree in `scanUnitLoad` (`:181` before `:192`) with the same unguarded recursion, so it overflows first — **no new exposure**, but the pattern is duplicated (L4).
* **Query count:** per tree node, `findBlockingReplen` issues `findByCarrierunitloadId` + `findByUnitloadId` (both already issued by `checkReservedStock`'s walk), and per stock unit in the whole tree 1 holder projection + 1 `findById` per holder, each inside its own read-only transaction (OSIV off). Previously only the top-level stock units were probed. For a pallet of K cartons this roughly doubles the tree-walk queries and adds ~2K replen queries plus K transaction begin/commits. Early return on the first blocker bounds the happy-ish path; the common "no replen anywhere" path pays the full walk (L5).
* **Null ids:** `unitLoad.getId()`, `child.getId()`, `stockUnit.getId()`, `holder.getId()` are all persisted PKs; Spring Data list finders never return null. No null path found. `findById` returning empty (row deleted between the projection and the load) is handled by `continue` (`ReplenishorderService.java:432-434`) — correct, but untested (L2).
* **Traversal order:** own stock first, then children depth-first — the same pre-order `processTransfer` uses to sync, so the banner names the same replen the destination scan would refuse on. Good.

### Q4. Test quality

* `ReplenishorderServiceUnitTest$ExistsForStockUnit`
  * `shouldReturnTheBlockingHolder_whenTheStockUnitHasTwoOpenReplens` (PROCESSABLE id 1, STARTED id 2 → STARTED): kills "return first" and "ignore blocksMove" mutants. Good.
  * `shouldReturnTheLowestIdHolder_whenNoHolderBlocks` (PROCESSABLE 300, RESERVED 400, both < STARTED 500 → id 1): kills "return last" / "return null when none block". Good.
  * A revert to the Optional finder is caught (unstubbed → `Optional.empty()` → `shouldReturnOrderWhenExists` fails).
  * Gaps: the `findById`-empty `continue` branch is untested — deleting `continue`/the null check survives (it would NPE only in `blocksMove(null)`, never exercised) (L2); no two-blockers case, so a mutant that keeps scanning and returns the *last* blocker survives (L2). The display name "…not a 500" overclaims: with a mocked repository the test cannot reproduce `IncorrectResultSizeDataAccessException`; it proves selection logic, not the absence of the exception (L3).
* `MobileMoveUnitloadServiceTest.scanUnitLoad_shouldPopulateActiveReplenNumber_whenAChildUnitLoadsStockHasAStartedReplen`: own SU → null, carton SU → STARTED, asserts number and `isHasActiveReplen()`. Kills "no child loop". Gap: one level only — replacing the recursive call with a single-level loop over children's stock survives; and no case pins that a **non-blocking** replen on a child is *not* bannered (the SBDEV-3523 invariant at depth) (L6).
* Edited tests — **none weakened.** `shouldReturnOrderWhenExists` / `shouldReturnNullWhenNoOrder` keep their assertions, only the stub moved to `stubHolders`. `ReplenishmentOrderMaintenanceServiceReassignTest:183-184` is a comment-only edit; the `verify(..., never()).findByStateLessThanAndStockunitId(...)` pin is untouched. Existing `scanUnitLoad` tests at `:312`/`:348` still hold because the mocked `findByCarrierunitloadId(1L)` defaults to an empty list. `MobileMoveUnitloadServiceUnitTest:2583` (`times(2)` on `scanDestination`) is unaffected — `scanDestination` does not call `findBlockingReplen`.

### Q5. Stale comments

Grep for `existsForStockUnit|findByStateLessThanAndStockunitId` across `src/main`, `src/test`, `*.md` and `sbdocs/3-Resources`:
* `ReplenishorderRepository.java:195-198` — updated; accurate ("no longer has a src/main caller"; the finder at `:128` is SDR-exported with an explicit `@RestResource(path=…)` and no `exported = false`). Note the second finder `findByStateAndItemdataId` (`:49`) is *also* SDR-exported (methods default to exported; `RepositoryDetectionStrategies.ANNOTATED` at `RestConfiguration.java:913` governs repositories, not methods) — the comment's "first and third" is accurate about *explicit path*, but a reader may infer the second is not exported (L7, pre-existing wording).
* `ReplenishorderRepository.java:219-222` ("exactly as Optional<Replenishorder> does today: behaviour preserved") — still true of the derived finder, which still exists. Not stale.
* `ReplenishmentOrderMaintenanceServiceReassignTest.java:183-184` — updated; accurate.
* `MobileMoveUnitloadService.java:183-185` — "surface an in-progress replenishment bound to **this unit load's** stock" — now also covers child unit loads; the new javadoc at `:246-252` says so, but the call-site comment does not (L8).
* `MobileMoveUnitloadService.java:285` (pre-existing) — "this also runs from the non-transactional scanUnitLoad **under OSIV**" — `spring.jpa.open-in-view=false` (`application.properties:85`) and no manual `OpenEntityManagerInView*` bean in `src/main`. Stale before this diff; flagged because the new `findBlockingReplen` javadoc cites "Read-only, like checkReservedStock" next to it (folded into L8).
* `sbdocs/3-Resources/design/wms2-replenishment-design.md:201` — generic signature row; still true.
* `db/v1-to-v2-onboarding/schema/V2.1.04__…sql:25` "Used by: findByStateLessThanAndStockunitId" — an applied migration; must not be edited, and the `(state, stockunit_id)` index serves the holders query equally.

### Q6. Sibling sweep (excluding the known `findIdByStateLessThanAndStockunitId` in sync/maintenance)

* `git grep -nE "Optional<[A-Za-z]+> [a-zA-Z]*(Stockunit|stockunit)[A-Za-z]*\(" src/main/java/net/aim_ai/wms/repo` → only `ReplenishorderRepository:129` and `:225`.
* **`ReplenishorderRepository.java:128-129` `findByStateLessThanAndStockunitId` is still a live SDR search endpoint** (`/v3/replenishorder/search/findByStateLessThanAndStockunitId`) returning `Optional<Replenishorder>`; for a multi-holder SU it 500s over HTTP. `git grep` on `origin/develop` of `wms2-web-ui` and `wms2-mobile-ui` finds no caller. Low (L9); propose separately alongside the sync/maintenance site.
* `ReplenishGeneratorService.findBlockingPendingOrder` returns `Optional<Replenishorder>` but is keyed on item/destination, not stock unit; not this shape. No other `existsForStockUnit`-style caller found.

---

## Findings

### Medium

**[M1] Claim scope: Move Unit Load to a location/carrier still 500s on a multi-holder stock unit**
File: `ReplenishmentOrderSourceSyncService.java:82-84` (reached from `UnitloadBusinessService.java:537`), commit message of 05e8c27c
Confidence: HIGH
Snippet: commit message — "which throws IncorrectResultSizeDataAccessException (a 500 on Move Unit Load) when a stock unit holds two open replens"
Issue: Fix 2 removes the 500 from `scanUnitLoad` and from `checkReservedStock`/`transferStock` in `scanDestination`, but on the location and carrier arms the move then reaches `syncForMovedStockUnit`, whose `findIdByStateLessThanAndStockunitId(...)` is `Optional<Long>` and throws the same exception. The 500 has moved one step later, not gone, for the most common Move Unit Load destination. Known and deliberately out of scope, but the commit/PR wording reads as if Move Unit Load no longer 500s.
Fix: state in the PR body and ticket that the location/carrier arms still 500 for a multi-holder SU until the sync/maintenance proposal lands, and link it. Optionally add a `[pin]` test asserting today's behaviour so the follow-up flips it deliberately.

**[M2] `existsForStockUnit` loads every holder as a managed entity when it needs at most one**
File: `ReplenishorderService.java:428-442`
Confidence: HIGH (that it loads N); MEDIUM (that it matters today)
Snippet: `Replenishorder order = replenishorderRepository.findById(holder.getId()).orElse(null);` inside the loop over all holders
Issue: `ReplenishorderHolderView` already carries `getState()` and `getNumber()`. Choosing on the projection and calling `findById` once for the chosen id keeps the PC footprint at exactly what the old finder had (one entity). Today the extra entities are harmless because the sync throws for 2+ holders (M1), but once the sync is fixed to lock each holder, every one of them would be a version-checked lock upgrade (SBDEV-3244 F5 shape), and `scanDestination` would have loaded them all.
Fix: select on the projection — first view with `state != null && state >= STARTED`, else the first view — then `findById` that one id (keep the `continue`-style fallback if it is gone). Equivalently add a `blocksMove(Integer state)` overload to `ReplenishmentOrderMessages` so the predicate stays single-sourced.

**[M3] (pre-existing, not introduced) `checkReservedStock` defeats SBDEV-3244 F5 on the Move Unit Load location arm**
File: `MobileMoveUnitloadService.java:299` → `ReplenishmentOrderSourceSyncService.java:92`, `ReplenishmentOrderMaintenanceService.java:282`
Confidence: MEDIUM (reasoned from the SBDEV-3244 comments' own model; not measured)
Snippet: `if (replenishorderService.existsForStockUnit(stockUnit) != null) {`
Issue: inside `@Transactional scanDestination`, for any SU with `reservedamount != 0` (the normal state of replen-held stock) this loads the replen entity at READ; the location/carrier arm then calls `findByIdForUpdate` on the same id — a version-checked upgrade, which is exactly what F5's probe-by-id was written to avoid. A concurrent cron recalculation committing in between yields `StaleObjectStateException` (409) instead of a serialized wait. True before and after this diff.
Fix: `checkReservedStock` only needs existence — give `ReplenishorderService` a `hasActiveHolder(Long stockUnitId)` backed by the holders projection (or an `exists…` query) and use it there. That also removes M2's entity loads from this caller. Propose under the sync/maintenance follow-up rather than this ticket if scope is tight.

### Low

**[L1] `transferStock` names only one of N holders**
File: `MobileMoveUnitloadService.java:774-779`
Confidence: HIGH
Issue: with two not-started holders the operator is told about the lowest id, cancels it, retries, and is refused again naming the second.
Fix: acceptable as is; optionally append "(and N more)" using the holders count.

**[L2] Unpinned branches in `existsForStockUnit`**
File: `ReplenishorderServiceUnitTest.java` `ExistsForStockUnit`
Confidence: HIGH
Issue: no test for `findById` → empty (`continue`), and no test with two blocking holders (a "return last blocker" mutant survives).
Fix: add both: holders [1 (findById empty), 2 PROCESSABLE] → returns 2; holders [1 STARTED, 2 STARTED] → returns 1.

**[L3] Display name overclaims**
File: `ReplenishorderServiceUnitTest.java` — `@DisplayName("two open holders: returns the one that blocks a move, not a 500")`
Confidence: HIGH
Issue: with a mocked repository the test cannot observe `IncorrectResultSizeDataAccessException`; it proves the selection rule only.
Fix: drop "not a 500", or add a repository-level test with two real rows (the holders query itself is already covered by `ReplenishmentIdProjectionContractUnitTest`).

**[L4] Unguarded recursion duplicated**
File: `MobileMoveUnitloadService.java:260-265`
Confidence: HIGH (that there is no guard); LOW (that a cycle exists in data)
Issue: no visited set, unlike `UnitloadBusinessService.processTransfer` (SBDEV-3091). No new exposure because `checkReservedStock` overflows first on the same tree.
Fix: optional — pass a `Set<Long> visited` as `processTransfer` does, ideally to both walks.

**[L5] Second full tree walk on every first scan**
File: `MobileMoveUnitloadService.java:181` and `:192`
Confidence: HIGH
Issue: `checkReservedStock` and `findBlockingReplen` each walk the tree (`findByCarrierunitloadId` + `findByUnitloadId` per node); the new walk also probes every SU in the tree, each probe in its own read-only transaction (OSIV off).
Fix: acceptable for typical pallets; if it shows up, collect the tree's stock-unit ids once and run one `state < FINISHED AND stockunitId IN :ids ORDER BY id` projection query.

**[L6] Child-carton test is one level deep and positive-only**
File: `MobileMoveUnitloadServiceTest.java:358-401`
Confidence: HIGH
Issue: a single-level loop (no recursion) passes; nothing pins that a not-started replen on a child is *not* bannered.
Fix: add a grandchild case (pallet → carton → inner carton with STARTED) and a child PROCESSABLE case asserting `getActiveReplenNumber()` is null.

**[L7] Repository comment implies `findByStateAndItemdataId` is not SDR-exported**
File: `ReplenishorderRepository.java:195-197`
Confidence: MEDIUM
Snippet: "the first and third are SDR-exported under an explicit @RestResource(path=...)"
Issue: `findByStateAndItemdataId` (`:49`) has no `@RestResource` and is exported by default on this `@RepositoryRestResource` interface. Wording pre-dates this diff, but the edited sentence is the place a reader will look.
Fix: "all three are SDR-exported (the first and third under an explicit path); removing any is an API contract change."

**[L8] Call-site / neighbour comments not updated**
File: `MobileMoveUnitloadService.java:183-185`, `:285`
Confidence: HIGH
Snippet: "surface an in-progress replenishment bound to this unit load's stock"; "runs from the non-transactional scanUnitLoad under OSIV"
Issue: the first now also covers child unit loads; the second is false (`spring.jpa.open-in-view=false`, `application.properties:85`) — pre-existing.
Fix: "… bound to stock on this unit load or any child unit load"; replace "under OSIV" with "outside any transaction (OSIV is off)".

**[L9] Sibling: SDR search `findByStateLessThanAndStockunitId` still 500s for multi-holder SUs**
File: `ReplenishorderRepository.java:128-129`
Confidence: HIGH (shape); no UI caller found on `origin/develop` of either v2 UI
Snippet: `@RestResource(path = "findByStateLessThanAndStockunitId", rel = "findByStateLessThanAndStockunitId") Optional<Replenishorder> findByStateLessThanAndStockunitId(...)`
Issue: same Optional-on-multi-row shape, reachable over HTTP. Now has no src/main caller.
Fix: propose with the sync/maintenance follow-up: mark `exported = false` after an HTTP-caller sweep (SBDEV-3486 precedent), or change to `List<Replenishorder>` (an API contract change).

## Open Questions (low-confidence, not blocking)

* Lock mode of an `em.find`-loaded entity vs a JPQL-loaded one: M2/M3 assume both enter the PC at READ (the SBDEV-3244 comments' model for "a plain finder"). If `em.find` differs, M3's 1-holder analysis changes for the new code only marginally — both paths still precede `findByIdForUpdate`. Confirm with the existing SBDEV-3244 IT if one measures it.

## Positive observations

* Reuses the SBDEV-3622 holders projection with its deterministic `ORDER BY r.id` rather than adding a fourth finder.
* Selection rule is minimal and correct for all three callers; 0/1-holder behaviour is byte-for-byte unchanged in outcome.
* `findBlockingReplen` traverses in the same pre-order as `processTransfer`'s sync, so the banner names the replen the destination scan will actually refuse on.
* The `blocksMove` predicate stays single-sourced in `ReplenishmentOrderMessages` across all banner/guard sites.
* The repository comment was updated in the same commit to record that the entity finder lost its last src/main caller, and the F5 pin test comment was corrected rather than left asserting a caller that no longer exists.

## Counts

High 0 · Medium 3 (M3 pre-existing) · Low 9 — total 12.

---

## Re-review of 08132098

Scope: `git show 08132098` (7 files, +150/−54) on top of 05e8c27c. Read-only. No mvn, no jdtls (a verify run was in progress).

### Verdict

**APPROVE** — 0 High, 0 Medium, 2 Low. M2 and M3 are fixed correctly. None of the stub edits weakens a test, `hasActiveHolder` is used at every call site that only needs existence, and the new comments are accurate. The deferred items (M1, L1, L4, L5, L9) are all defensible as stated (see below).

### Prior findings: status

| # | Status | Evidence |
|---|---|---|
| M2 | **Fixed** | `ReplenishorderService.existsForStockUnit` now chooses on the projection (`blocksMove(h.getState())`, else `holders.get(0)`) and calls `findById` once. Pinned by `shouldLoadOnlyTheChosenHolder` (`verify(findById(2L))`, `never().findById(1L)`). |
| M3 | **Fixed** | `checkReservedStock` (`MobileMoveUnitloadService.java:301`) calls `hasActiveHolder`, which reads the projection only. Pinned twice: `MobileMoveUnitloadServiceUnitTest:2586-2587` (`hasActiveHolder` once, `existsForStockUnit` `times(1)`; a revert makes it 2), and the strict `hasActiveHolder(stockUnit)` stub at `:1380`, which would raise `UnnecessaryStubbingException` under `MockitoExtension` if `checkReservedStock` stopped calling it. |
| L2 | **Fixed (mostly)** | The two-blockers test is added (`shouldReturnTheLowestIdBlocker_whenTwoHoldersBlock`). The `findById`-empty branch changed shape and is still untested (R1). |
| L3 | **Fixed** | Display name no longer says "not a 500". |
| L6 | **Fixed** | Grandchild test (kills a mutant that walks only one level) and not-started-child test (kills a mutant that drops `blocksMove` from the walk). |
| L7 | **Fixed** | `ReplenishorderRepository.java:196-197`: "all three are SDR-exported searches (the first and third under an explicit @RestResource(path=...))". Accurate. |
| L8 | **Fixed** | Banner comment now names child unit loads (`:183-185`). The OSIV claim is corrected to "outside any transaction (OSIV is off)" (`:285`), matching `application.properties:85`. |
| M1 | Deferred: PR body and ticket | **Defensible.** The remaining 500 lives in the known sync/maintenance `Optional<Long>` site, which is already being proposed, so documenting it is the right fix. Make sure the PR body says it in plain words ("location/carrier arm still 500s on a multi-holder SU"). |
| L1 | Deferred | **Defensible.** A retry names the next holder, and both message variants still refuse the move. |
| L4 | Deferred | **Defensible.** There is no new exposure, because `checkReservedStock` overflows first. If it is ever wanted, a private overload `checkReservedStock(Unitload, Set<Long>)` behind the existing one-arg method would leave the reflective tests untouched. |
| L5 | Deferred | **Defensible** for typical pallet sizes. |
| L9 | Deferred | **Defensible.** No UI caller on `origin/develop`, and it belongs with the same follow-up. |

### Your three questions

1. **Did the stub changes weaken anything?** No.
   * `MobileMoveUnitloadServiceTest:868/891/930` and `MobileMoveUnitloadServiceUnitTest:1316/1410`: `existsForStockUnit → null` became `hasActiveHolder → false`. These are equivalent to the old stubs and to Mockito's defaults, and every assertion is unchanged.
   * `MobileMoveUnitloadServiceUnitTest:1380-1381` (AC4): the old single stub served both `checkReservedStock` and the banner. It now stubs each lane separately. The fixture still has `reservedamount = TEN`, so the `hasActiveHolder` stub is actually exercised. The test still pins "active replen on reserved stock is not cancelled" (`never().cancelReplenishmentOrder`).
   * `:2497` adds a lenient `hasActiveHolder → true` alongside the existing lenient `existsForStockUnit` stub. That keeps the "real-world shape" test meaningful: a reservation held by a replen passes `checkReservedStock` and is then refused by the SBDEV-3747 guard.
   * `:2585-2587`: `times(2)` became `hasActiveHolder` once plus `existsForStockUnit` `times(1)`. This is stricter than before, not weaker, because it now separates the two lanes.
   * The `scanUnitLoad` tests at `MobileMoveUnitloadServiceTest:312/348` use `mockStockunit` with `reservedamount = ZERO` (`:234`). `checkReservedStock` never consults the replen service for them, so there is no hidden path change.
2. **Is `hasActiveHolder` used everywhere existence-only is meant?** Yes. `git grep` in `src/main` finds three call sites:
   * `:255`, the banner: needs the blocking holder's number. It is non-transactional, so there is no persistence-context concern.
   * `:301`, `checkReservedStock`: existence only. Now uses `hasActiveHolder`.
   * `:776`, `transferStock`: needs the order to build its message, and it throws whenever the result is non-null. Any entity it loads is never followed by a lock in that transaction.

   No other caller exists.
3. **Are the new comments accurate?** Yes.
   * The `existsForStockUnit` javadoc ("at most one entity … callers that need only existence use hasActiveHolder") matches the code.
   * The `hasActiveHolder` javadoc ("no Replenishorder entity is loaded") matches the code: it is a JPQL scalar projection.
   * The `checkReservedStock` SBDEV-3755 comment is accurate for this call. I found no other `Replenishorder` load in `scanDestination` ahead of `processTransfer`'s sync (MEDIUM confidence, from reading the method only).
   * The `blocksMove(Integer)` overload keeps the predicate in one place. `blocksMove(Replenishorder)` now delegates to it, so `ReplenishmentOrderMessagesTest`'s null-state and threshold cases cover both. No `blocksMove(null)` literal exists, so the overload causes no compile ambiguity.

### New findings

**[R1] Low: `existsForStockUnit` returns null when the chosen holder's `findById` comes back empty, and this is untested**
File: `ReplenishorderService.java` (new body), `return chosen == null ? null : replenishorderRepository.findById(chosen.getId()).orElse(null);`
Confidence: HIGH that it is untested; LOW that it matters.
Issue: The old loop skipped a vanished row and moved on to the next holder. The new code returns null even when other holders exist, so `transferStock` would let the drain through. This only happens if the row is deleted between the projection and the load inside one read-only transaction. Replens finish by changing state, not by being deleted, so this is practically unreachable. Either behaviour is acceptable, but neither is pinned: a mutant using `orElseThrow()` survives.
Fix: Optional. Either add a one-line test pinning the null, or fall back to `holders.get(0)` only when it is a different id.

**[R2] Low: `hasActiveHolder` pulls full projection rows to answer a yes/no question**
File: `ReplenishorderService.java`, `hasActiveHolder`
Confidence: HIGH
Issue: It reuses `findHoldersByStateLessThanAndStockunitIdOrderById`, which returns 6 columns per holder, sorted. An `existsBy…` / `SELECT COUNT(r) > 0` query would be cheaper. The cost is negligible at 0–2 rows per SU, and reusing the finder keeps the predicate single-sourced. Noted only for completeness.
Fix: None needed.

### Re-review counts

High 0 · Medium 0 · Low 2. Total 2 new. All prior findings are either fixed or deferred on defensible grounds.
