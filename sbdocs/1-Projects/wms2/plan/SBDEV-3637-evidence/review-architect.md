# SBDEV-3637 — ralplan round 1, ARCHITECT review of the plan snapshot

**Reviewed:** `sbdocs/1-Projects/wms2/plan/SBDEV-3637-replenish-redirect-lock-order.md` (r1, 550 lines).
**Code read:** `.claude/worktrees/wms2-api/SBDEV-3637-readonly` @ `ec42f43a` (*"Merge pull request #453 from
SiteBossInc/feature/SBDEV-2624-sku-rename-in-place"*). Read-only; no `mvn`, no writes, no HEAD change.
**DB read:** `wsl-wineco-uat`, `nywh-hydra-prd` (read-only, 2026-10-04).
**Independent of lane-b.** I re-derived every `[arch-N]` claim from the code rather than ratifying it; §9 records
which of the seven are satisfied in substance and which are satisfied only in text.

**VERDICT UP FRONT: SOUND-WITH-CHANGES.** The hybrid is the right primitive and survives the strongest case
I can build against it (§1–§3). But the plan ships a **self-contradictory specification of the branch
predicate** — its javadoc and method name describe the *opposite* comparison from its body (§4.1, A-1,
severity HIGH) — and three of its own completeness claims are false against today's code (§4.3, §4.4, §5).
One mutant in §7.5 is provably equivalent and cannot be killed (§6.2, A-3).

---

## 1. The steelman antithesis: Option B (always skip-locked) is the better engineering bet

Argued as well as I can make it, before any rebuttal. This is not a strawman — on four of the five axes
below Option B wins outright.

### 1.1 Option B deletes more complexity than the plan admits

The plan concedes Option B loses "one lock method, one branch fewer, no id comparison, no null-source edge
case." It undercounts. Under Option B the following all disappear:

- `holdsLowerSourceLock` and its sign (the thing §4.1 below shows the plan has already got wrong once in
  prose);
- the `recalcPath`-vs-id-relation interaction, i.e. the five-row case table in §4 Fix B — which is itself
  internally inconsistent (§4.4);
- **the whole of Fix C's hardest clause.** The plan's own ⚠ at §4 Fix C says the plain/skip-locked `null`
  cases are *"different outcomes from the same expression, so the branch must record which finder ran"* and
  calls collapsing them *"the easiest way to get Fix C wrong."* Under Option B there is one finder, so
  `targetStock == null` has one meaning and there is nothing to record. A vanished row and a locked row both
  defer, and a vanished row then resolves on the next tick through `NO_CANDIDATE` anyway, because the
  candidate query re-runs from DB state;
- unit tests U-A, U-B, U-D, U-E and mutants M-4 and M-6 — roughly half the new test matrix, including the
  one mutant that is provably unkillable (§6.2).

So the real delta is not "one branch". It is a branch, a helper with a sign, a five-case table, a two-meanings-
from-one-expression invariant, four unit tests and two mutants.

### 1.2 Option B closes a cycle the hybrid deliberately leaves open

This is the strongest point and the plan does not engage with it at all.

The hybrid's justification for keeping the plain waiting finder on the ascending edge is, verbatim:

> `targetId > sourceId` (ascending), recalc path | **plain** `findByIdForUpdate` | already globally ordered,
> **therefore already deadlock-free**

That inference is false, and the plan's own §0 contains the counterexample. `ReplenishorderService.java`
locks the stock unit *before* the order row:

```java
// SBDEV-3621: the lock is the source's FIRST touch in this transaction (SBDEV-3244) ...
// The order row is not locked first; that SU-then-order order is a known, bounded residual.
Optional<Stockunit> sourceStockOptional = stockunitRepository.findByIdForUpdate(replenishOrder.getStockunitId());
...
replenishmentOrderMaintenanceService.markCancelled(replenishOrder);
```

and `markCancelled` writes the order row, taking its lock at flush:

```java
public void markCancelled(Replenishorder order) {
    order.setState(WmsConstants.State.CANCELED);
    replenishorderRepository.save(order);
}
```

Meanwhile `recalculateOrder` takes the **order** lock first (*"THE FIRST-TOUCH RULE. This locking read must
be the FIRST time this transaction touches this row"*), then the source SU, then the target SU.

So: T1 (recalc on order O, ascending edge) holds `O` and waits on `SU_hi`. T2 (`cancelReplenishmentOrder` on
the same order O) holds `SU_hi` and waits on `O`. **ABBA, through two different resource types, on the edge
the hybrid leaves waiting.** Id-ordering the SU pair does nothing about it, because the cycle does not run
through two SUs. Always-skip-locked removes T1's wait edge and breaks it.

The plan names this residual in §0 row 10 and AC-8, but then argues *for* the hybrid using a sentence that
assumes it away. Those two passages cannot both stand.

### 1.3 The 77% number measures the wrong quantity

The plan's decisive evidence for the hybrid is *"77% of second-lock acquisitions sit on the already-safe
ascending edge"*, so always-skip-locked would convert 253 of 329 certain-successes into maybe-successes.

But a skip-locked acquisition only *misses* when the row is locked **at that instant**. The cost of Option B
is therefore `P(ascending edge) × P(target contended at that instant)`, and the plan measures only the first
factor. Its own DB table measures the second as indistinguishable from zero on every tenant it could read:
`pg_stat_database.deadlocks = 0` on all three, and **0** items with ≥2 active orders on all three. The
partial unique indexes `idx_replenishorder_active_item_dest` and `idx_replenishorder_active_item_no_dest`
structurally cap how many same-item orders can contend. So the hybrid is paying certain complexity to avoid
a cost the plan itself measures as ~0.

(Derivation of my restatement: the plan's §1 DB table and §4 Fix B paragraph, read together. Blind spot:
three tenants at one instant, and both ShipItEZ prd roles refused the query — the same blind spot the plan
already declares. Neither of us can bound this fleet-wide.)

### 1.4 Option B's failure mode is symmetric; the hybrid's is not

If Option B is implemented wrongly, the failure is "we skip-locked somewhere we did not need to" — a
spurious defer, self-healing on the next tick. If the hybrid's comparison is implemented with the sign
inverted, you get **both** failure modes at once: spurious silent defers on 77% of edges **and** the original
deadlock still live on the remaining 23%. That is, a sign error ships the bug you came to fix, plus a new
one. §4.1 shows the plan has already written that sign inconsistently in the artifact an implementer will
copy from.

### 1.5 "A brief certain wait" is not bounded the way the argument implies

The plan contrasts "wait briefly, then certainly succeed" against a defer. The wait is bounded by
`wms.tenant.lock-timeout-ms`, which is **3000** in production (`src/main/resources/application.properties`:
`wms.tenant.lock-timeout-ms=3000`), applied per lock **acquisition**. The holder of the target is itself
inside `changeReservedAmount` + `releaseHeld`. A waiting ascending redirect can therefore stall a recalc
iteration for up to 3 s, and `recalculateForItem` runs those iterations inside a *caller's* transaction
(`StockunitService.transferStock` → `createFixedLocationAssignment` → `triggerReplenishmentMaintenance`,
per the in-code warning at `recalculateForItem`). "Brief" is doing unearned work.

---

## 2. Rebuttal — why the hybrid still wins, narrowly

**2.1 Determinism on the common path is a real asset, and it is the one Option B cannot buy back.** Under
Option B every redirect becomes probabilistic, and the plan is right that the failure is *silent*: no
exception, no metric (nothing scrapes Prometheus in this deployment), only Fix E's WARN. You could not tell
a 0.1% defer rate from a 10% one without log aggregation nobody has. §1.3's argument cuts the other way too:
because `P(contended)` is unmeasured fleet-wide, Option B's cost is unmeasured fleet-wide. The hybrid's cost
is zero by construction on 77% of edges regardless of what the unmeasured tenants look like. Choosing the
design whose worst case does not depend on an unmeasurable parameter is defensible.

**2.2 Starvation interacts badly with Option B.** AC-9/IT-4 already has to argue a deferred order is not
starved by the deterministic candidate sort. Every extra deferring edge is another full cadence lost and
another chance for the `available`-tiebreak pathology the plan names (exact ties, a reservation released
before the next pass). Tripling the deferring surface makes an argument that is already the plan's thinnest
measurably thinner.

**2.3 §1.2's cycle is genuinely out of scope.** It runs through the order row, is explicitly accepted
in-code under SBDEV-3621, and closing it by skip-locking the *SU* edge would be closing an order-row cycle at
an SU lock — an invariant-over-instance violation of exactly the kind the repo's fix discipline forbids. The
right fix for §1.2 is to make `cancelReplenishmentOrder` take the order lock first. **But that means the
plan must stop citing "therefore already deadlock-free" as the reason for the ascending branch, and must
instead say: the ascending edge is kept waiting because it agrees with the three id-ordering counterparties,
and it remains exposed to the SBDEV-3621 order↔SU residual, which this ticket does not close.** That is a
required change, not a quibble — it is the load-bearing sentence of D2.

---

## 3. The tradeoff tension, named and LEFT OPEN

**Determinism on the measured-common edge versus blast radius of a wrong branch, under an unmeasured
contention rate.** The hybrid is better if contention is non-trivial on some tenant nobody could read; Option
B is better if contention is near-zero everywhere (which is what every reading the team *could* take says).
Neither side can settle it from here: the deciding number — the rate at which a redirect target is locked at
the instant of acquisition — is not measurable before the fix ships, because today that case *is* the
deadlock. **I am not resolving this, and the plan should not pretend D2 resolved it either.** D2 resolved
"which edge distribution", not "which contention rate".

**Synthesis that makes the tension cheap to settle later, and which the plan should adopt:** P-3 ("on
CONTENDED, try the next candidate") is listed as a deferred proposal. If P-3 ever lands, Option B's entire
cost disappears — a skip-locked miss on the ascending edge stops being a lost cadence and becomes "take the
second-best source in the same tick." So the hybrid's complexity is **provisional on P-3 never landing.**
Record that explicitly in D2 and in the Fix F comment: *"if SBDEV-3637-P3 lands, collapse this branch to
always-skip-locked — the measurement that justifies the branch is about the cost of a lost cadence, and P-3
removes it."* Fix E's WARN token is the instrument that will make the decision measurable in production.
That is the synthesis: ship the hybrid, but ship it with its own expiry condition written down, instead of
as a permanent-looking invariant.

---

## 4. Hard tests of the specific items asked

### 4.1 ⛔ The branch predicate's javadoc and name contradict its body — A-1, HIGH

Plan §4 Fix B, verbatim:

```java
/** true when this transaction already holds a lock on a stock unit whose id is BELOW the target's. */
private static boolean holdsLowerSourceLock(Stockunit currentSource, Long targetId) {
    return currentSource != null && currentSource.getId() > targetId;   // unboxing compare, both non-null here
}
```

The javadoc says the held id is **BELOW** the target's (`source < target` — the **ascending** case). The body
computes `source > target` (the **descending** case). The name `holdsLowerSourceLock` agrees with the
javadoc, not the body. The call site is
`(!recalcPath || holdsLowerSourceLock(...)) ? skipLocked : plain`, which is only correct if the body's
reading is the intended one — and the §4 Fix B case table confirms it is (descending → skip-locked).

**So two of the three artifacts an implementer reads say the opposite of the one that is correct.** The
failure mode is §1.4's: an implementer who trusts the name or the javadoc, or who "fixes" the body to match
them, inverts the entire fix — ascending gets silently deferred, descending keeps the live deadlock, and the
only guard is U-A/U-B, which are Mockito `verify()` pins of the kind R-2 says executors edit to green.

**Required:** rename to something whose name states the mechanism and cannot be read backwards —
`targetIsBelowHeldSource(currentSource, targetId)` or `wouldDescend(...)` — and rewrite the javadoc to match
the body. State the rule once, as an invariant: *"skip-locked exactly when acquiring this lock would descend,
i.e. when a lock on a higher id is already held."*

### 4.2 ✅ The boxed-`Long` comparison is value-based — PASS

`currentSource.getId() > targetId` with both operands `Long`: Java's relational operators `<`/`>`/`<=`/`>=`
unbox both operands unconditionally, so this is a value comparison. The repo's recorded defect class
(reference comparison working under 128 and inverting past 127) applies to `==`/`!=`, not to `>`. The
precedent the plan cites is identically shaped and identically safe —
`ReplenishorderService.java`: `if (oldStockUnitId != null && oldStockUnitId < newStockUnitId) {`.

**Residual hazard, worth one line in the plan:** the hazard is a *future* edit to `Objects.equals`,
`compareTo`, or `!=`. Say so at the call site so the next reader does not "modernise" it.

### 4.3 ⛔ `candidate.stockUnitId` is not provably non-null — A-5, LOW

The comment `// unboxing compare, both non-null here` carries no derivation, and the code does not support
it. `candidate.stockUnitId` comes from `mapCandidate(row)` → `toLong(row[0])`, and `toLong` has **two**
null-returning branches:

```java
private Long toLong(Object value) {
    if (value == null) { return null; }
    if (value instanceof Number) { return ((Number) value).longValue(); }
    try { return Long.parseLong(value.toString()); } catch (Exception e) { return null; }
}
```

Today a null id reaches `findByIdForUpdate(null)` and raises a named Spring Data
`InvalidDataAccessApiUsageException`. Under Fix B it reaches `currentSource.getId() > null` and raises a bare
NPE at unboxing *before* the finder — a worse diagnostic, inside a `recalculateForItem` loop whose catch
arm distinguishes SQL-backed from non-SQL exceptions. Either guard it (`targetId != null &&`) or replace the
comment with the derivation that makes it unreachable. Do not leave an unsupported "both non-null here".

### 4.4 ⛔ The Fix B case table is internally inconsistent and miscounted — A-4, MEDIUM

- The prose says *"Four cases, exhaustively ... there is no fifth"*; the table immediately below has **five**
  rows. A sentence using *exhaustively* that disagrees with the artifact under it is the plan's own claim-
  discipline rule being broken in the place it matters most.
- Two rows contradict each other for a reachable combination. Row 4 says **move path, any id relation →
  skip-locked, always.** Row 5 says **`currentSource == null` → plain.** For (move path, null source) both
  rows apply and they disagree. The code expression resolves it correctly (`!recalcPath` short-circuits
  first, so skip-locked wins), but the *specification* does not, and nothing tests it.
- **(move path, null source) is reachable.** `reassignOrCancelForMovedStockUnit` does
  `Stockunit lockedSource = stockunitRepository.findByIdForUpdate(movedStock.getId()).orElse(null);` and then
  passes it straight into `redirectSource(order, lockedSource, share, false)` with no null guard.

**Required:** add the `recalc path` qualifier to the null-source row, restate as four rows keyed on
`recalcPath` first, and add a unit test for (move, null source) → skip-locked.

### 4.5 ✅ Equal ids genuinely return before any second lock — PASS, verified on today's code

`ReplenishmentOrderMaintenanceService.redirectSource`, SBDEV-3618 Fix E, sits above the target lock:

```java
if (currentSource != null && Objects.equals(candidate.stockUnitId, currentSource.getId())) {
    if (!recalcPath) { return false; }
    ... order.setRequestedlocationId(candidate.locationId); ... replenishorderRepository.save(order);
    return true;
}
```

Both arms return. `Objects.equals` is value-based and also catches (null, null). **So no equal-id pair can
reach the target lock on either path** — derivation: read of the full method body between the Fix E block and
`Stockunit targetStock = ...`; the only statements between are `newRequested` computation and a
`<= 0 → return false`. Blind spot: none for this clause; the region is 6 statements and I read all of them.
The plan's claim is correct. This has a consequence the plan missed — see §6.2.

### 4.6 ⛔ "CONTENDED: nothing was written" is false at transaction scope — A-2, MEDIUM

The Fix C enum javadoc asserts: *"CONTENDED carries an invariant the callers depend on: **nothing was written
and the transaction is NOT rollback-marked**."*

Traced, every point that maps to CONTENDED:

- **Within `redirectSource`:** correct. The only CONTENDED return is the skip-locked `targetStock == null`,
  and the only write above it is inside the Fix E block, which returns. Nothing has thrown, so the tx is not
  rollback-marked. ✅
- **At transaction scope on the recalc path: FALSE.** `recalculateOrder` calls `alignDestination` *before*
  `ensureValidSource`, and it writes:

  ```java
  private boolean alignDestination(Replenishorder order, FixLocationAssignment assignment) {
      if (order.getDestinationId() == null) {
          if (assignment != null) { order.setDestinationId(assignment.getAssignedlocationId()); replenishorderRepository.save(order); }
          return false;
      }
      return false;
  }
  ```

  It returns `false` on both arms, so execution continues into `ensureValidSource` with a pending write.
- **At transaction scope on the move path: FALSE by design and necessarily so.** D1 requires *"the move still
  proceeds"*, i.e. the transaction commits `processTransfer`'s unit-load relocation. An invariant worded
  "nothing was written" directly contradicts the product-owner decision it is supposed to protect.

The invariant the callers actually depend on is narrower and is the one worth pinning: **`redirectSource`
itself wrote nothing, took no reservation, and did not mark the transaction rollback-only — so the caller may
carry on and the surrounding transaction may commit.** Reword the javadoc to that. As written, R-4's
mitigation ("the invariant is stated in the enum's own javadoc") protects a claim that is false.

### 4.7 ✅ No path reaches CONTENDED after a write *inside the method*, and the FacadeException arm is mapped right — PASS

`catch (FacadeException)` → `NO_CANDIDATE` is correct and the plan's reasoning matches the in-code SBDEV-2074
M5 comment: `changeReservedAmount` is `@Transactional(rollbackFor = FacadeException.class)` and joins the tx,
so by that point the shared tx is already rollback-only. Mapping it to CONTENDED would let the move "proceed"
on a doomed unit. U-H + M-4 pin it. ✅ `[arch-1]` satisfied in substance.

### 4.8 ✅ SBDEV-3244 F3 and F4 survive — PASS, with the premise named

**F3** (source loaded under its lock as its first touch): Fix B changes only the *target* acquisition. Site 1
is untouched:
`Stockunit source = order.getStockunitId() == null ? null : stockunitRepository.findByIdForUpdate(order.getStockunitId()).orElse(null);`
✅

**F4** (target loaded under its lock before being written): `findByIdForUpdateSkipLocked` carries
`@Lock(PESSIMISTIC_WRITE)`, so when a row comes back it comes back locked; when it does not come back, nothing
is written to it. ✅ The plan's AC-10 wording is correct.

**And the plan's §7.3 prediction about `ReplenishmentFirstTouchInvariantUnitTest.redirectSource_loadsTheTargetUnderItsLock`
is correct, verified against the fixture.** It stubs
`when(stockunitRepository.findByIdForUpdate(SU_SRC)).thenReturn(Optional.empty());`, so `currentSource` is
null and `recalcPath` is true (entry via `recalculateForItem`), so
`(!recalcPath || holdsLowerSourceLock(null, 99L))` is `(false || false)` → **plain finder** → the existing
`InOrder` pin on `findByIdForUpdate(candidateId)` before `findById(candidateId)` stays green. ✅ `[arch-2]`
satisfied in substance, and it is load-bearing for an existing pin, not just for tidiness.

The plan's instruction to tighten that test's `verifyNoMoreInteractions(ignoreStubs(...))` to name the new
finder is right and matches the class's own in-code rule (*"If you tighten anything here, tighten the two
weakened ones"*).

### 4.9 ⚠ Defer-on-move self-heals **only for orders at state exactly 300** — A-6, MEDIUM

The plan's D1 and §4 Fix D assert, unconditionally, that the next recalc tick resolves a deferred order
because `isSourceUsable`'s `if (!locationId.equals(order.getRequestedlocationId())) { return false; }` fires.

**The `isSourceUsable` half of that is verified true.** The order keeps its old `requestedlocationId` (the
replenishable location the SU just left) because CONTENDED writes nothing; the SU's unit load now reports the
lane; `isSourceUsable` reads `Long locationId = unitload.getStoragelocationId();` and compares to
`order.getRequestedlocationId()` → mismatch → `false` → redirect-or-cancel. ✅

**The "next recalc tick visits it" half is narrower than the plan states.** Both sweep queries select on
*exact* equality:

- `@Query("SELECT r.id FROM Replenishorder r WHERE r.state = :state") List<Long> findIdsByState(...)` — called
  with `WmsConstants.State.PROCESSABLE`;
- `findIdsByStateAndItemdataId(...)` — same, plus `ORDER BY r.id`;

and `recalculateOrder` re-guards: `if (order == null || !Objects.equals(order.getState(), WmsConstants.State.PROCESSABLE)) { return; }`.

But the move path admits a **wider** band. `reassignOrCancelForMovedStockUnit` probes
`findIdByStateLessThanAndStockunitId(WmsConstants.State.FINISHED, ...)` and rejects only
`order.getState() >= WmsConstants.State.STARTED`. With `PROCESSABLE = 300`, `RESERVED = 400`,
`STARTED = 500`, **an order at 400 can be deferred on the move path and will be visited by no recalc sweep
ever** — it keeps its reservation, keeps pointing at a stock unit now on a non-replenishable lane, and
nothing heals it. The existing move-path test fixtures use exactly that state
(`Replenishorder order = orderAt(WmsConstants.State.RESERVED);` in
`ReplenishmentOrderMaintenanceServiceReassignTest`), so it is not a state the codebase treats as impossible.

**Measured, so you can size it:** `SELECT state, count(*) FROM replenishorder GROUP BY state` returns
`{300: 570, 700: 608, 800: 60452}` on `wsl-wineco-uat` and `{300: 1, 700: 2}` on `nywh-hydra-prd` — **no row
at 400 or 500 on either tenant.** A supporting (not conclusive) code axis: `git grep -n "State.RESERVED" --
src/main/java` returns 9 hits and **none** of them sets a `Replenishorder` to it (all are Pickingorder /
Customerorder); positive control in the same scan, `git grep -c "State.PROCESSABLE" -- src/main/java`
returns counts across 5+ files, so the instrument finds state constants. **Blind spots:** two tenants at one
instant; both ShipItEZ prd roles refuse `replenishorder`; and the grep cannot see a native `UPDATE
replenishorder SET state` or a state arriving from OMS import.

So this is latent, not live. **It still needs to be in the plan**, because D1 is a product-owner decision and
the plan sells its self-heal as unconditional. Required: state the premise (`self-heal is guaranteed only for
state == PROCESSABLE`), record the measurement and its blind spot, and either (a) narrow
`reassignOrCancelForMovedStockUnit`'s defer to `state == PROCESSABLE` and keep today's cancel for anything
else, or (b) add an assertion/WARN when CONTENDED is returned for a non-PROCESSABLE order. (b) is cheaper and
sufficient given the measurement.

---

## 5. Overclaim sweep

I checked every *every / only / all / no / exactly / none* sentence in the plan for a named derivation and
blind spot. The plan is unusually disciplined here — §0's three-mechanism derivation, §2.4's grep plus its
token-exactness blind spot, §4 Fix A's `HibernatePropertiesCustomizer` blind spot, and the §1 DB table's
"⚠ Three tenants at one instant" are all correctly formed, and **AC-8 does what it was asked to do**: it
explicitly refuses "the move path is deadlock-free" and explicitly refuses "all Stockunit locks are
id-ordered", naming both pre-existing residuals. ✅ `[arch-7]` satisfied in substance.

Three failures:

1. **"already globally ordered, therefore already deadlock-free"** (§4 Fix B case table, row 1) — no
   derivation, and false per §1.2. **Required fix, MEDIUM** (A-7).
2. **"Four cases, exhaustively ... there is no fifth"** over a five-row table (§4.4 above). **MEDIUM** (A-4).
3. **"both non-null here"** (§4.3 above) — no derivation and not supported by `toLong`. **LOW** (A-5).

One more, softer: **"nothing excludes the current source BY IDENTITY from the candidate set"** is carried
over from the in-code comment and is correct — I re-read
`.stream().map(this::mapCandidate).sorted(...).findFirst()` and there is no `.filter`. ✅

---

## 6. Testability of the acceptance criteria

### 6.1 What holds

- **AC-1 / AC-3 / AC-4** map cleanly to U-A/U-B/U-D/U-E as Mockito `verify()` pins on which finder was
  called. Testable. ⚠ They are *name*-coupled: a rename of either finder un-pins them silently. Worth one
  parameterized table-driven test over `(recalcPath, sign)` instead of five separate cases — strictly
  stronger and it cannot drift case-by-case.
- **AC-2 / IT-3a-c** are the right shape, and IT-3c (assert the emitted SQL on the **tenant** EMF, not the
  annotation) is genuinely what closes Fix A's declared blind spot. ✅
- **AC-7 / IT-1a-e.** I traced the choreography and it does form a clean ABBA deterministically, not by
  timing: A pre-seizes S1 and B pre-seizes S2, then A's move of UL_1 to LANE_1 makes S1 non-replenishable
  *to A only* (B's move is invisible), so A's sole candidate is S2 and A waits on B; symmetric for B. IT-1b's
  `hasSize(1)` is correct — both-fail means the fixture serialised elsewhere, zero-fail means it is vacuous,
  and the plan says so. Post-fix IT-1e is deterministic too: both sides skip, both defer, both commit. ✅
- The `40P01`-not-`55P03` reasoning is verified against the config: `wms.tenant.lock-timeout-ms=10000`
  (`src/test/resources/application-postgres-integration.properties`) versus `3000`
  (`src/main/resources/application.properties`), both well-separated from PostgreSQL's 1000 ms
  `deadlock_timeout`. M-3 is a good mutant. ✅
- **AC-5** is testable as written *once* its "writes nothing" clause is scoped per §4.6.
- The three-template choice (§7.1) is right, and `MoveUnitloadLockOrderProbeIT`'s `backend_xid` trick really
  is the only in-repo mechanism that distinguishes "ordered correctly" from "happened not to deadlock".
  `[arch-5]`, `[arch-6]` are carried in substance (the WARN token exists and the NOWAIT reasoning is slated
  for the code, not just the plan).

### 6.2 ⛔ M-6 is an equivalent mutant and cannot be killed — A-3, MEDIUM

§7.5 M-6: *"flip `>` to `>=` in `holdsLowerSourceLock`"* must turn **U-C** red, and the ⚠ underneath adds
*"M-6's fixture must include an equal-id row, not only unequal ones."*

By §4.5, **the equal-id case returns from the Fix E block and never reaches `holdsLowerSourceLock` at all**,
on either path. Flipping `>` to `>=` therefore changes no observable behaviour: the mutant survives, and the
instruction to add an equal-id fixture row cannot help, because no equal-id row can reach the predicate.

This matters beyond bookkeeping. AC-11 says *"Every new assertion is mutation-checked with an attributable
kill"*, so an executor hits an unkillable mutant on an AC that says it must die, and the cheapest way to
"fix" it is to move the branch above the Fix E return — which **U-C explicitly forbids** and which §4 Fix B's
`[arch-3]` placement rule exists to prevent. The plan sets a trap for its own guard rail.

**Required:** either delete M-6 and replace it with a mutant that is reachable — *invert the comparison*
(`>` → `<`), which U-A and U-B both kill attributably and which is the error §4.1 makes likely — or keep M-6
and mark it **EQUIVALENT, expected to survive, with the reason** (Fix E returns first), so a survivor is read
as confirmation rather than as a gap.

### 6.3 ⚠ IT-2's holder contradicts §7.1's own prohibition — A-8, LOW

§7.1 says, correctly: *"Do **not** drive locks through a raw `JdbcTemplate`"*, citing `MoveCronConcurrencyIT`'s
record that a template on an autocommit `DriverManagerDataSource` releases `SELECT ... FOR UPDATE` at
statement end, and that two sibling ITs in this repo have exactly that defect. IT-2 then says *"park a raw
JDBC holder on the target row."* The holder must be a `java.sql.Connection` with `setAutoCommit(false)`, held
open across the probe and explicitly rolled back in a `finally`. Spell that out — a false-green here reads as
"the fix works" when nothing was ever locked.

### 6.4 ⚠ AC-9 / IT-4 is the weakest criterion, and the plan half-says so

"Not starved by the deterministic candidate sort" is argued structurally (a successful reservation lowers the
winner's `available` and demotes it) and the plan names the pathological cases (exact ties, a released
winner). But IT-4 as written tests one hold-and-release cycle, which does not exercise either pathology. This
is acceptable for T3 — Fix E's WARN is the production instrument — but AC-9 should say it is *bounded
evidence*, not a proof, so nobody later cites it as one.

---

## 7. Items checked and found SOUND (no change needed)

- **Fix A's `-2` premise.** I did not re-disassemble; lane-b's bytecode evidence is corroborated in-repo by
  `StockunitRepository.java`'s own comment directly above the method being paired — *"PostgreSQLDialect.withTimeout
  translates only 0 (NO_WAIT) and -2 (SKIP_LOCKED) and returns the lock string unchanged for every other
  value"* — and by `TenantDatabaseConfig`. Two independent instruments plus a disassembly. The plan's framing
  that SBDEV-3250 is *positive* evidence (value-dependent, not path-dependent inertness) is correct.
- **`@RestResource(exported = false)` is mandatory** and correctly justified by the SBDEV-3169 precedent on
  `findByIdForUpdate`.
- **No Flyway migration** — correct; nothing schema-shaped changes.
- **The move path's "no ascending claim available" argument** is correct:
  `List<Stockunit> findByUnitloadId(@Param("unitloadId") Long unitloadId);` is a derived finder with no
  `ORDER BY`, and `processTransfer` loops
  `for (Stockunit movedStockUnit : stockunitRepository.findByUnitloadId(unitload.getId()))` calling
  `syncForMovedStockUnit` per SU, then recurses into children. So the transaction does accumulate SU locks in
  unspecified order before reaching any given target. ✅ Row 4 of the case table is right.
- **P-1 through P-6 are correctly scoped as proposals, not folded in.** P-1 (`findByUnitloadId` has no
  `ORDER BY`) is verified and is indeed the other half of the move-path claim; agreeing with the plan that it
  is the one to do first. P-4 is verified: `findIdsByState` has no `ORDER BY` while its sibling
  `findIdsByStateAndItemdataId` has `ORDER BY r.id` with the SBDEV-3622 comment above it.
- **§6.1 row 9 / Q1 (SBDEV-3626 sequencing)** is honestly left open with a named probe. Correct handling.
- **Horizontal-scalability table** — all ten rows check out; row 6 correctly identifies that the Fix C
  mapping is what makes idempotency true.

---

## 8. Principle violations against the plan's own stated principles

| # | Principle the plan asserts | Where it is broken |
|---|---|---|
| 1 | Completeness words name their derivation and blind spots | *"therefore already deadlock-free"* (A-7); *"Four cases, exhaustively"* over 5 rows (A-4); *"both non-null here"* (A-5) |
| 2 | *"Every new assertion is mutation-checked with an attributable kill"* (AC-11) | M-6 is equivalent and unkillable (A-3) |
| 3 | Invariant over instance | `holdsLowerSourceLock`'s name/javadoc state the instance backwards instead of the invariant (A-1) |
| 4 | §7.1: never drive locks through a raw `JdbcTemplate` | IT-2 does exactly that without naming the autocommit guard (A-8) |
| 5 | An invariant worth pinning must be true | Fix C's *"nothing was written"* is false at tx scope on both paths (A-2) |

---

## 9. Verification of the seven `[arch-N]` tags from lane-b

| tag | claim | satisfied in substance? |
|---|---|---|
| `[arch-1]` | `FacadeException` arm → `NO_CANDIDATE` | **YES** — §4.7. Mapped in Fix C, pinned by U-H and M-4 |
| `[arch-2]` | null source → plain finder | **PARTLY** — correct for recalc and verified load-bearing for an existing pin (§4.8), but the case table contradicts itself for (move, null source) and no test covers it (A-4) |
| `[arch-3]` | branch placed at the existing target lock, not earlier | **YES** in the text; **undermined** by M-6, whose only repair route is to move it (A-3) |
| `[arch-4]` | the U-11b rewrite *is* the proof SBDEV-3618 Fix D stays pinned | **YES** — §7.3 names both pins, states what survives, and forbids the id-flip shortcut. Verified against `stubRedirectSuccess`, which stubs `findByIdForUpdate((Long) candidateRow[0])` and must be re-pointed |
| `[arch-5]` | observability on CONTENDED | **YES** — Fix E, greppable token, both paths, U-I |
| `[arch-6]` | the NOWAIT-vs-SKIP-LOCKED asymmetry goes in the **code** | **YES** — stated in Fix B and routed into Fix F |
| `[arch-7]` | the scope limit is asserted as a limit | **YES** — AC-8 is correctly formed and refuses both overclaims |

---

## 10. VERDICT

# SOUND-WITH-CHANGES

The design is right. The hybrid survives the strongest antithesis I can build (§1), though its *stated
justification* does not and must be repaired (A-7). The deadlock mechanism, the `-2` premise, the F3/F4
preservation, the Fix C mapping and the scope limit are all correct against `ec42f43a`. What is wrong is
concentrated in the specification artifacts an implementer copies from, not in the architecture.

### Required changes

| # | Change | Severity |
|---|---|---|
| **A-1** | `holdsLowerSourceLock`'s javadoc (*"id is BELOW the target's"*) and its name both describe the **opposite** comparison from its body (`source > target`). Rename to `targetIsBelowHeldSource` / `wouldDescend` and rewrite the javadoc to the invariant: *skip-locked exactly when this acquisition would descend.* | **HIGH** |
| **A-2** | Fix C's *"nothing was written and the transaction is NOT rollback-marked"* is false at transaction scope on **both** paths — `alignDestination` writes before `ensureValidSource` on recalc, and D1 **requires** the move's writes to commit. Rescope to *"`redirectSource` itself wrote nothing, reserved nothing, and did not mark the tx rollback-only."* R-4's mitigation currently protects a false claim | **MEDIUM** |
| **A-3** | M-6 (`>` → `>=`) is an **equivalent mutant**: equal ids return from the Fix E block and never reach the predicate (§4.5). Replace it with *invert the comparison* (`>` → `<`), killed attributably by U-A and U-B, or mark M-6 EQUIVALENT with the reason. As written it is an AC that cannot pass, whose cheapest repair is the one `[arch-3]` and U-C forbid | **MEDIUM** |
| **A-4** | The Fix B case table says *"Four cases, exhaustively"* over **five** rows, and rows 4 and 5 contradict each other for **(move path, null source)** — a reachable combination (`reassignOrCancelForMovedStockUnit` passes `lockedSource` with no null guard). Re-key the table on `recalcPath` first, and add a unit test for (move, null source) → skip-locked | **MEDIUM** |
| **A-5** | `// unboxing compare, both non-null here` is unsupported: `toLong` has two null-returning branches. Either guard `targetId != null` or give the derivation. Today a null id yields a named `InvalidDataAccessApiUsageException`; after Fix B it yields a bare NPE earlier, inside the `recalculateForItem` loop | **LOW** |
| **A-6** | Defer-on-move self-heals **only for `state == PROCESSABLE`**, because both sweeps select `r.state = 300` exactly, while the move path admits `state < STARTED`. Measured no 400/500 rows on `wsl-wineco-uat` or `nywh-hydra-prd` (blind spot: 2 tenants, 1 instant, ShipItEZ refused), so it is latent. State the premise in D1 and add a WARN or a narrowing guard for a non-PROCESSABLE CONTENDED | **MEDIUM** |
| **A-7** | Delete *"already globally ordered, therefore already deadlock-free"*. It contradicts the plan's own AC-8 and §0 row 10: the ascending plain wait can still close a cycle through the **order row** against `ReplenishorderService.cancelReplenishmentOrder`, which locks SU-then-order. Replace with: *the ascending edge keeps waiting because it agrees with the three id-ordering counterparties; it remains exposed to the SBDEV-3621 order↔SU residual, which this ticket does not close* | **MEDIUM** |
| **A-8** | IT-2's *"park a raw JDBC holder"* contradicts §7.1's own prohibition. Specify `Connection` with `setAutoCommit(false)`, held across the probe, rolled back in a `finally` | **LOW** |
| **A-9** | Record D2's **expiry condition**: the hybrid's justification is the cost of a lost cadence, and P-3 ("try the next candidate on CONTENDED") removes that cost. Write in D2 and in the Fix F comment that if P-3 lands, this branch collapses to always-skip-locked. Also stop presenting D2 as having settled the contention-rate question — it settled the edge *distribution* | **LOW** |
| **A-10** | Replace U-A/U-B/U-D/U-E with one parameterized test over `(recalcPath, sign-of-comparison, null-source)`. Five name-coupled `verify()` pins drift case-by-case; one table cannot | **LOW** (quality) |

### The single thing most likely to go wrong during implementation

**A-1 — the sign of the branch predicate.** The plan hands the implementer a method whose *name* and
*javadoc* both say "the held source is below the target" while its *body* computes the opposite, and the body
is the correct one. The two most natural implementer reactions — trust the name, or "fix" the body to match
the javadoc — both invert the fix in the worst possible direction: silent spurious defers on the 77% of
edges that were already safe, **and** the original ABBA still live on the 23% this ticket exists to close.
Nothing in production would show it (no exception, no metric, only Fix E's WARN, which would fire *more* and
be read as working-as-intended), and the only guards are U-A/U-B — Mockito `verify()` pins of exactly the
kind R-2 predicts an executor will edit until green. Fix the name and the javadoc before the gate writes a
single test.
