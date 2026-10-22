# SBDEV-3637 — ralplan round 2, ARCHITECT RE-REVIEW of r2

**Reviewed:** `sbdocs/1-Projects/wms2/plan/SBDEV-3637-replenish-redirect-lock-order.md` (r2, 668 lines).
**My r1 review:** `SBDEV-3637-evidence/review-architect.md` (SOUND-WITH-CHANGES, A-1 … A-10).
**Code read:** `.claude/worktrees/wms2-api/SBDEV-3637-readonly` @ `ec42f43a` (*"Merge pull request #453 from
SiteBossInc/feature/SBDEV-2624-sku-rename-in-place"*), detached, clean (`git status --porcelain` empty).
Read-only: no `mvn`, no writes, no HEAD change, no stash.
**Scope:** disposition of A-1 … A-10 verified *in substance against the code*, not by the presence of an
`[A-N]` tag; plus a defect sweep of the ~118 lines r2 added.

**VERDICT UP FRONT: SOUND-WITH-CHANGES.** Eight of ten findings are fully cleared, and the two the brief
flagged as highest-risk — A-1 (the predicate sign) and A-3 (the equivalent mutant) — are cleared correctly,
with the body still computing the right comparison. **A-7 is not cleared.** r2 deleted the false
justification and replaced it, in the same place, for the same conclusion, with a *different* false
sentence that its own counterexample two paragraphs above refutes. A-5 is partially cleared: the guard is
right, the reason given for it is false against today's code (my r1 error, adopted and propagated into
AC-3 and M-11), and the same null hazard is left unguarded four lines down in the new `existsById` call.

---

## 1. Disposition of A-1 … A-10

### A-1 — the branch predicate's name / javadoc / body. **CLEARED.** (was HIGH)

All three artifacts now state the same comparison, **and the body is still the correct one.** This was the
failure mode worth checking hardest — a revision that "fixed" the name by flipping the body — and it did
not happen.

- **Name:** `targetIsBelowHeldSource(Stockunit currentSource, Long targetId)`. Target below held source ⇒
  `target < source` ⇒ `source > target`.
- **Javadoc:** *"skip-locked exactly when this acquisition would DESCEND — that is, when this transaction
  already holds a lock on a stock unit whose id is HIGHER than the target's. Returns true when
  `currentSource`'s id is above `targetId`."* Same comparison.
- **Body:** `return currentSource != null && targetId != null && currentSource.getId() > targetId;` Same
  comparison.

