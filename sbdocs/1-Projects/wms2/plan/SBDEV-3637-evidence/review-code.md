# SBDEV-3637 — code review (lane: code-review)

**Subject:** worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3637`, commit `29e43eb1`,
branch `bugfix/SBDEV-3637-replenish-redirect-lock-order`, base `origin/develop` `ec42f43a`.
**Diff read:** `git -C <WT> diff origin/develop...HEAD` — 11 files, +1844/−47.
**Contract graded against:** `sbdocs/1-Projects/wms2/plan/SBDEV-3637-replenish-redirect-lock-order.md` §4 Fix Design (r3).
**Constraint honoured:** read-only; no Maven, no test execution, no `git stash`/`checkout --`/`restore`.
Only the worktree was read; `v2/wms2-api` was not consulted.

## VERDICT: APPROVE-WITH-FIXES

No High findings. The six items the lead asked me to look hardest at all come back clean on behaviour
(details in §A). Four Mediums and four Lows, all of them in comment accuracy or test coverage, none in
the shipped control flow. Per the owner's standing instruction the Lows are fixed in this pass, so every
finding below carries the specific edit that clears it.

---

## A. The six focus items — verdicts

### A1. `targetIsBelowHeldSource` — name, javadoc and body agree. PASS
Body: `return currentSource != null && targetId != null && currentSource.getId() > targetId;`
Name says *target is below the held source*; `source > target` is exactly that; the javadoc's
*"a stock unit whose id is HIGHER than the target's"* is the same statement. The inverted draft the two
plan reviewers flagged at HIGH is **not** present.

Composition at the call site —
`boolean skipLocked = !recalcPath || targetIsBelowHeldSource(currentSource, candidate.stockUnitId);` —
graded over all four (path × direction) combinations plus both null sub-cases, against the §4 Fix B table:

| recalcPath | relation | expression | plan row | verdict |
|---|---|---|---|---|
| false (move) | any | `!false` short-circuits → **skip-locked** | skip-locked always | ✔ |
| true | target < source | predicate true → **skip-locked** | skip-locked | ✔ |
| true | target > source | predicate false → **plain** | plain | ✔ |
| true | `currentSource == null` | predicate false → **plain** | plain | ✔ |
| true | `targetId == null` | predicate false → **plain** | plain | ✔ |

Null source and null target both behave as the plan specifies, and `findByIdForUpdate(null)` binds null
against `@Query("SELECT s FROM Stockunit s WHERE s.id = :id")` → `Optional.empty()` → `NO_CANDIDATE`,
which is pre-fix behaviour preserved (plan `[A-5′]`).

### A2. `catch (FacadeException)` maps to `NO_CANDIDATE`, never `CONTENDED`. PASS
`ReplenishmentOrderMaintenanceService.java`, the arm quoted
*"SBDEV-3637 Fix C — NO_CANDIDATE, never CONTENDED. The shared transaction is ALREADY rollback-only"*
returns `RedirectOutcome.NO_CANDIDATE`. Pinned from both entry points by `U-H (recalc)` and `U-H (move)`
in `ReplenishmentOrderMaintenanceServiceUnitTest`, each asserting `State.CANCELED` **and**
`order.getStockunitId()` unchanged.

### A3. The `existsById` disambiguation. PASS on the claim; see M-3 for a coverage gap
`if (candidate.stockUnitId == null || !stockunitRepository.existsById(candidate.stockUnitId))` →
`NO_CANDIDATE`.

The in-code claim *"can only ever err toward DEFER, never toward a spurious CANCEL"* **holds under READ
COMMITTED**. Derivation: `existsById` is a non-locking JPQL exists query, so it reads the latest committed
snapshot; PostgreSQL's row-level locks (`FOR UPDATE` / `FOR NO KEY UPDATE`) are not visibility, so a row
held by another transaction is still returned; an uncommitted `DELETE` is likewise still visible. The only
`false` is a committed-gone row, which is genuinely `NO_CANDIDATE`. The asymmetry does not depend on the
isolation level, so it also holds at REPEATABLE READ. *Blind spot: derived from the semantics, not
executed — no fixture in this change holds an uncommitted delete across the check.*

The null guard **is** correct and **is** necessary: on the move path `skipLocked` is unconditionally true,
so a null `candidate.stockUnitId` (two null-returning branches in `toLong`) reaches this line, and
`SimpleJpaRepository.existsById` opens with `Assert.notNull(id, ID_MUST_NOT_BE_NULL)`.
`existsById` is reachable at all because `StockunitRepository extends PagingAndSortingRepository<Stockunit, Long>, CrudRepository<Stockunit , Long>` — under Spring Data 3 `PagingAndSortingRepository` alone would not supply it. Verified.

### A4. Every return site of `redirectSource`. PASS
Derivation: `grep -c "return RedirectOutcome"` → **9**; `grep -c "RedirectOutcome.CONTENDED"` → **2**
(one `return`, one comparison in `ensureValidSource`); positive control `grep -c "RedirectOutcome"` → 16,
so the instrument reads this file. Blind spot: a path that leaves the method by throwing is not a return
site and is not counted — the only catch here is the `FacadeException` arm, which does return.

| site (quoted) | outcome | correct? |
|---|---|---|
| `if (candidate == null)` | NO_CANDIDATE | ✔ |
| Fix E same-row, `if (!recalcPath)` | NO_CANDIDATE | ✔ |
| Fix E same-row, after `replenishorderRepository.save(order);` | REDIRECTED | ✔ |
| `if (newRequested.compareTo(BigDecimal.ZERO) <= 0)` | NO_CANDIDATE | ✔ |
| `if (!skipLocked) { ... // the row vanished between query and lock` | NO_CANDIDATE | ✔ |
| `candidate.stockUnitId == null \|\| !stockunitRepository.existsById(...)` | NO_CANDIDATE | ✔ |
| after the two WARNs | **CONTENDED** | ✔ |
| `catch (FacadeException e)` | NO_CANDIDATE | ✔ (A2) |
| after `replenishorderRepository.save(order);` at the tail | REDIRECTED | ✔ |

**No path reaches CONTENDED after a write.** The single CONTENDED return sits inside
`if (targetStock == null)`, and every statement above it in the method is either a read
(`unitloadRepository.findById`, `locationRepository.findById`, `syspropService.getSysvalue`,
`getAvailableReplenishmentSources`) or a branch that returns first. The two writers
(`changeReservedAmount` / `releaseHeld` and the `setStockunitId`… `save(order)` block) are both *below*
it. The enum javadoc correctly scopes the invariant to the method and explicitly disclaims transaction
scope (`alignDestination` may already have saved).

### A5. Both callers defer on CONTENDED. PASS
- `ensureValidSource`: `if (outcome == RedirectOutcome.CONTENDED) { return null; }` placed **before** the
  `REDIRECTED` arm and before the terminal `cancelOrder(...)`. No cancel, no `releaseHeld`, no `save`.
  `recalculateOrder` then does `if (sourced == null) { return; }` — the same early exit it already took
  for a cancel, so nothing downstream runs.
- `reassignOrCancelForMovedStockUnit`:
  `if (redirectSource(order, lockedSource, share, false) == RedirectOutcome.NO_CANDIDATE) { cancelOrder(...); }`
  — CONTENDED falls out of the `if`, the method returns normally, and the move proceeds. The
  `state >= STARTED` throw still runs *before* `redirectSource`, so a defer cannot let a started
  replenishment's stock move.
  Source, reservation and state are untouched on both paths.

### A6. SBDEV-3244 F3 — source is still its transaction's FIRST touch, under its lock. PASS
`ensureValidSource`'s
`Stockunit source = order.getStockunitId() == null ? null : stockunitRepository.findByIdForUpdate(order.getStockunitId()).orElse(null);`
is untouched by this diff, and nothing was inserted above it.
`ReplenishmentFirstTouchInvariantUnitTest` is correctly *tightened* rather than relaxed: the new
`verify(stockunitRepository, never()).findByIdForUpdateSkipLocked(candidateId);` closes the hole
`ignoreStubs()` leaves for a newly added finder, and it is paired with a live `InOrder` row on the same
run so it cannot be vacuous.

Worth stating because it is the non-obvious half: the new `existsById` call does **not** reintroduce a
lock-upgrade hazard. It is an exists/count query, so it creates no `EntityEntry` at lock mode READ for the
target row; a later `findByIdForUpdate` on that row is therefore still a first touch, not an upgrade.

### A7. Scope honesty. PASS on substance, three wording defects (M-1, M-2, L-2)
The replacement comment does **not** claim the move path is deadlock-free — it says
*"⚠ Scope limit: this closes the TARGET-acquisition edge and nothing more. It does NOT make the move path
deadlock-free"*. It does **not** claim all Stockunit locks are id-ordered — it says
*"Role-ordered acquisition is RETAINED"*. The two residuals are named **separately** with the acquisition
each runs through, and the comment explicitly forbids the collapsed false claim
(*"do NOT write that skip-locking this edge would buy nothing"*). It also states, correctly and
uncomfortably, *"THIS EDGE CARRIES A LIVE SU<->SU ABBA"*. That is the honest shape the plan asked for.

---

## B. Findings

### [MEDIUM · HIGH confidence] M-1 — the null-source/null-target branch note states a reason that is false for half of it
`src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java`, in the replacement
lock-ordering block:

> `//   recalc + null source or null target -> plain. NO stock-unit lock is held (FOR UPDATE on a`
> `//     missing row takes no lock), so there is no descending edge to avoid.`

For `(recalc, non-null source, null target)` a stock-unit lock **is** held — `ensureValidSource` took it
on the source. The conclusion survives (a finder bound to a null id matches no row and takes no lock, so
no edge is created), but the stated reason does not, and this is the exact comment block whose own history
records four successive wrong safety arguments. A reader who checks the reason against the code finds it
false and has no way to tell which of the two cases the author meant.

**Fix — split the row:**
```
//   recalc + null source -> plain. NO stock-unit lock is held: the source is null either because
//     stockunitId was null or because the locking read found nothing, and FOR UPDATE on a missing
//     row takes no lock. There is no descending edge to avoid.
//   recalc + null target -> plain. A source lock MAY be held here, but a finder bound to a null id
//     matches no row and takes no lock either, so no edge is created in either direction. The
//     outcome is NO_CANDIDATE, exactly as before this change.
```

### [MEDIUM · HIGH confidence] M-2 — "253 of 329 measured" is stated as a count; the plan says it is an estimate
Same comment block:

> `//     it is NOT (see the residual split below). It keeps waiting because 253 of 329 measured`
> `//     second-lock acquisitions are ascending (wsl-wineco-uat, 2026-10-04), and skip-locking`

§4 Fix B of the plan says of exactly this number: *"It approximates the real comparator by dropping the
`preferredAreaId` tiebreak … so 76/253 is an estimate, not a count."* The code drops the caveat and keeps
the word "measured". This is the single number the whole hybrid-vs-always-skip-locked trade rests on, and
the next person to revisit D2's expiry condition will read it as a count.

**Fix — add the caveat inline:**
```
//     cadence each. (253/329 is an ESTIMATE, not a count: the query approximates the candidate
//     comparator by dropping the preferred-area tiebreak. What it establishes robustly is that the
//     descending edge is common rather than exotic — a looser query returns 448 of 570.)
```

### [MEDIUM · HIGH confidence] M-3 — the `candidate.stockUnitId == null` guard is not pinned by any test that can see it fail
The plan's §7.5 mutation row **M-13** claims U-param row `move-null-target` kills "drop the
`candidate.stockUnitId == null ||` guard", on the grounds that `CrudRepository.existsById(null)` throws
`IllegalArgumentException`. In `ReplenishmentOrderMaintenanceServiceUnitTest` the repository is a Mockito
`@Mock`, so `existsById(null)` does **not** throw — it returns the default `false`. The mutant therefore
takes `!false` → `NO_CANDIDATE` → `CANCELED`, which is precisely what the row asserts. **M-13 survives**,
and AC-11's "every new assertion is mutation-checked with an attributable kill" is falsified for this one.
(`@MockitoSettings(strictness = Strictness.STRICT_STUBS)` does not change this: `existsById` is unstubbed
in that test, and strict stubs only grades stubbings that exist.)

The guard itself is correct and necessary — this is a coverage/claim defect, not a production defect.

**Fix — pin the short-circuit directly** in `targetAcquisitionUsesTheFinderTheBranchSelects`, guarded on
the one row that reaches it:
```java
if (targetId == null) {
    // M-13: the guard must SHORT-CIRCUIT, so existsById is never reached. A mock cannot reproduce
    // SimpleJpaRepository's Assert.notNull, so asserting "no exception" cannot see this mutant;
    // asserting the call never happens can. existsById takes a reference Long, so any() is safe here.
    verify(stockunitRepository, never()).existsById(any());
}
```
and retitle M-13's killer in §7.5 from "bare IllegalArgumentException" to "the `never()).existsById(any())`
assertion on the `null-target` / `move-null-target` rows".

### [MEDIUM · MEDIUM confidence] M-4 — `ReplenishRedirectLockOrderIT.IT-1e` has a timing window that can turn it red for the wrong reason
`src/test/java/net/aim_ai/wms/service/ReplenishRedirectLockOrderIT.java`,
`concurrentMovesOnInvertedPair_bothCommitAndNeitherOrderMoves`.

Both legs seize their own source and meet at `bothHoldTheirSource`, then each runs its whole move. The
assertions require **both** legs to find the other's source locked. If leg A's entire move committed
before leg B executed its first post-barrier statement, S1 would be free when B's redirect reached it, B
would redirect successfully, and `boundStockUnit(O2)`/`reserved(S1)` would fail — a red that reads as a
lock-ordering regression but is a scheduling artefact. The barrier makes this unlikely (A's move is tens
of statements, B needs only to reach one), but nothing makes it impossible, and this repo already carries
two timing-flaky ITs whose cost is that a red `develop` silently stops deploying.

**Fix — make the window observable so a flake is attributable rather than mysterious.** Attach a logback
`ListAppender` to `ReplenishmentOrderMaintenanceService` for the duration and add, before the state
assertions:
```java
assertThat(contendedLines)
    .as("NON-VACUITY: BOTH legs must have hit the contended target. One line means one leg's move "
        + "completed before the other reached its redirect — a scheduling artefact, not a lock-order "
        + "regression; re-run before investigating the assertions below.")
    .hasSize(2);
```
This is the same `linesContaining(..., "SBDEV-3637 REDIRECT_CONTENDED")` helper the unit test already uses.

### [LOW · HIGH confidence] L-1 — the residual block cites bare line numbers in another file
```
//      source (:202) then destination (:277) with no id comparison between them, on rows of the
```
Both are correct today (`grep -n "findByIdForUpdate" StockunitBusinessService.java` → `202`, `277`), but
this repo's citation rule is a quoted snippet precisely because line citations here drift 1–3 lines, and
a drifted citation in *this* comment block points a future reader at the wrong acquisition.

**Fix:** replace `(:202)` / `(:277)` with the snippets
`sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId)` and
`destinationStockUnit = stockunitRepository.findByIdForUpdate(dstSuId)`.

### [LOW · HIGH confidence] L-2 — "`transferStockToUnitLoad` runs through THIS acquisition" reads as a call path
`transferStockToUnitLoad` never executes `redirectSource`. What runs through this acquisition is its
*cycle* — recalc's wait edge at this line is one arm of the ABBA. The plan says it correctly
("Its cycle runs through recalc's TARGET acquisition"); the code dropped the word. Same wording in
residual 2.

**Fix:** `// 1. StockunitBusinessService.transferStockToUnitLoad's cycle CLOSES THROUGH this acquisition.`
and `// 2. ReplenishorderService.cancelReplenishmentOrder's cycle closes through the SOURCE acquisition in`.

### [LOW · MEDIUM confidence] L-3 — `targetIsBelowHeldSource` unboxes `currentSource.getId()` with no guard
`return currentSource != null && targetId != null && currentSource.getId() > targetId;`
A null `getId()` NPEs at unboxing. Unreachable in production — both call paths pass an entity returned by
`findByIdForUpdate`, so the PK is set — but the javadoc goes to some length about the `targetId != null`
guard and says nothing about the other operand, which invites a reader to conclude the asymmetry is an
oversight. Adding a third guard would create a branch no test can reach; stating the reason is better.

**Fix — one javadoc sentence next to the `targetId != null` paragraph:**
```
 * <p>No guard on {@code currentSource.getId()}: both callers pass a row returned by
 * {@code findByIdForUpdate}, so its PK is always set. Do not add one — it would be an unreachable
 * branch, and an unreachable branch is an untestable one.
```

### [LOW · HIGH confidence] L-4 — `ReplenReassignOnNonReplenishableMoveIT`'s mutation record is updated but its header still dates the measurement
The class javadoc opens *"Mutation record — measured 2026-09-07, every test killed by at least one
mutant."* The SBDEV-3637 edit splits one of those mutants in two and states that the CONTENDED leg
**was not measured** on that date. The header's blanket "every test killed" now covers a mutant that
post-dates it.

**Fix:** amend the header to
*"Mutation record — measured 2026-09-07, every test killed by at least one mutant; see the split row below
for one mutant added by SBDEV-3637 and NOT covered by that measurement."*

---

## C. Open questions (low confidence — surfaced, not blocking)

### [LOW severity · LOW confidence] O-1 — `existsById` introduces an auto-flush point on the miss path
A JPQL exists query over `Stockunit` triggers Hibernate's auto-flush if the transaction holds pending
`Stockunit` changes, so on the move path (where `processTransfer` has already walked part of the carrier
tree) the miss branch may emit the pending `UPDATE`s earlier than before. I believe this is benign: those
rows were loaded under `findByIdForUpdate` in the same transaction, so the flush takes no lock the
transaction does not already hold, and the writes would flush at commit regardless.
**NOT ESTABLISHED.** Probe that settles it: run `ReplenReassignOnNonReplenishableMoveIT` with
`org.hibernate.SQL` at DEBUG and check whether any `update stockunit` precedes the exists query on a
contended move.

### [LOW severity · LOW confidence] O-2 — `for no key update` is asserted as the rendered clause
`StockunitSkipLockedIT` records *"Hibernate's PostgreSQLDialect renders LockModeType.PESSIMISTIC_WRITE as
`for no key update` (measured 2026-10-05, this lane)"* and the regex accepts either spelling. If that is
right the conclusions still hold — PostgreSQL's row-lock matrix has `FOR NO KEY UPDATE` conflicting with
itself and with `FOR UPDATE`, so IT-3b's plain-`FOR UPDATE` holder really does block the finder and
`changeReservedAmount`'s own locking read stays a same-mode no-op. I did not execute the lane, so I am
taking the measurement on trust. The accept-either regex is the right call and needs no change.

---

## D. Not established in this lane

- **`lsp_diagnostics` was not run.** `lsp_servers` reports Eclipse JDT Language Server as **not
  installed** in this environment, so there is no language server to query. The probe that would settle
  type-safety is `mvn -o -q test-compile` in the worktree, which this lane was explicitly forbidden to run
  (a sibling lane owns the JVM and the ITs share one reusable Postgres container). I read the new source
  for compile hazards by hand instead and found none: `StockunitRepository` gained both
  `jakarta.persistence.QueryHint` and `org.springframework.data.jpa.repository.QueryHints`; the service
  needs no new import (`Objects`, `LOG`, `WmsConstants.State` are all already in use); the unit test's new
  `ParameterizedTest`/`MethodSource`/`Stream`/`ListAppender`/`ILoggingEvent` imports are present, and
  `assertThatCode`, `anyBoolean`, `isNull`, `doThrow`, `atLeastOnce` all resolve through the existing
  `import static org.assertj.core.api.Assertions.assertThatCode` and `import static org.mockito.Mockito.*`
  (`Mockito extends ArgumentMatchers`, so the on-demand import carries the matchers).
- **No test was executed**, so every "pinned by" statement above is a reading of the assertion, not an
  observed pass.
- **Fix G (the `sbdocs/` doc updates)** is outside this worktree and was not reviewed.

## E. Positive observations

- **The hardest thing here was got right.** The two `targetStock == null` cases are distinguished by the
  `skipLocked` boolean the code already holds rather than by inspecting the result — the collapse the plan
  names as the easiest way to get Fix C wrong. `U-L` pins the ascending-edge leg of that collapse, which
  is the leg an earlier plan revision mis-attributed to a test grading a different arm.
- **`U-param` carries both a wide and a boundary row on each side of the comparison** (`10/99`, `10/11`,
  `99/10`, `11/10`), which is what makes the sign mutant killable rather than merely asserted — a fixture
  with only wide rows lets `>` → `>=` and `>` → `<` survive, and one with only adjacent rows lets a sign
  mutant survive on adjacency.
- **Every `never()` in the new tests is paired with a positive assertion on the same run**, and each
  states why in a comment. `U-C` is the sharpest: it asserts the Fix E re-point *happened*
  (`getRequestedlocationId() == CAND_LOC`, `save(order)`) before asserting neither finder ran again.
- **`IT-3a` is kept as an explicit positive control** for `IT-3b`, with the reason written down: a finder
  that always returns empty passes the contention test perfectly. Same discipline in `IT-2`'s ascending
  control, which asserts the redirect actually *landed* so that a worker which blocked and then did
  nothing cannot satisfy it.
- **The non-autocommit holder connection** in both ITs, with the sibling classes that got this wrong named
  in the javadoc.
- **Both `TestClassTransactionManagerArchTest` exemptions document the id band they own and that they wipe
  in both `@BeforeEach` and `@AfterEach`** — the leak the rail exists to catch is addressed, not waived.
- **The `NeverMatcherNullBlindnessArchTest` count bump reads the `boolean zeroIfNegative` parameter at its
  declaration** rather than inferring it from the matcher name, and says so.
- **The replacement lock-ordering comment names its own expiry condition** and tells the next reader what
  *not* to conclude, including the two false safety arguments previous revisions put in that slot.

---

**Verdict line: APPROVE-WITH-FIXES** — clear M-1, M-2, M-3, M-4, L-1, L-2, L-3, L-4 in this pass. No
finding disputes the plan's design; all eight are comment accuracy or test coverage against the design the
plan already settled.
