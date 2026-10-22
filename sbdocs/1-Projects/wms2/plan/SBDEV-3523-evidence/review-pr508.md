---
title: "SBDEV-3523 — independent review of wms2-api PR #508"
ticket: SBDEV-3523
type: review
date: 2026-10-13
reviewed: 11468c4a...d5eca5ec (14f242c1, a03f609d, d5eca5ec)
verdict: APPROVE (no blocking findings; Lows recommended)
---

# Code Review Summary — wms2-api PR #508 (SBDEV-3523)

**Scope:** the whole PR diff `git diff 11468c4a...d5eca5ec`, with extra attention on d5eca5ec, which had not been reviewed before.
**Files reviewed:** 6 changed files. For context I also read `UnitloadBusinessService.processTransfer`, `MobileMoveUnitloadService.scanDestination` / `transferStock` / `checkReservedStock`, `ReplenishorderService.existsForStockUnit`, `PickLineActivityCodeClassifier`, `TransferInfoDto`, `Replenishorder` + DDL, and mobile `components/moveUnitload/scanDestination.vue` (origin/develop 36368b6).
**Method:** git, gh and file reads only. I did not run mvn or LSP, because another session's builds are running. Evidence for the build: the GitHub `test` check on head d5eca5ec is **SUCCESS** (run 38424586567). origin/develop has not moved past base 11468c4a, so there is no rebase drift.
**Total issues:** 9. CRITICAL 0 · HIGH 0 · MEDIUM 0 · LOW 9 (L1 has two parts: L1a and L1b).

## d5eca5ec specifically

- **Main source:** whitespace and reflow only. The comment text in `MobileMoveUnitloadService` is word-for-word the same as in a03f609d. No behaviour change.
- **New test:** `ReplenishmentOrderMessagesTest`, a `@CsvSource` over 0, 55, 300, 400, 499 → false and 500, 530 → true.
  - Every row is a compile-time constant expression (`int + String` of `static final int`), so the annotation compiles. `@CsvSource` already has precedent in the suite (`StockUnitControllerUnitTest`, etc.).
  - It pins both sides of the `>=` boundary, so the `>`/`>=` mutant and any threshold shift are killed. The test cannot pass vacuously, because it calls the predicate directly.
  - No duplicate test class exists for `ReplenishmentOrderMessages`.
  - Gap: no row at or above FINISHED. See L2.

## Stage 1 — Spec compliance: PASS

The ticket asks for the banner to stop firing on replen orders the move would not block. The PR does exactly that:

- `scanUnitLoad` now sets `activeReplenNumber` only when `blocksMove(ro)` is true.
- Both throw sites use the same predicate. Their behaviour is unchanged: `>= STARTED` before and after.
- Nothing extra is in the diff: no UI change, no message change, no contract change. `activeReplenNumber` and `hasActiveReplen` keep the same shape and are just null in more cases.

## Correctness of `blocksMove` at each call site

| State | blocksMove | SourceSync (replenishable dest) | Maintenance (non-replenishable dest) | Banner |
|---|---|---|---|---|
| 0 RAW | false | re-point | reassign/cancel | hidden |
| 50 / 55 / 56 / 57 / 58 on-hold | false | re-point | reassign/cancel | hidden |
| 300 PROCESSABLE / 400 RESERVED | false | re-point | reassign/cancel | hidden |
| 500 STARTED, 520–530 | true | throw | throw | shown |
| ≥ 700 | true (!) | unreachable: probe is `StateLessThan(FINISHED)` | unreachable | unreachable: `existsForStockUnit` is `< FINISHED` |
| null | NPE | unreachable | unreachable | unreachable |

- **Throw sites.** The before/after diff is a pure substitution of `x.getState() >= WmsConstants.State.STARTED` with `ReplenishmentOrderMessages.blocksMove(x)`. Both sites keep their `findByIdForUpdate` re-read before the predicate, so the predicate still judges locked, current state.
- **On-hold 50–58.** The predicate returns false, so these orders are re-pointed or reassigned, and the banner now agrees with that. This behaviour was already in place at the throw sites before the PR.
- **530.** Blocks at all three sites. The a03f609d parameterised banner test and the new direct test both pin it.
- **null state.** It is unreachable:
  - the DDL has `state integer NOT NULL` (`V2.2.00__base_v2_schema.sql`);
  - the entity has `@NotNull private Integer state = WmsConstants.State.RAW;`.

  The banner path did not unbox `state` before this PR and now does (see L5).