Correctness of the retained body, re-derived rather than assumed: the call site is
`boolean skipLocked = !recalcPath || targetIsBelowHeldSource(currentSource, candidate.stockUnitId);`.
Holding `S_hi` (site 1, the source) and acquiring `T_lo` is the descending acquisition, and that is exactly
the case the body returns `true` for. Cross-checked against the r2 case table rows 2 and 3
(*"`targetId < sourceId` (descending) | **skip-locked**"* / *"`targetId > sourceId` (ascending) | **plain**"*)
— table, expression and helper agree in all four combinations I enumerated (the expression has exactly two
inputs, so four is the whole product; blind spot: this grades the expression, not what reaches it, which is
the placement rule's job).

The javadoc also now carries the `>` vs `>=`/`<`/`compareTo`/`Objects.equals` prohibition and the
`ReplenishorderService` precedent, which is where the next reader will look. Good.

### A-2 — `CONTENDED`'s "nothing was written" invariant. **CLEARED.** (was MEDIUM)

r2's enum javadoc rescopes to *"redirectSource itself wrote nothing, reserved nothing, and did not mark the
transaction rollback-only"* and explicitly refuses the wider reading: *"It is NOT a claim that the
transaction is clean."* Both named exceptions verified on today's code:

- `ReplenishmentOrderMaintenanceService.java` · `alignDestination` —
  `order.setDestinationId(assignment.getAssignedlocationId()); replenishorderRepository.save(order);` followed
  by `return false;`, and `return false;` again on the other arm; its caller is
  `if (alignDestination(order, assignment)) { return; }` immediately above `Sourced sourced = ensureValidSource(order, ctx);`.
  So the recalc path does reach `redirectSource` with a pending write. ✅
- The move path's pending unit-load relocation is required to commit by D1. ✅

AC-5 carries the same scoping (*"Scoped to the method, not to the transaction `[A-2]`"*), and horizontal-
scalability row 6 now says *"(AC-5's scoped form — *not* 'the transaction wrote nothing')"*. R-4's mitigation
now protects a true claim.

### A-3 — M-6 was an equivalent mutant. **CLEARED**, with one executor-facing note.

M-6 is now *"invert the comparison: `>` → `<`"*. Reachable and attributably killable, re-derived:
under the mutant, U-param `asc` (source 10, target 11) flips `false → true`, so the skip-locked finder is
called where the row demands plain, and U-param `desc` (11, 10) flips `true → false`. Each row asserts both
halves (*"which finder was called **and** `never()` on the other"*), so each failure names a finder. ✅

M-6b's equivalence reasoning is **correct**, and I re-derived it rather than ratifying it. `>` and `>=`
differ only at `sourceId == targetId`; that case returns from the SBDEV-3618 Fix E block above:

```java
if (currentSource != null && Objects.equals(candidate.stockUnitId, currentSource.getId())) {
    if (!recalcPath) { return false; }
    ... replenishorderRepository.save(order);
    return true;
}
```

Both arms return. Between that block and `Stockunit targetStock = stockunitRepository.findByIdForUpdate(...)`
there are exactly two statements — the `newRequested` computation and `if (newRequested.compareTo(BigDecimal.ZERO) <= 0) { return false; }`.
Derivation: I read the whole region. Blind spot: none for this clause; it is six statements and all were
read. So no equal-id pair reaches the predicate on either path, and the plan's line *"No fixture can rescue
M-6b — no equal-id row can reach the predicate"* is right.

**Note for the executor, not a blocking finding.** PIT does not emit `>` → `<`. Its two relevant mutators
are `NEGATE_CONDITIONALS` (`>` → `<=`) and `CONDITIONALS_BOUNDARY` (`>` → `>=`). `<=` is behaviourally
identical to `<` here for exactly the reason M-6b is equivalent, so M-6 **is** killable as PIT actually
emits it — but the PIT report will name `NEGATE_CONDITIONALS` and `CONDITIONALS_BOUNDARY`, not the plan's
wording. Add the mutator names to the M-6 / M-6b rows so the survivor is matched to the right row; a
survivor filed against the wrong row is how an equivalent mutant gets "repaired".

### A-4 — the five-row / four-case table, and (move, null source). **CLEARED.** (was MEDIUM)

The table is re-keyed on `recalcPath` first, has four rows, and resolves the contradiction explicitly:
*"⚠ **(move, null source) is reachable** … and `!recalcPath` short-circuits first, so skip-locked wins."*
Reachability re-verified: `reassignOrCancelForMovedStockUnit` does
`Stockunit lockedSource = stockunitRepository.findByIdForUpdate(movedStock.getId()).orElse(null);` then
`if (!redirectSource(order, lockedSource, share, false))` — no null guard between them. ✅

Consistency of the three artifacts the brief asked about, checked pairwise:
helper body (`currentSource != null && …` ⇒ `false` on null source) → call site (`!recalcPath` ⇒ `true`) →
**skip-locked**; case table row 1 says skip-locked; U-param carries the row
*"**move-null-source** | false | `null` | 11 | **skip-locked** `[A-4]`"*. All three agree. ✅

### A-5 — `// both non-null here`. **PARTIALLY CLEARED.** (was LOW; the residue is now MEDIUM)

The guard itself is right and is in the body: `targetId != null &&`. ✅ **The reason given for it is false,
and I am the source of the error** — my r1 review asserted that *"today a null id reaches
`findByIdForUpdate(null)` and raises a named Spring Data `InvalidDataAccessApiUsageException`"*, and r2
adopted that verbatim into three places. It is wrong against `ec42f43a`:

`repo/jpa/StockunitRepository.java` declares the finder as a `@Query` method, not a derived one —
`@Query("SELECT s FROM Stockunit s WHERE s.id = :id")` over
`Optional<Stockunit> findByIdForUpdate(@Param("id") Long id);`. A null argument binds null; `s.id = null` is
never true; the query returns zero rows and the method returns `Optional.empty()`. No
`InvalidDataAccessApiUsageException` is raised — that exception belongs to the **derived** `findById(null)`
shape, which this is not.

Consequences, each of which is a sentence an implementer will act on:
- §4 Fix B `[A-5/L4]`: *"strictly worse than today's named `InvalidDataAccessApiUsageException`, which the
  guard preserves by falling through to the plain finder"* — the guard does preserve today's behaviour, but
  today's behaviour is `Optional.empty()` → `NO_CANDIDATE` → the caller cancels, not a named exception.
- **AC-3**: *"A null `candidate.stockUnitId` likewise, and raises the named
  `InvalidDataAccessApiUsageException` rather than a bare NPE"* — unsatisfiable as written.
- **M-11**: *"expect the named `InvalidDataAccessApiUsageException`, **not** a bare `NullPointerException`"* —
  the unmutated code raises neither, so the assertion cannot be written. The mutant is still good; its
  expected-green side must become *"no exception; outcome is `NO_CANDIDATE`"*, and the mutant then goes red
  with an NPE. That is still an attributable kill.

**And the same hazard is unguarded four lines down, in code r2 added.** On the move path `skipLocked` is
unconditionally true, so a null `candidate.stockUnitId` now reaches
`if (!stockunitRepository.existsById(candidate.stockUnitId))`. `StockunitRepository extends
PagingAndSortingRepository<Stockunit, Long>, CrudRepository<Stockunit, Long>`, so that is
`CrudRepository.existsById`, whose contract throws `IllegalArgumentException` on a null id (Spring Data's
`SimpleJpaRepository.existsById` opens with `Assert.notNull(id, ID_MUST_NOT_BE_NULL)`). So the bare
unchecked exception the `targetId != null` guard exists to prevent is reintroduced one branch later, on the
path where the guard cannot fire. Either guard both, or drop the `toLong`-can-return-null premise
consistently — the plan cannot rely on it in Fix B and ignore it in Fix C.

### A-6 — self-heal only at `state == PROCESSABLE`. **CLEARED.** (was MEDIUM)

r2 states the premise, carries the measurement **with** its blind spots (*"two tenants at one instant; both
ShipItEZ prd roles refuse `replenishorder`; and the grep cannot see a native `UPDATE replenishorder SET
state`"*), takes the cheap guard (`REDIRECT_CONTENDED_NO_HEAL`) over the narrowing one and says why
(narrowing *"would re-introduce the cancel-on-contention behaviour D1 just removed"*), and pins it with U-K
and M-10. The *"codebase does not treat it as impossible"* claim is verified —
`ReplenishmentOrderMaintenanceServiceReassignTest` uses `Replenishorder order = orderAt(WmsConstants.State.RESERVED);`
at eight sites, so U-K has an existing fixture shape to copy. ✅ See N-2 for a flaw in the *token*, not in
the finding's disposition.

### A-7 — *"already globally ordered, therefore already deadlock-free"*. **NOT CLEARED.** (was MEDIUM; now **HIGH**)

Half of what I asked for landed. The false sentence is gone, and both counterexamples are named, both
correctly against the code:

- `StockunitBusinessService.transferStockToUnitLoad` —
  `sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId)` (`:202`) and
  `destinationStockUnit = stockunitRepository.findByIdForUpdate(dstSuId)` (`:277`), with the destination
  chosen by `if (stockunit.getItemdataId().equals(sourceStockunit.getItemdataId()))`, and no id comparison
  anywhere between them. Verified by reading `:175`–`:290` continuously. ✅
- `ReplenishorderService.cancelReplenishmentOrder` —
  `Optional<Stockunit> sourceStockOptional = stockunitRepository.findByIdForUpdate(replenishOrder.getStockunitId());`
  under the in-code note *"The order row is not locked first; that SU-then-order order is a known, bounded
  residual"*, then `replenishmentOrderMaintenanceService.markCancelled(replenishOrder);`. ✅

**But the replacement justification is itself false, and r2's own counterexample refutes it.** Verbatim:

> The actual reason to keep waiting is narrower: **the ascending edge agrees with the counterparties that
> *are* id-ordered …, and converting it to skip-locked would buy nothing against either residual above,
> **because neither of those cycles runs through two stock units.**

Two paragraphs above, the plan describes the first residual like this:

> Counterexample, both sides plain waits, both *after* this fix: recalc holds `S_low` (site 1) and waits on
> `S_high` (site 2, ascending, plain); `transferStockToUnitLoad` holds `S_high` (`:202`) and waits on
> `S_low` (`:277`). ABBA, `40P01`, unchanged by this ticket.

That cycle runs through **two stock units** and nothing else. And converting the ascending edge to
skip-locked would not "buy nothing" against it — it would **close it**: it deletes recalc's wait edge
`S_low → S_high`, so recalc returns `CONTENDED` and the cycle cannot form. Both halves of the clause are
false for that residual. They are true for the `cancelReplenishmentOrder` residual, which genuinely runs
through the order row and which skip-locking an SU could not close; r2 collapses the two and asserts the
weaker, uniform claim over both.

This is the same defect A-7 named, in the same sentence slot, now pointing the other way: r1 argued the
ascending edge was safe when it is not; r2 argues always-skip-locked would buy nothing when against one of
its two named residuals it would buy the whole cycle. Both errors favour the chosen design.

**The design can still be defended, so this is a rewrite, not a redesign.** The defensible form is the
measurement plus a split verdict, roughly:

> The ascending edge keeps waiting because a spurious defer there costs a full recalc cadence and 77% of
> second-lock acquisitions sit on it. It is **not** deadlock-free. Two residual cycles cross it, and they
> are different in kind: `cancelReplenishmentOrder`'s runs through the **order row**, so skip-locking a
> stock unit could not close it and doing so would be invariant-over-instance inverted;
> `transferStockToUnitLoad`'s runs through **two stock units** and skip-locking this edge *would* close it
> — we decline to, because the correct site for that fix is `transferStockToUnitLoad` itself, where both
> ids are known before either lock and an ascending acquisition is available with no sequencing obstacle
> (P-7). Until P-7 lands, this edge carries a live SU↔SU ABBA.

Three places then have to move with it:
1. the Fix B paragraph (above);
2. the **Fix F code comment**, which §4 instructs to carry *"the residuals that remain open"* — it must
   carry the split, or the false equivalence lands in `src/main` at the exact site whose history is three
   successive wrong safety arguments;
3. **P-7's ranking.** §10 currently says *"⚠ Ranked second only to P-1, and above it if the §1 `stats_reset`
   re-measurement shows a short window."* On the honest reading P-7 is not an adjacent cleanup — it is the
   thing that makes the ascending edge's continued waiting defensible, and it should rank **first**, with a
   sentence saying 3637 knowingly ships with that cycle open.

Nothing else in the plan depends on the false clause: AC-8 and P-7 already describe `transferStockToUnitLoad`
correctly (*"a live counterparty to the ascending edge this fix leaves waiting"*), so §4 is the single
passage out of step with the rest of the document.

### A-8 — IT-2's raw JDBC holder. **CLEARED.** (was LOW)

§7.1 now binds it explicitly: *"(a) the same `TransactionTemplate(tenantTransactionManager)` holder the
IT-1 choreography already uses, or (b) a `java.sql.Connection` … with **`setAutoCommit(false)`** … **rolled
back and closed in a `finally`**. (a) is preferred"*, with the failure named (*"a green that proves the
opposite of what it claims"*). IT-2's own paragraph repeats the binding. ✅

### A-9 — D2's expiry condition. **CLEARED.** (was LOW)

D2 carries both halves: *"D2 settled the edge DISTRIBUTION, not the contention RATE"* with the
`P(ascending) × P(target locked at that instant)` decomposition and the reason the second factor is
unmeasurable pre-fix, and *"**EXPIRY: if P-3 lands, collapse this branch to always-skip-locked**"* routed
into the Fix F comment. §4 Fix B carries the same ⚠ inline. **The brief asked me to confirm the recording of
the open tension is accurate — it is.** r2 records it as unresolved with a named expiry condition rather
than as settled, which is what §3 of my r1 asked for. ✅

### A-10 — five name-coupled `verify()` pins → one parameterized test. **CLEARED.** (was LOW/quality)

U-param, eight rows, each asserting *"which finder was called **and** `never()` on the other"*, with the
`any()`-unboxing trap named and boundary rows on both sides of `>`. ✅

---

## 2. Did the revision introduce anything new and wrong?

Swept the material r2 added: §0 rows 11–17 and the "three, not four" paragraph, the reworked Fix B case
table, the `existsById` disambiguation, the `REDIRECT_CONTENDED_NO_HEAL` WARN, U-J/U-K, M-8…M-11, the §5
`AbstractReplenishRedirectPgFixture` decision, and the §7.1 template table. Four findings, none of which
touches the architecture.

### N-1 (MEDIUM) — carried in A-5: `InvalidDataAccessApiUsageException` ×3, and the unguarded `existsById(null)`

See A-5 above. Three sentences to correct, one guard to add.

### N-2 (LOW) — `REDIRECT_CONTENDED_NO_HEAL` is not greppable apart from `REDIRECT_CONTENDED`

The second token has the first as a **prefix**. The WARN token is, by the plan's own statement, the only
production instrument this change ships (*"nothing scrapes Prometheus in this deployment, so a log token
beats a metric"*), and two places now mis-handle the collision:

- §7.6 *"Defer is observable"* tells the operator to `grep the app log for 'SBDEV-3637 REDIRECT_CONTENDED'`
  and expect *"zero or a handful of lines"*. That pattern matches the NO_HEAL line too, so every no-heal
  event is counted twice and the no-heal row's expected **zero** is invisible inside the other row's
  "handful".
- **U-I** asserts *"the Fix E WARN is emitted exactly once per `CONTENDED`"*. On a non-PROCESSABLE order two
  lines are emitted, and a substring-based log-capture assertion sees two. U-I must assert on the exact
  token boundary, or the tokens must not nest.

Cheapest fix: rename the second to something disjoint (`SBDEV-3637 REDIRECT_NO_HEAL`), and the §7.6 and U-I
rows stop needing a boundary caveat at all.

### N-3 (LOW) — AC-3 cites a U-param row that §7.4 does not define

AC-3 grades itself on *"U-param rows `null-source`, `null-target`"*; §7.4's table has eight rows and
`null-target` is not among them. M-11 refers to *"the null-target row **added** to U-param"*, i.e. it is an
instruction rather than a definition. Add the row to the table with its expected outcome (which, per A-5, is
`NO_CANDIDATE` without an exception), so the AC grades against something that exists.

### N-4 — `existsById`'s auto-flush: **checked, NOT a finding**

`SimpleJpaRepository.existsById` runs a JPQL count, so it is an auto-flush point over the `stockunit` query
space, and on the move path the transaction can hold dirty `Stockunit` rows from earlier iterations of
`processTransfer`'s per-SU loop — a new early flush would take their row locks sooner, which on a
lock-ordering ticket would matter. It does not, because the hazard is already incurred unconditionally a few
lines above: `StockunitRepository.getAvailableReplenishmentSources` is `nativeQuery = true` (verified:
`"ORDER BY su.amount DESC", nativeQuery = true)` directly above its declaration), and Hibernate flushes
fully before a native query with undeclared synchronized spaces. `existsById` adds no flush point that the
candidate query has not already forced. No change needed; recorded so the sweep is visible.

---

## 3. Is the `existsById` disambiguation sound?

**Yes, and its residual race errs in the safe direction — which the plan should say, because it currently
only says the race exists.**

The plan is correct that it is racy and that it *"narrows the window, it does not close it."* What it does
not say is that the two race outcomes are not symmetric, and that asymmetry is the reason the construct is
acceptable:

| state of the target row | `existsById` | outcome | correct? |
|---|---|---|---|
| locked by another live tx, not deleted | `true` | CONTENDED → defer | ✅ |
| deleted and **committed** before the skip-locked read | `false` | NO_CANDIDATE → cancel | ✅ |
| delete **uncommitted** at the instant of the check | `true` (READ COMMITTED does not see it) | CONTENDED → defer | ⚠ should have been NO_CANDIDATE |
| deleted and committed **after** the check | `true` | CONTENDED → defer | ⚠ should have been NO_CANDIDATE |

Derivation: `existsById` is a non-locking `SELECT` under the tenant transaction's READ COMMITTED isolation,
so it sees committed state as of statement start. Blind spot: I did not test this; it is derived from the
isolation level and from `SimpleJpaRepository.existsById`'s query form, and I did not check whether any
tenant runs at REPEATABLE READ — at REPEATABLE READ the check would read the transaction's snapshot and
could return `true` for a row deleted and committed before the transaction began, widening the same
benign-direction error.

**So a wrong answer causes a defer that should have been a cancel — never a cancel that should have been a
defer.** That matters for the brief's question: the dangerous direction (cancelling a live order because a
locked row looked absent) is structurally unreachable, because the only way `existsById` returns `false` is
that the row is genuinely committed-gone. And the benign direction self-heals at `PROCESSABLE` (the next
tick's candidate query re-runs from DB state and the vanished row is no longer a candidate → `NO_CANDIDATE`
→ cancel) — at non-`PROCESSABLE` it does not, which is precisely what A-6's `NO_HEAL` WARN now covers.

One sentence in Fix C recording that asymmetry would turn the construct from "racy but low-probability" into
"racy in one direction only, and that direction is the recoverable one." Worth adding; not blocking.

---

## 4. Is (move, null-source) consistent across the three artifacts?

**Yes** — case table row 1, the helper body + call site, and U-param `move-null-source` all resolve it to
skip-locked, and the reachability claim is verified against
`reassignOrCancelForMovedStockUnit`'s unguarded `redirectSource(order, lockedSource, share, false)`. Detail
under A-4.

---

## 5. Does §0 account for all 17 sites?

**Yes.** I re-ran the derivation myself rather than reading the table's own count:
`git grep -n "stockunitRepository\.findByIdForUpdate" -- src/main/java` returns 17 lines across 7 files, and
every one maps to exactly one §0 row — `CustomerorderPositionService:148`→17; `PickingorderBusinessService:566`→17's
sibling row; `ReplenishmentOrderMaintenanceService:256/424/579`→3/1/2; `ReplenishorderService:259,260,262,264`→4–7
and `:338`→8; `StockunitBusinessService:202,277,472,509`→11–14; `StockunitService:1060`→15;
`MobileReplenishService:218`→10 and `:775`→9. No row is unmatched and no grep line is unaccounted for.
Blind spots are the plan's own declared (a)–(c) blind spots, which I did not independently extend.

Four verdicts spot-checked against the code, including both the brief named:

| row | verdict | my check |
|---|---|---|
| 11–12 `StockunitBusinessService.transferStockToUnitLoad` | **no — RESIDUAL (H2)**, same defect shape, → P-7 | **Correct, and understated in §4.** Read `:175`–`:290` continuously: src SU `:202`, then src UL, src Location, dst UL, dst SU `:277`, dst Location — role order, no id comparison, destination selected by `stockunit.getItemdataId().equals(sourceStockunit.getItemdataId())`. The *"fixing it here would be invariant-over-instance done wrong"* reasoning is sound. See A-7 for why §4 must stop treating it as inert |
| 16 `CustomerorderPositionService:148` | **no** — N SUs per tx, loop order unspecified, off-axis (pick sources of one customer order) | **Correct.** `for (PickingorderPosition pickingPosition : pickingPositions)` → `findByIdForUpdate(pickingPosition.getPickfromstockunitId())` → `changeReservedAmount(..., negate(), ...)`. Loop order comes from a query with no `ORDER BY` in view. Verdict is defensible *because* AC-8's rule explicitly re-admits it to the residual set rather than dismissing it |
| 17 `PickingorderBusinessService:566` | **no** — same shape | **Correct.** Nested `for` over `findByCustomerorderpositionId`, SU lock inside, preceded by `pickingorderRepository.findByIdForUpdate(...)` under the in-code note *"This is the Pickingorder acquisition that has to precede the Stockunit one below"* — so it is PO-before-SU, which is the canonical order, and the SU accumulation is the only unordered part. The row's "same reason" is right |
| 8 `ReplenishorderService.cancelReplenishmentOrder` | **no — RESIDUAL**, live counterparty to the ascending edge | **Correct.** SU lock, then `HeldShareRelease.release(...)`, then `markCancelled(replenishOrder)` writing the order row. The in-code SBDEV-3621 note is quoted accurately |

Two adjacent r2 claims also check out: `switchSourceToUnitLoad` is genuinely absent (`git grep` exits 1 with
no output; positive control in the same scan — `git grep -c "redirectSource"` returns counts across 10 files
including `ReplenishorderService.java:5`, so the instrument finds strings here), and §2.4's three
outside-the-advisory-lock callers are all real (`MobileReplenishService:711` `recalculateOpenOrders(true)`,
`StockunitService:174` and `FixLocationAssignmentService:307` `recalculateForItem`).

I also verified the two test-side claims r2 newly leans on, since both are load-bearing for §5 and §7.1:
`AbstractReplenishRedirectPgFixture` really does declare `private void area(long id, String name)` and
`private void location(long id, String name, long areaId, Long rackId, long typeId)` — no replenishable or
lane parameter — while `ReplenReassignOnNonReplenishableMoveIT` declares
`private void area(long id, String name, boolean useForReplenish)` and
`private void location(long id, String name, long areaId, boolean transferLane)`. The §5 "decision, not an
omission" paragraph is accurate. And `ReplenishmentFirstTouchInvariantUnitTest.redirectSource_loadsTheTargetUnderItsLock`
does stub `when(stockunitRepository.findByIdForUpdate(SU_SRC)).thenReturn(Optional.empty());`, so §7.3's
"expected green via the null-source rule" prediction still holds under r2's helper.

---

## 6. Settled items — confirmed recorded, not reopened

- **CONTENDED defers on both paths** (D1): recorded as SETTLED with the product-owner date, the move-still-
  proceeds clause, and the superseded-ticket note. Not reopened here.
- **3637 before 3626** (D4): recorded with the `c99ddaff`-does-not-resolve evidence and a positive control.
- **No verify script** (D3): recorded, with the 12-of-16 false-green precedent.
- **The always-skip-locked vs hybrid tension**: r2 records it as *open with an expiry condition* (D2), which
  is an accurate recording of where I left it. Not re-argued. ⚠ A-7's correction makes the open tension
  *sharper* — one of the two residuals it names is closable by always-skip-locked — but it does not reopen
  the decision, because P-7 closes that residual at the right site and more cheaply.

---

## 7. VERDICT

# SOUND-WITH-CHANGES

r2 is a real improvement, not a tag-sprinkling pass. The three the brief singled out are genuinely handled:
the predicate's name, javadoc and body now state one comparison and it is the correct one; M-6 is reachable
and M-6b's equivalence argument is right against the code; and both A-7 counterexamples are named and
accurate. A-2, A-4, A-6, A-8, A-9 and A-10 are cleared in substance. §0 accounts for all 17 sites and the
four verdicts I spot-checked hold.

What remains blocking is concentrated in two sentences and one missing guard.

### Findings that still block

| # | Finding | Severity |
|---|---|---|
| **A-7′** | §4 Fix B's replacement justification — *"converting it to skip-locked would buy nothing against either residual above, because neither of those cycles runs through two stock units"* — is **false for `transferStockToUnitLoad`**, which the plan itself describes two paragraphs above as `S_low`/`S_high` ABBA through two stock units, and which always-skip-locked **would** close. Replace with the split verdict (order-row cycle: skip-locked buys nothing; SU↔SU cycle: it would close it, and we decline because P-7 is the right site). Carry the split into the **Fix F code comment**, and re-rank **P-7 to first** with an explicit statement that 3637 ships with that cycle open | **HIGH** |
| **A-5′** | `findByIdForUpdate` is `@Query("SELECT s FROM Stockunit s WHERE s.id = :id")` with `@Param("id")`, so a null id binds null and returns `Optional.empty()` — it does **not** raise `InvalidDataAccessApiUsageException` (my r1 error, propagated). Correct the §4 Fix B `[A-5/L4]` paragraph, **AC-3** and **M-11**: today's and the post-fix behaviour is `NO_CANDIDATE` with no exception, and M-11's mutant still kills attributably via the NPE | **MEDIUM** |
| **A-5″** | The new `existsById(candidate.stockUnitId)` is **unguarded against the same null**. On the move path `skipLocked` is unconditionally true, so a null target id reaches `CrudRepository.existsById(null)` → bare `IllegalArgumentException`, reintroducing one branch later exactly what the `targetId != null` guard prevents. Guard it, or drop the `toLong`-returns-null premise consistently in both places | **MEDIUM** |
| **N-2** | `REDIRECT_CONTENDED_NO_HEAL` has `REDIRECT_CONTENDED` as a prefix, so §7.6's operator grep double-counts and **U-I**'s *"exactly once"* is ambiguous on a non-PROCESSABLE order. Rename to a disjoint token (e.g. `SBDEV-3637 REDIRECT_NO_HEAL`). The WARN is the only production instrument this change ships | **LOW** |
| **N-3** | **AC-3** grades itself on a U-param `null-target` row that §7.4's table does not define (M-11 only says to add it). Add the row, with the corrected expectation from A-5′ | **LOW** |

Two non-blocking notes worth folding in while the above is edited: add the PIT mutator names
(`NEGATE_CONDITIONALS` / `CONDITIONALS_BOUNDARY`) to the M-6 and M-6b rows so a survivor is filed against
the right row; and add one sentence to Fix C recording that the `existsById` race errs **only** toward
deferring a vanished row, never toward cancelling a merely-locked one (derivation and blind spot in §3).

### The single thing most likely to go wrong during implementation

No longer A-1 — that is fixed, and fixed in the right direction. It is now **A-7′, because it is the sentence
routed into `src/main`.** Fix F's instruction is to put *"the residuals that remain open"* into the comment
that replaces `⚠ LOCK ORDERING — NOT PROVED SAFE`. If the current wording goes in, the fourth successive
safety argument at that site will be wrong in the same way as the first three — and this time it will be
wrong in a direction that tells the next reader the `transferStockToUnitLoad` cycle cannot be closed from
here, which is the thing most likely to get P-7 quietly dropped.
