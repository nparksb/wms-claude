# SBDEV-3637 — scoped review of the fix commit `6bd4f32c`

**Subject:** `6bd4f32c` *"SBDEV-3637: every finding from the code and security review rounds"* (parent `29e43eb1`, already reviewed and approved).
**Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3637`
**Lane:** fix-review. Read-only; no Maven run (suite + PIT numbers consumed from the lane brief, not re-collected).
**Date:** 2026-10-05

**Verdict: APPROVE-WITH-FIXES** — one MEDIUM (a comment-correctness defect in the very block whose history is wrong safety arguments) and two LOW. No code-behaviour change in this commit; no test weakened.

---

## Scope of the change

`git show 6bd4f32c --numstat`:

| File | + | − |
|---|---|---|
| `src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java` | 28 | 9 |
| `src/test/java/net/aim_ai/wms/security/StockunitLockingSearchRouteWithdrawalContextTest.java` (new) | 123 | 0 |
| `src/test/java/net/aim_ai/wms/service/ReplenReassignOnNonReplenishableMoveIT.java` | 4 | 1 |
| `src/test/java/net/aim_ai/wms/service/ReplenishRedirectLockOrderIT.java` | 55 | 0 |
| `src/test/java/net/aim_ai/wms/unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java` | 18 | 0 |

**Every one of the 10 removed lines is a comment or javadoc line** (derivation: `git show 6bd4f32c -U0 | grep '^-' | grep -v '^---'`, all 10 begin `//` or ` * `). `src/main` carries **no executable change** — the predicate body, the `catch (FacadeException)` arm and the finder selection are untouched and do not appear in the diff.

---

## Findings

### [MEDIUM · HIGH confidence] F-1 — M-1's new `recalc + null source` row asserts a transaction-wide absolute that its own justification does not establish, and that `recalculateForItem`'s own sweep falsifies

`ReplenishmentOrderMaintenanceService.java`, the new row:

> `//   recalc + null source -> plain. NO stock-unit lock is held: the source is null either`
> `//     because stockunitId was null or because the locking read found nothing, and FOR UPDATE on`
> `//     a missing row takes no lock. There is no descending edge to avoid.`

The justification establishes only that **this order's source acquisition** took no lock. The claim is about the **transaction**, and the transaction's held-lock set is strictly larger. In-repo evidence, no inference required — `ReplenishorderRepository.java`:

> `// SBDEV-3622: ascending id, so recalculateForItem locks an item's orders in the same order as the`
> `// attributed reserved cut does (two orders on one stock unit could otherwise deadlock).`

That comment exists *because* `recalculateForItem` locks **several orders inside one transaction**. The mechanism:

- `recalculateForItem` is `@Transactional(tenantTransactionManager)` and iterates `findIdsByStateAndItemdataId(...)` calling `recalculateOrder(orderId, ctx)` through a **plain `this.` call** — deliberately, with a long comment saying so. Every order in the sweep therefore shares **one** transaction.
- Each iteration with a non-null `stockunitId` runs `ensureValidSource`'s `Stockunit source = ... stockunitRepository.findByIdForUpdate(order.getStockunitId())`. That row lock is held to the end of the **outer** transaction, not the end of the iteration.
- A later order in the same sweep whose source is null then reaches `redirectSource(order, null, share, true)`. `targetIsBelowHeldSource(null, targetId)` is `false`, so `skipLocked` is `false` and the **plain waiting finder** is used — while the transaction still holds the earlier order's source lock. If that earlier id is above the target's, the acquisition **descends**, which is precisely what the row says cannot happen.

