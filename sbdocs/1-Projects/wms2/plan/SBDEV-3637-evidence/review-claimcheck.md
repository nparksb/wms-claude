# SBDEV-3637 — claim check on `aafe1b05` (F-1's rewritten null-source row)

**Lane:** claimcheck. Read-only, no Maven run. **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3637`, branch `bugfix/SBDEV-3637-replenish-redirect-lock-order`, HEAD `aafe1b05`, clean.
**Scope:** the one question — is the new claim true, and is it complete. Nothing else reviewed.
**Date:** 2026-10-05

**Verdict: CLAIM SOUND.** Every clause checks out, `may` is the correct strength, and the "NOT TESTED" statement is accurate. **One defect, and it is the recorded failure mode: a fourth sibling copy of the retired reason survives in `src/test` and was not swept.**

---

## 1. Is the `recalc + null source` row true as written?

Clause by clause, against `ReplenishmentOrderMaintenanceService.java` lines 623–633.

| Clause | Verdict |
|---|---|
| *"No lock was taken for THIS order's source"* | **TRUE and exhaustive.** On `recalcPath = true`, `redirectSource` has exactly one caller — `ensureValidSource`'s `RedirectOutcome outcome = redirectSource(order, source, share, true);` — and `source` there is `order.getStockunitId() == null ? null : stockunitRepository.findByIdForUpdate(order.getStockunitId()).orElse(null)`. So a null `currentSource` on the recalc path means precisely the two stated causes and no third. (The other call site, `redirectSource(order, lockedSource, share, false)` in `reassignOrCancelForMovedStockUnit`, is `recalcPath = false` and is the move row.) |
| *"`FOR UPDATE` on a missing row takes no lock"* | **TRUE**, and stated independently elsewhere in `src/main` — `MobilePalletizeWriteService`: `` `SELECT ... FOR UPDATE` that matches ZERO rows takes no lock ``. |
| *"recalculateForItem sweeps an item's orders in ONE transaction (plain `this.` call, deliberately — see the loop)"* | **TRUE.** `recalculateForItem` is `@Transactional(value = "tenantTransactionManager", rollbackFor = …)`, and its loop body calls `recalculateOrder(orderId, ctx)` unqualified under `// WARNING: keep this as a plain (this.) call — do NOT change to self.recalculateOrder.` No proxy, so `recalculateOrder`'s own `@Transactional` is not intercepted and every iteration shares the one transaction. The contrast is real and the comment names the right method: the *other* sweep, `recalculateOpenOrders`, uses `self.recalculateOrder(orderId, ctx)` under `// self proxy → @Transactional intercepted → per-order short REQUIRED tx.` — it does **not** accumulate. |
| *"it JOINS an ambient transaction when one exists"* | **TRUE.** No `propagation` attribute on `recalculateForItem` ⟹ `REQUIRED`. Confirmed by two independent in-repo statements at the call sites: `StockunitService` — `// recalculateForItem is @Transactional(REQUIRED). Called with no ambient transaction it` — and the same sentence at `FixLocationAssignmentService`. |
| *"an earlier order's `ensureValidSource` lock … may still be held here"* | **TRUE.** `ensureValidSource` takes `stockunitRepository.findByIdForUpdate(order.getStockunitId())`, which is `@Lock(LockModeType.PESSIMISTIC_WRITE)` on `SELECT s FROM Stockunit s WHERE s.id = :id`. A PG row lock is held to transaction end, and the transaction spans the sweep. |
| *"The predicate compares against THIS order's source only"* | **TRUE.** `boolean skipLocked = !recalcPath \|\| targetIsBelowHeldSource(currentSource, candidate.stockUnitId);` — `currentSource` is this order's. |

### The SBDEV-3622 citation

The comment at `ReplenishorderRepository.findIdsByStateAndItemdataId` reads, verbatim:

> `// SBDEV-3622: ascending id, so recalculateForItem locks an item's orders in the same order as the`
> `// attributed reserved cut does (two orders on one stock unit could otherwise deadlock).`

**It supports the cited fact, but by entailment rather than in so many words.** It says `recalculateForItem` locks an item's order**s** (plural) and that two of them could deadlock — a deadlock requires both locks held at once, so cross-iteration accumulation is entailed. The new comment's verb *"is stated at"* is therefore a half-step strong; *"follows from"* would be exact. **Not a finding** — the fact is correct, the pointer resolves, and the load-bearing premise (the sweep shares one transaction) is anyway established directly at the loop, which the same sentence also cites.

⚠ One precision worth noting for a future reader: the cited comment is about **Replenishorder** row locks, not **Stockunit** locks. It establishes *that the transaction spans iterations*; it is the `ensureValidSource` acquisition, not this citation, that establishes a **stock-unit** lock is among what accumulates. The sentence does not claim otherwise ("accumulates **order** locks"), so this is a reading hazard, not an error.