- **Multi-stock-unit loop.** `if (activeReplen != null && blocksMove(activeReplen)) { ...; break; }` now skips a non-blocking replen and keeps scanning later stock units. This is correct. The old code broke on the first non-null result, so a RAW replen on stock unit #1 would have masked a STARTED one on stock unit #2. The PR fixes that by accident, and no test covers it (L3).

## Can the banner now hide a replen that DOES block?

1. **No hiding is introduced on the arms that block.**
   - On the location arm (`transferUnitLoadToLocation`) and the existing-pallet arm with `moveStock=false` (`transferUnitLoadToCarrier`), both paths reach `processTransfer`, then `CODE_TRANSFER` (BLOCK_REALIGN), then `syncForMovedStockUnit`, and those arms block exactly at `blocksMove`.
   - The banner predicate and the block predicate are now the same function, so on these arms, for the scanned unit load's own stock, the banner equals the block.
2. **Time-of-check gap (scan → destination).** If a replen goes from below 500 to STARTED between `scanUnitLoad` and `scanDestination` (a handheld claims it, SBDEV-3626), the banner is hidden but the move blocks. This is inherent to an early warning, and the throw still names the order (`replenBlockMessage`). Before the PR, the banner happened to cover this case because it over-warned. See L6.
3. **Child unit loads (existing gap, not a regression).** `scanUnitLoad` only looks at `stockunitRepository.findByUnitloadId(unitLoad.getId())`, the scanned unit load's direct stock. `processTransfer` recurses into children (`processTransfer(child, ...)` at UnitloadBusinessService:557) and calls `syncForMovedStockUnit` for each child's stock. So moving a pallet whose carton has a STARTED replen blocks with no banner. This was equally true before #508. See L7.
4. **transferStock arms run no replen check at all** (flow-bin location, fixed-assignment unit load, `moveStock=true` pallet). Here a STARTED replen shows the banner, but the move goes through. The banner over-warns on these arms; it never hides. SBDEV-3747 owns this gap. Two documents in #508 make claims that are false on these arms (L1a, L1b).
   - Nuance on the PR body's "Not in this PR" wording: *"Moving onto a flow bin or an existing pallet (`transferStock`)"*. The **default** existing-pallet path (`moveStock=false`, the one the shipped mobile client sends) goes through `transferUnitLoadToCarrier → processTransfer`, which **does** block. Only `moveStock=true` (a pallet unit load with no fix-assignment) and the two flow-bin forms go through `transferStock` (MobileMoveUnitloadService:464, :514, :529). See L8.

## Mobile UI (`v2/wms2-mobile-ui`, origin/develop 36368b6)

The only use is in `components/moveUnitload/scanDestination.vue:15-16`:
```
<v-alert v-if="info && info.activeReplenNumber" dense type="warning" class="mx-4 my-2">
  Replenishment {{ info.activeReplenNumber }} is in progress for this stock — complete or cancel it before moving.
```

- The banner is display-only, truthy-gated, and has no other consumer.
- `hasActiveReplen` is not read anywhere in the mobile UI. `wms2-web-ui` has zero references.
- Null is already the "no banner" value, so **nothing breaks**.
- The wording "in progress … complete or cancel it before moving" is now accurate on the blocking arms. On the transferStock arms it is still false (L1b).

## Test adequacy

- **The negative banner test cannot pass vacuously.**
  - The class runs `@MockitoSettings(strictness = Strictness.STRICT_STUBS)`, so the `existsForStockUnit(mockStockunit)` stub must be consumed. That proves the loop ran and saw the replen.
  - The PR states the test failed before the fix on its own assertion, which is consistent: before the fix, the number was set for any non-null result.
  - It covers 0, 55, 300 and 400.
- **The positive banner test** now sets the state explicitly (500, 530). Before the PR it used the default RAW and still passed, which would now be wrong. Good catch.
- **Direct predicate test (d5eca5ec):** good boundary coverage, as described above.
- **Gaps** (none blocks a merge):
  - no row ≥ FINISHED (L2);
  - no multi-stock-unit "skip non-blocking, find later blocking" case (L3);
  - no throw-site test is newly parameterised over the on-hold band. The existing throw-site tests already cover below-STARTED re-point/reassign, and the substitution is mechanical, so this is acceptable.

## Issues

**[LOW] L1a — The javadoc claim "the warning cannot again fire for a replen the move would not block" is false on the transferStock arms**
File: `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMessages.java:20-25`
Confidence: HIGH
> "Both throw sites and the mobile early warning (`MobileMoveUnitloadService.scanUnitLoad`) call this, so the warning cannot again fire for a replen the move would not block."