The same accumulation also reaches this method from outside: `recalculateForItem` is `REQUIRED` and **joins** an ambient transaction. Its own loop comment says *"Most acute when recalculateForItem is called from a transactional caller, where the outer tx spans multiple operations beyond just this service"*, and `StockunitService.triggerReplenishmentMaintenance` decides its rethrow with a runtime `TransactionSynchronizationManager.isActualTransactionActive()` for exactly that reason. `reassignOrCancelForMovedStockUnit` takes `stockunitRepository.findByIdForUpdate(movedStock.getId())`, so a caller that moves stock and then triggers maintenance in one transaction reaches recalc with a Stockunit lock held. I did **not** establish a live such caller end-to-end — the clearest candidate, `StockunitService.setLockOnHold`, is `@Transactional` and calls `transferUnitLoadToLocation` before `triggerReplenishmentMaintenance`, but its own guard `if (BigDecimal.ZERO.compareTo(stockUnit.getReservedamount()) < 0) throw` refuses a source that still carries a reservation, which is the usual state of a bound replen source. **The intra-sweep route above needs no such caller and is sufficient on its own.**

Note the asymmetry inside the same comment block: the `move path` row *does* reason about accumulation (*"This transaction has already accumulated locks on earlier stock units of the carrier tree"*). The recalc rows all reason as though the only Stockunit lock in flight is this order's source. The `recalc + ASCENDING` row survives this because it explicitly declines to claim safety (*"NOT because it is 'already deadlock-free' — it is NOT"*); the `null source` row is the only one that asserts one.

**Exposure today is near zero, and that is not the point.** Measured 2026-10-05, two tenants, one instant:

| Tenant | PROCESSABLE orders | `stockunit_id IS NULL` | orphaned `stockunit_id` | max orders per `itemdata_id` |
|---|---|---|---|---|
| `wsl-wineco-uat` | 570 | 0 | 0 | 1 |
| `nywh-hydra-prd` | 1 | 0 | 0 | — |