---

## 2. `may` vs `is` — is `may` hedging something always true?

**`may` is correct; `is` would have been the sixth wrong claim.** Two constructions make it strictly false:

1. **The first order of the sweep.** `findIdsByStateAndItemdataId` is `ORDER BY r.id`; on `openOrderIds.get(0)` no earlier iteration has run, so no earlier order's lock exists. If that first order has a null source, nothing is held.
2. **Every order in the sweep having a null `stockunitId`.** `ensureValidSource` short-circuits (`order.getStockunitId() == null ? null : …`) and issues no query at all, so no iteration contributes a lock.

The same applies to the *"or a caller's"* arm: `ReplenishOrderJob` reaches `recalculateForItem` under `// on this path, so recalculateForItem (REQUIRED) opens its OWN` — no ambient transaction, no inherited caller lock.

Note this is a correction of the **review's own suggested text**, which said *"is still held here"*. The author was right not to paste it.

---

## 3. Is the row complete, and does any other row still over-claim?

### "NOT TESTED on any recalc row" — accurate

**Derivation:** `git grep -l "recalculateForItem" -- src/test` → 17 files; I then read the order-seeding of every one that reaches `redirectSource` on the recalc path.

- **Mocked lanes cannot test it at all.** `ReplenishmentOrderMaintenanceServiceUnitTest` and `ReplenishmentFirstTouchInvariantUnitTest` drive `recalculateForItem` against a mocked `StockunitRepository` — no real row lock exists on any row. Four sites do stub a two-order sweep (`stubItemOrders(10L, first, second)`, ×4), which is my positive control that the instrument *would* find a multi-order fixture — it found them, and they are still mocks.
- **The container lanes seed one order on the recalc path.** `ReplenishRedirectLockOrderIT.seedRecalcProbe` inserts a single `O_PROBE`; its two-order helper `seedInvertedPair` (`replen(O1, S1, …)` / `replen(O2, S2, …)`) feeds the **move** gate IT-1e, two threads in two transactions, not one sweep. `ReservationCutAttributionIT` has a genuine `twoOrdersOnA()`, but its `recalculateForItem` calls sit in `partialCut_regrowsOnNextRecalc_pinsAcceptedBehaviour`, which does not call it and asserts stockrecord rows, not finder choice.
- **No fixture anywhere produces a null-source replenishorder in a container.** `git grep -niE "stockunit_id = NULL|setStockunitId\(null\)" -- src/test` returns no replenishorder seed; positive control, `git grep -c "setStockunitId(" -- src/test` returns 5 files, so the token is findable.

**Blind spots of that derivation, inline:** it keys on `recalculateForItem` as the entry point, so a test reaching the sweep through a transitive caller (`StockunitService.triggerReplenishmentMaintenance`, `FixLocationAssignmentService.createFixedLocationAssignment`) without naming it is invisible to the grep; and I read seeding helpers rather than every assertion in all 17 files. Settling probe if it matters: instrument `redirectSource` to record `(currentSource id, candidate id, skipLocked)` per call and assert over a two-order container fixture — nothing short of a container test can observe an inherited lock.

### Other rows in the block

- `recalc + DESCENDING` — no transaction-scope claim.
- `recalc + ASCENDING` — explicitly declines safety: *"NOT because it is 'already deadlock-free' — it is NOT"*. Sound. Its exposure to the same inherited-lock gap is covered, since the new row scopes its statement to *"any recalc row"*, not to the null-source row alone. (Placement only: a reader stopping at the ASCENDING row will not see it.)
- `recalc + null target` — *"A source lock MAY be held here … but a finder bound to a null id matches no row and takes no lock either, so no edge is created in either direction."* **TRUE and robust to the gap**: `findByIdForUpdate` is `@Query("SELECT s FROM Stockunit s WHERE s.id = :id")` with `@Param`, so a null binds and matches nothing — the conclusion holds no matter how many locks the transaction holds.
- `move path` — *"This transaction has already accumulated locks on earlier stock units of the carrier tree"*. **One residual over-statement, opposite polarity.** On the first moved stock unit of a tree there are no *earlier* ones; what is unconditionally true is that `reassignOrCancelForMovedStockUnit` has itself taken `Stockunit lockedSource = stockunitRepository.findByIdForUpdate(movedStock.getId())` just above. The row's conclusion (`SKIP LOCKED` unconditionally) is unaffected, and the over-statement errs toward **caution**, not toward a safety claim — the failure mode this block exists to prevent. **Not a required fix.**

---

## 4. Sibling sweep — ONE COPY MISSED