`scanUnitLoad` does not know the destination yet. With a STARTED replen and a flow-bin destination, or a `moveStock=true` pallet, the warning fires but `transferStock` moves the stock without any replen check (SBDEV-3747). The same javadoc also says *"Anything earlier is re-pointed or reassigned by the move instead"*, which is false on those arms, where nothing is re-pointed. It also leaves out "cancelled".
Fix: scope the claim, for example: *"…so on the whole-unit-load arms (`transferUnitLoadToLocation` / `transferUnitLoadToCarrier` → `processTransfer`) the warning and the block agree; the `transferStock` arms run no replen check (SBDEV-3747)."* Write "re-pointed, reassigned or cancelled". Alternatively, have SBDEV-3747 rewrite this sentence when it lands.

**[LOW] L1b — The scanUnitLoad comment makes the same over-broad claim**
File: `src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java:186-189`
Confidence: HIGH
> "SBDEV-3523: only a replen the move would actually block on … A not-yet-started one is re-pointed or reassigned by the move itself"

Same scoping problem as L1a: on the transferStock arms the move neither blocks on a STARTED replen nor re-points a not-started one. Also leaves out "cancelled" (`cancelOrder` on `NO_CANDIDATE`).
Fix: same scoping as L1a, or a pointer such as "(whole-unit arms; see SBDEV-3747 for transferStock)".

**[LOW] L2 — `blocksMove` is now public, and it says FINISHED/CANCELED replens block a move**
File: `ReplenishmentOrderMessages.java:27-29`
Confidence: HIGH (fact) / LOW (likelihood of misuse)
```java
public static boolean blocksMove(Replenishorder ro) {
    return ro.getState() >= WmsConstants.State.STARTED;
}
```
The javadoc says "started or later", which covers 700 and 800. Today every caller pre-filters to `< FINISHED`, so this is correct in practice. But the method was made `public` precisely so other packages can call it. A future caller that passes an unfiltered replen (for example from `findByStockunitId`) would block moves on finished or cancelled orders. The new test does not pin 700 or 800 either way.
Fix: either encode the band, `state >= STARTED && state < FINISHED` (behaviour-neutral for all three current callers), or state the precondition in the javadoc ("caller must pass an active, < FINISHED order"). Add rows for 700 and 800 to `ReplenishmentOrderMessagesTest`.

**[LOW] L3 — No test for the multi-stock-unit loop: skip a non-blocking replen, then flag a later blocking one**
File: `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileMoveUnitloadServiceTest.java` (new tests at about :291 and :327 use a single stock unit)
Confidence: HIGH
The behaviour changed: the loop used to `break` on the first non-null result, and now continues past a non-blocking one. A refactor to `if (activeReplen != null) { if (blocksMove(activeReplen)) set(...); break; }` would pass every current test. PIT will not generate that mutant.
Fix: add a test with two stock units. Stock unit 1 → replen at 300, stock unit 2 → replen at 500 numbered "REPL-B". Assert that `activeReplenNumber == "REPL-B"`. Fixture `mockStockunit2` already exists at about :525.

**[LOW] L4 — The class javadoc was not updated for the new responsibility (N1 left open)**
File: `ReplenishmentOrderMessages.java:5-13`
Confidence: HIGH
> "single source of truth for the operator-facing message shown when a Move Unit Load is blocked…"

The class now also owns the policy predicate, which is a second reason to change (SRP). The author deferred the naming question (N1) on purpose, which is reasonable for a T1 change. But the class doc should at least mention that it holds the predicate, so a reader looking for "where is the block threshold" finds it.
Fix: add one `<p>` noting that `blocksMove` is the shared threshold. Optionally move it to a `ReplenishmentMovePolicy` later.

**[LOW] L5 — The banner path now unboxes `Integer state`**
File: `ReplenishmentOrderMessages.java:28`, reached from `MobileMoveUnitloadService.java:192`
Confidence: HIGH that it is unreachable today
Before the PR, `scanUnitLoad` never read `getState()`. It now unboxes it, so a null-state replen would make the first scan return a 500. The DDL `NOT NULL` and the entity's `@NotNull` plus `RAW` default make this unreachable. A Mockito `mock(Replenishorder.class)` stub would hit it, but no test uses one (checked).
Fix: optional. `ro.getState() != null && …` matches the house style (`ReplenishorderService:333`, `MobileReplenishService:585`). Otherwise, no action needed.