So no live row reaches the null-source arm, and today no item carries two PROCESSABLE orders. *Derivation: two `execute_sql` calls, `replenishorder LEFT JOIN stockunit`, `state = 300`. Blind spots: two tenants, one instant, and both ShipItEZ prd roles refuse `replenishorder` (per the plan's own note), so this is not a fleet measurement. It bounds nothing about future data — `V2.2.00__base_v2_schema.sql` declares `stockunit_id bigint`, nullable, and `ensureValidSource`'s own comment calls such a row legitimate.*

The defect being reported is **the reason, not the exposure**. This block's stated purpose is to stop the next reader from reaching a wrong conclusion, its history is four successive wrong safety arguments, and the commit message names a fifth as the thing to avoid. A categorical *"NO stock-unit lock is held"* is the fifth.

**Fix** (comment only; no code change, and the code gap behind it is pre-existing and belongs to a proposal, not to this commit):

```
//   recalc + null source -> plain. No lock was taken for THIS order's source — it is null because
//     stockunitId was null or because the locking read found nothing, and FOR UPDATE on a missing
//     row takes no lock, so this acquisition adds no edge off a source of its own.
//     ⚠ This is NOT "the transaction holds no stock-unit lock". recalculateForItem sweeps an item's
//     orders in ONE transaction (plain this. call, deliberately — see the loop) and it JOINS an
//     ambient transaction when one exists, so an earlier order's ensureValidSource lock, or a
//     caller's, is still held here. The predicate compares against THIS order's source only, so a
//     descending edge off one of those is not detected on any recalc row — the same gap as S-1,
//     measured nowhere, and NOT closed by this ticket.
```

---

### [LOW · HIGH confidence] F-2 — M-2's "a looser query" is unreproducible from the comment alone

The new caveat ends:

> `//     edge is common rather than exotic — a looser query returns 448 of 570.`

The plan is precise about what "looser" means — `SBDEV-3637-replenish-redirect-lock-order.md`: *"a looser query — does any lower-id eligible candidate exist at all — returns 448 of 570, 79%"*. The comment drops the definition and names no pointer, so a reader cannot tell whether 448/570 is a different population, a different predicate, or a different instant, and the next person to re-derive it will get a different number.

The caveat is otherwise **accurate and correctly directed**: the plan's own split is `144 no candidate · 97 same-row · 253 ascending · 76 descending` = 570, giving 253 of 329 second-lock acquisitions ascending, and the plan states *"76/253 is an estimate, not a count"* for exactly the stated reason (the query drops the `preferredAreaId` tiebreak). It neither under- nor over-states: it calls the number an estimate, keeps it as the basis of the trade, and forbids re-quoting it as a count.

**Fix** — one clause:

```
//     edge is common rather than exotic — a looser query (does any lower-id ELIGIBLE candidate
//     exist at all, same tenant, same instant) returns 448 of 570. Full derivation and blind
//     spots: plan §D2 "Why not always-skip-locked".
```

---

### [LOW · MEDIUM confidence] F-3 — S-2's javadoc ranks the `ResourceMappings` rail below the new HTTP test, but the rail is strictly stronger against a rename

`StockunitLockingSearchRouteWithdrawalContextTest` asserts 404 at two **literal paths**:

> `private static final String SKIP_LOCKED_ROUTE = "/v3/stockunit/search/findByIdForUpdateSkipLocked";`

If a future edit replaced `@RestResource(exported = false)` with `@RestResource(path = "lockSu")`, the method would be **live** at `/v3/stockunit/search/lockSu` and this test would still be green — it is keyed on the path, not on the method. `SdrLockingSearchNotExportedContextTest`, which walks the live `ResourceMappings` bean, catches that case; the new test cannot. The javadoc calls both existing pins *"indirect"* and says this class *"is the only instrument that measures the effect rather than the declaration"*, which under-sells the rail on the one axis where it dominates.

This is a framing defect, not a coverage hole — the two instruments compose correctly and the javadoc does cite the rail. Rated LOW for that reason.

**Fix** — append to the `<ul>` entry for `SdrLockingSearchNotExportedContextTest`:

```
 *       ⚠ And it is STRICTLY STRONGER than this class on one axis: this class asserts 404 at a
 *       literal path, so a re-export under a DIFFERENT rel would leave it green while the method
 *       is live. The rail walks the mapping bean and sees that. The two compose; neither replaces
 *       the other.
```

---

## Verification of each claimed fix

| | Claim | Verdict |
|---|---|---|
| **M-1** | both new rows TRUE | **`null target` row: TRUE.** *"A source lock MAY be held here — this row does NOT share the 'no lock is held' reason above"* is correct, and the conclusion follows: `candidate.stockUnitId == null` binds the finder to a null id, which matches no row and takes no lock, so no edge either way; the outcome is `NO_CANDIDATE`, unchanged. **`null source` row: FALSE as written — see F-1.** |
| **M-2** | caveat neither under- nor over-states | **TRUE**, modulo F-2. Reconciled against the plan's `144/97/253/76 = 570` split and its own "estimate, not a count" wording. |
| **M-3 (a)** | assertion reachable on the row it guards | **TRUE.** On `move-null-target`, `skipLocked` is unconditionally true, the unstubbed finder returns empty, `if (!skipLocked)` is false, and control reaches `if (candidate.stockUnitId == null \|\| !stockunitRepository.existsById(...))`. Dropping the short-circuit makes `existsById(null)` execute, and `verify(..., never())` fails. Matches the PIT evidence (`NegateConditionals` on the guard line now KILLED). |
| **M-3 (b)** | only `move-null-target` can kill it | **TRUE.** The two rows with `targetId == null` are `("null-target", true, 10L, null, false)` and `("move-null-target", false, 10L, null, true)`. On `null-target`, `skipLocked = !true \|\| targetIsBelowHeldSource(source, null)` = `false`, so the plain finder runs and `if (!skipLocked)` returns `NO_CANDIDATE` **before** `existsById` is reachable at all — the mutant cannot change the outcome there. |
| **M-3 (c)** | `any()` is safe | **TRUE.** `CrudRepository.existsById(ID id)` takes a reference `Long`; `any()` supplies `null` with no unboxing. This is not the `never()`/primitive trap the sibling rows avoid, and the inline ⚠ says so. |
| **M-3 (d)** | not vacuous where skipped | **TRUE and honestly stated.** The assertion is inside `if (targetId == null)`, so 8 of 10 rows skip it by construction — that is scoping, not vacuity. The comment volunteers that the `null-target` copy *is* true either way and gives the reason for keeping it (a future edit making the recalc arm fall through would be caught here). |
| **M-4** | appender detached in a `finally` | **TRUE.** `detach(captured)` is the first statement of the `finally`, ahead of `pool.shutdownNow()`. The only statements between `captureServiceLog()` and `try {` are two local declarations, which cannot throw — so the attach sitting outside the `try` is **not** a leak. Checked and dismissed; no finding. |
| **M-4** | token match cannot count `REDIRECT_NO_HEAL` | **TRUE.** The filter is `m.contains("SBDEV-3637 REDIRECT_CONTENDED")`; the other literal is `"SBDEV-3637 REDIRECT_NO_HEAL replenishOrder={} state={} — ..."`. The two are disjoint as substrings, and the inline ⚠ pins the exact token against a future loosening. The appender is attached to the `ReplenishmentOrderMaintenanceService` logger, not ROOT, so no other class can inflate the count. |
| **M-4** | `hasSize(2)` right rather than `>=2` | **TRUE, and `>=2` would be weaker.** `seedInvertedPair()` puts exactly one Stockunit on each unit load (`stockunit(S1, UL_1, …)`, `stockunit(S2, UL_2, …)`), so each leg's `transferUnitLoadToLocation` drives exactly one `reassignOrCancelForMovedStockUnit`, which can log `REDIRECT_CONTENDED` at most once. Max one line per leg ⟹ `hasSize(2)` ⟺ both legs contended, which is what the assertion claims. *Derivation that the move path cannot also reach the recalc sweep (which could add lines): `git grep -n "recalculateForItem\|triggerReplenishmentMaintenance" -- src/main/java` returns call sites only in `ReplenishOrderJob`, `FixLocationAssignmentService` and `StockunitService`, and `UnitloadBusinessService` references none of those (control: it has 13 `private final` deps, so the grep is not scanning an empty file). Blind spot: one hop out of `UnitloadBusinessService`, not a full call-graph walk.* |
| **M-4** | thread safety of the capture | **SOUND, for a reason the javadoc does not name.** The javadoc justifies the **read** (both `Future.get()` returned, appender detached, `Future.get()` is a happens-before edge) and that is correct. It is silent on the **write** side — two legs appending concurrently to `ListAppender.list`, a plain `ArrayList`. That is safe because `ch.qos.logback.core.AppenderBase.doAppend` is `public synchronized void doAppend(E)` — verified with `javap` against `logback-core-1.5.22.jar`, the version on this build's classpath. No change needed; recorded so a future reader does not "discover" the hazard and bolt on a redundant lock. |
| **S-2** | control genuinely exported | **TRUE.** `StockunitRepository` is `@RepositoryRestResource(collectionResourceRel = "stockunit", path = "stockunit")`, and `findByUnitloadId` carries `@RestResource(path = "findByUnitloadId", rel = "findByUnitloadId")` with **no** `exported = false` — checked by reading the annotation lines directly, not by grepping for `exported = false`, which in this repo matches at method level and inverts the verdict. It returns `List<Stockunit>`, so SDR answers 200 with an empty `_embedded` rather than the 404 an `Optional` finder would give — the trap the javadoc names. A blanket-404 context therefore cannot pass this class. |
| **S-2** | exercises HTTP routing, not the annotation | **TRUE.** Three `mockMvc.perform(get(...))` calls with the control asserted first. `SdrGuardMode.OFF` plus an allow-all `AccessService` means no status can come from the gating programme. Both subjects (`findByIdForUpdateSkipLocked`, `findByIdForUpdate`) carry `@RestResource(exported = false)` at `StockunitRepository`, and `Stockunit` is listed in `SdrUncalledSurfaceNotExportedContextTest.MUST_REMAIN_EXPORTED`, so the surface really is live and the withdrawal really is load-bearing. Residual: F-3. |
| **S-2** | context-cache claim | **TRUE.** `ReportPaginationSearchWithdrawalContextTest` and `SdrOmittedPrimitiveParamSearchContextTest` both `extends BaseControllerIntegrationTest` with exactly `@MockitoBean SdrGuardModeProvider modeProvider` and `@MockitoBean AccessService accessService` — identical to the new class, so the cache key matches and no new context is built. All four cited sibling classes exist on disk. |
| **L-1** | bare line numbers → quoted snippets | **TRUE and verbatim.** `git grep` finds both quoted strings as exact source lines: `sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId)` at `StockunitBusinessService.java:202` and `destinationStockUnit = stockunitRepository.findByIdForUpdate(dstSuId)` at `:277` — the same two acquisitions the removed `(:202)` / `(:277)` pointed at. A quoted snippet that did not match would be worse than a line number; these match. |
| **L-2** | "runs through" → "cycle closes through" | **TRUE.** Both residual rows now say *"cycle CLOSES THROUGH this acquisition"* / *"cycle closes through the SOURCE acquisition in `ensureValidSource`"`, and residual 1 adds the disambiguator *"(it never executes redirectSource itself; recalc's wait edge at this line is one arm of the ABBA)"*, which is what the old call-path reading got wrong. |
| **L-3** | documents the absent guard; did NOT add it | **TRUE on both halves.** The new javadoc paragraph argues the guard would be unreachable and therefore untestable, and the body is unchanged — `return currentSource != null && targetId != null && currentSource.getId() > targetId;` does not appear in the diff at all. |
| **L-4** | mutation header no longer over-claims | **TRUE.** The header now reads *"every test killed by at least one mutant; see the split row below for one mutant added by SBDEV-3637 and NOT covered by that measurement"* and states why (*"The blanket claim dates the measurement"*). The referenced split row exists below it and names the uncovered leg: *"always `CONTENDED`"*, which is M-8 in the plan. |

---

## Hard invariants

| # | Invariant | Verdict |
|---|---|---|
| 1 | `targetIsBelowHeldSource` — name, javadoc and body state the same comparison; body is `currentSource.getId() > targetId` | **HOLDS.** Name says *below held source*; javadoc says *"returns true **exactly when this acquisition would DESCEND**"*; body is `currentSource.getId() > targetId`. The body is untouched by this commit. |
| 2 | `catch (FacadeException)` maps to `NO_CANDIDATE`, never `CONTENDED` | **HOLDS.** The arm still ends `return RedirectOutcome.NO_CANDIDATE;` under the Fix C comment *"NO_CANDIDATE, never CONTENDED"*. Not in the diff. |
| 3 | Nothing claims the move path is deadlock-free; nothing asserts all Stockunit locks are id-ordered; both residuals named separately with their acquisitions | **HOLDS.** The scope limit is intact — *"It does NOT make the move path deadlock-free — processTransfer iterates findByUnitloadId with no ORDER BY"*. Residual 1 is pinned to *this* acquisition and still carries *"THIS EDGE CARRIES A LIVE SU<->SU ABBA"*; residual 2 is pinned to `ensureValidSource`'s source acquisition and *"Nothing done at THIS line can close it"*. No global ordering claim anywhere in the block. ⚠ F-1 is the one sentence in the block that reads as a safety claim it cannot support. |
| 4 | No test weakened, `@Disabled`, deleted or renumbered; every removed line accounted for | **HOLDS.** 10 removed lines, all comment/javadoc, enumerated above. `git show 6bd4f32c \| grep -E "^\+.*(@Disabled\|@Ignore\|assumeTrue)"` → empty; `grep -E "^-.*(assert\|verify)"` → empty. Test files are additive only (123/4/55/18 added, 1 removed and it is a javadoc line). |
| 5 | `wms.tenant.lock-timeout-ms` untouched | **HOLDS.** Absent from the diff. Control: `git grep -c "lock-timeout-ms" -- src` returns hits in 5+ files, so the instrument finds the token. |

---

## Consistency with the evidence already gathered

Nothing in the diff contradicts the supplied numbers, and two of them corroborate it:

- **Suite 7811/0F/1S + 627/0F/31S, 122 IT classes** vs the 7791/3F and 624/2F, 121 IT baseline. The deltas are consistent with this commit's additions: one new `*ContextTest` class (surefire, +1 test in the unit lane and +1 in the parameterized class's assertion count rather than its row count), and the new `ReplenishRedirectLockOrderIT` assertions are inside an existing method, so the IT-class count moves by the one new class in the earlier commit's lane, not by this one. The 3F/2F gate reds are gone, which is what a landed implementation should produce.
- **PIT, 236 mutations, M-13 guard line `NegateConditionals` now KILLED** — this is exactly what M-3's re-pin predicts and it could not have come from the old "no exception" assertion, for the reason the new comment gives (the mock returns `false` for `existsById(null)` instead of tripping `SimpleJpaRepository`'s `Assert.notNull`).
- **`ConditionalsBoundary` SURVIVED on `targetIsBelowHeldSource`'s line, with `NegateConditionals` ×3 and `BooleanTrueReturnVals` KILLED** — consistent with the javadoc's own standing claim that `>` → `>=` is EQUIVALENT because `sourceId == targetId` never reaches the method (SBDEV-3618 Fix E returns from both arms above). The surviving mutant is the documented M-6b and the sign is pinned by the killed ones.

---

## Positive observations

- **The M-1 correction is the right shape even though one half is still wrong.** Splitting one row that carried one reason for two cases is the correct move, and the `null target` half is now stated with the precision the block needs — including the explicit *"this row does NOT share the 'no lock is held' reason above"*, which inoculates against a future re-merge.
- **M-3 is the strongest item in the commit.** It found that a mutation row's *stated killer could never have worked* — a mock cannot reproduce a `SimpleJpaRepository` assertion — and re-pinned on the one thing that can observe the mutant. That is the failure mode where a green suite proves nothing, caught without a code change, and the PIT numbers confirm it.
- **L-1 replaced bare cross-file line numbers with snippets that match verbatim**, and gave the reason (drift inside *this* block points at the wrong acquisition). The snippets check out at `:202` and `:277`.
- **S-2's control is the right control**, and the javadoc explains why an `Optional`-returning sibling would have been the wrong one — SDR answers 404 on an empty `Optional` search, which would have reported "route missing" for an unrelated reason.
- **M-4's assertion message tells the reader what to do with a red** ("RE-RUN before investigating the assertions below"), which is the difference between an attributable flake and an afternoon spent on a phantom lock-ordering regression.
- **L-4 is an unusually honest retraction**: a blanket "every test killed" header that was true when measured, narrowed rather than deleted, with the dating argument stated.

---

## Recommendation

**APPROVE-WITH-FIXES.** Apply F-1 (required — it is a false safety claim in the block whose entire history is false safety claims), then F-2 and F-3 (both one-sentence comment edits; this repo fixes Lows in the same pass). None of the three touches executable code, so no re-run of the suite or PIT is implied by them.

Out of scope and correctly dispatched: the recalc path's predicate compares only against **this order's** source, so a descending edge off a lock inherited from a sibling order in the same `recalculateForItem` sweep — or from an ambient caller — is detected nowhere. That is a code gap, pre-existing in `29e43eb1`, adjacent to but distinct from S-1/P-7 (which is about `transferStockToUnitLoad`'s own two acquisitions). It is named in no plan section I could find and is worth a proposal on the ticket; F-1's comment fix is what stops the next reader believing it has been handled.