**Method:** `git grep -n -i -E "no lock is held|no stock-unit lock|takes no lock|took no lock|no lock was taken|holds no .*lock" -- src/` plus a looser second pass, and the same patterns over the plan and `SBDEV-3637-evidence/`. Positive control in the same scan: `git grep -c "lock" -- …/ReplenishmentOrderMaintenanceService.java` → 89, so the instrument is live. (`grep` here is ugrep; `git grep` used throughout, so the binary-skip false zero does not apply.)

Three copies were fixed as claimed. **A fourth was not:**

`src/test/java/net/aim_ai/wms/unit/service/ReplenishmentFirstTouchInvariantUnitTest.java`, in `redirectSource_loadsTheTargetUnderItsLock`:

> `// It must NOT be called on this fixture: findByIdForUpdate(SU_SRC) is stubbed empty, so the`
> `// current source is null, no stock-unit lock is held, and Fix B's null-source rule routes the`
> `// target acquisition to the PLAIN finder.`

This is the retired reason verbatim — *"no stock-unit lock is held"* offered as the **cause** of the plain-finder routing. The cause is `currentSource == null`, a per-order fact; the transaction-scope statement is a property of the mock fixture, not of the rule.

Three things make this the copy that matters rather than a stray:

1. **It was added by this ticket.** `git log 29e43eb1^..HEAD -- <that file>` returns only `29e43eb1` — SBDEV-3637's own implementation commit. It is not inherited text.
2. **It is the exact construct the author did fix in the sibling file.** `ReplenishmentOrderMaintenanceServiceUnitTest`'s `@param` javadoc got the full treatment — *"(Not because the transaction holds none … This fixture drives one order under mocks, so here there genuinely is no other lock — that is a property of the fixture, not of the production path.)"* — and that disclaimer is exactly what this site needs and lacks.
3. **The plan points straight at it.** §4's case table ends *"Load-bearing: this case is what keeps `ReplenishmentFirstTouchInvariantUnitTest.redirectSource_loadsTheTargetUnderItsLock` green (§7.3)"*. The sweep had the pointer and did not follow it.

**Fix** — comment only, mirroring the wording already landed in the sibling test:

```
        // It must NOT be called on this fixture: findByIdForUpdate(SU_SRC) is stubbed empty, so the
        // current source is null, and Fix B's null-source rule routes the target acquisition to the
        // PLAIN finder because no lock was taken for THIS order's source. (Not because the
        // transaction holds none — see the Fix B comment block's null-source row. This fixture drives
        // one order under mocks, so here there genuinely is no other lock: a property of the fixture,
        // not of the production path.)
```

I verified the fixture premise before proposing that wording: `stubItemOrders(ITEM, order)` / `stubItemOrders(ITEM, …)` seeds one order in `recalcFixture`, and this test's own `service.recalculateForItem(ITEMDATA)` runs against a single stubbed id list.

No other copy survives. Plan §4 and AC-3 both carry the corrected text (*"no lock was taken for **this order's** source … ⚠ not 'the transaction holds no stock-unit lock'"*). The historical copies in `review-code.md` and `lane-b-architect.md` are quotations in dated review artifacts and are correctly left alone.

---

## 5. Was the sixth wrong claim avoided — is the S-1/P-7 distinction real?

**Real, not the same cycle renamed.**

- **S-1 / P-7** (`review-security.md` §S-1 *"SU↔SU ABBA remains live on the retained waiting edge"*; plan §10 P-7) is about **another method's** acquisition pair: `StockunitBusinessService.transferStockToUnitLoad` taking `sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId)` then `destinationStockUnit = stockunitRepository.findByIdForUpdate(dstSuId)` in role order with no id comparison. Its remedy is to order that method's own pair, at its own site.
- **The new gap** is about **this method's own predicate having an incomplete view of its own transaction's held set** — a lock contributed by a *different order* in the same sweep, or by an ambient caller, that `targetIsBelowHeldSource(currentSource, …)` never sees. Its remedy is to widen the predicate, or to always-skip-lock.

Different holder, different site, different fix. They are adjacent only in that always-skip-locking the recalc target would close both — which is the plan's own framing (*"always-skip-locking site 2 WOULD close it"*), and is why *"adjacent to but distinct from"* is the accurate phrase. Declining to merge them was correct; merging them would have produced a sixth wrong claim by attributing this gap to a cycle that does not contain it.

---

## Verdict

**CLAIM SOUND** — the row is true as written, `may` is the right strength, the "NOT TESTED" statement is accurate, and the S-1/P-7 separation is real. **Required before this is closed: the fourth sibling at `ReplenishmentFirstTouchInvariantUnitTest.java` `"no stock-unit lock is held"`, which still carries the retired reason.** Comment only; no executable change, no suite implication.