**[LOW] L6 — The early warning is now strictly a point-in-time snapshot (time-of-check gap)**
File: `MobileMoveUnitloadService.java:190-195`
Confidence: MEDIUM
Suppose a replen is at state 300 when the unit load is scanned and is claimed to STARTED before the destination scan. The operator then gets no banner, and the move is refused at `scanDestination`. The throw still names the order, so this is acceptable and inherent to an early warning. Recording it so nobody later reads "no banner" as "won't block".
Fix: none required. Optionally add a clause to the comment: "a snapshot; the throw sites re-judge under lock".

**[LOW] L7 — Existing gap (not caused by #508): the banner ignores child unit loads, while the block covers them**
File: `MobileMoveUnitloadService.java:169, 190` vs `UnitloadBusinessService.java:534-537, 557`
Confidence: HIGH
The banner loop iterates only `stockunitRepository.findByUnitloadId(unitLoad.getId())`. `processTransfer` recurses into children and calls `syncForMovedStockUnit` for each child stock unit, so a STARTED replen on a carton inside a scanned pallet blocks the move with no banner. `checkReservedStock` already recurses (`for (Unitload ul : unitloadRepository.findByCarrierunitloadId(...)) checkReservedStock(ul)`), so the pattern to copy is in the same file.
Fix: out of scope for #508 (T1). Propose it on SBDEV-3523 or fold it into SBDEV-3747, which touches the same "banner ⇔ block" invariant.

**[LOW] L8 — The PR body's "Not in this PR" paragraph overstates the existing-pallet gap**
File: PR #508 description
Confidence: HIGH
> "Moving onto a flow bin or an existing pallet (`transferStock`) appears never to run the replen sync"

The shipped client's existing-pallet move (`moveStock=false`) goes through `transferUnitLoadToCarrier` → `processTransfer` → `syncForMovedStockUnit`, and it **does** block. Only `moveStock=true` (which, per the code comment at about :487, the shipped client never sets) and the fixed-assignment / flow-bin destinations use `transferStock` (MobileMoveUnitloadService:464, :514, :529).
Fix: reword to "onto a flow bin / fixed-assignment unit load, or with `moveStock=true` (`transferStock`)". Do the same in the SBDEV-3747 ticket, so its scope is not inflated.

**[LOW] L9 — Prose enumerations in comments will go stale**
Files: `ReplenishmentOrderMessages.java:22-24` ("Both throw sites and the mobile early warning"), `ReplenishmentOrderMessagesTest.java:13-14` ("not one of its three callers")
Confidence: HIGH
SBDEV-3747 will add a fourth caller, a transferStock-arm check, which makes both counts wrong.
Fix: state the rule instead of the count: "every Move-Unit-Load replen block and the scan-time warning must call this".

## Open questions (low confidence, not blocking)

- **[LOW] Uniqueness of the active replen per stock unit.** `existsForStockUnit` (`findByStateLessThanAndStockunitId` → `Optional`) and the throw-site probe both assume at most one active replen per stock unit. If two existed (for example one at 300 and one at 500), the derived single-result query would throw `IncorrectResultSizeDataAccessException`, which surfaces as a 500 on scan. It would not silently hide anything. This is pre-existing, and #508 does not change it. I did not check the DB (read-only brief).
- I did not independently verify the WineCo PRD census in the commit message ("573 active replens, all at state 300"). It is not needed for code correctness.

## Positive observations

- The root cause is fixed at the right level: one predicate shared by the warning and both blocks removes the drift that caused the ticket.
- The throw-site substitution is purely mechanical. The lock re-read before the predicate is preserved, and messages are unchanged.
- The tests vary the fixture instead of asserting a single value: four non-blocking states including on-hold 55, two blocking states including 530, and a direct `STARTED-1` / `STARTED` boundary pin. Under STRICT_STUBS, the negative test is grounded rather than vacuous.
- The positive test was quietly relying on the default RAW state. a03f609d set the state explicitly, which closed a test that was passing for the wrong reason.
- Narrow public surface: only `blocksMove` became public, and `replenBlockMessage` stayed package-private.
- d5eca5ec is safe: the comment change is a no-op reflow, and the new test is correct.

## Recommendation

**APPROVE.** There are no CRITICAL, HIGH or MEDIUM findings. Under the repo's "fix Low findings too" rule:

- **Cheapest to fix now** (comment, javadoc and test edits only): L1a, L1b, L2 (add 700/800 rows, and optionally the `< FINISHED` band), L3, L4 and L9.
- **Fix in the PR body and the SBDEV-3747 scope:** L8.
- **Propose rather than fold in:** L7 (child unit loads), as an existing gap on the banner ⇔ block invariant, ideally carried by SBDEV-3747.
