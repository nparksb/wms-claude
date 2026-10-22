# SBDEV-3637 — conformance verification (independent lane)

**Subject** worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3637`, commit `29e43eb1`
on `bugfix/SBDEV-3637-replenish-redirect-lock-order`, merge-base `ec42f43a` (confirmed by
`git merge-base origin/develop HEAD`). One commit ahead; nothing read from `v2/wms2-api`.

**Verdict: PASS with two PARTIAL and one MISSING criterion.** Nothing is wrong in the shipped code.
The gaps are an unwritten test (AC-9 / IT-4) and unreproduced manual mutants (AC-11).

---

## 1. Evidence — every command re-run by this lane

`pgrep -af "[j]ava.*SBDEV-36"` before each run → no peer JVM. Toolchain
`openjdk 21.0.11 2026-04-21 LTS (Microsoft-13877187)`.

| check | command | result |
|---|---|---|
| clean compile | `mvn -o -B -ntp clean compile` | **exit 0** |
| full build | `mvn -o -B -ntp clean verify` | **BUILD SUCCESS, exit 0** |
| surefire | same run | **Tests run: 7810, Failures: 0, Errors: 0, Skipped: 1** |
| failsafe | same run | **Tests run: 627, Failures: 0, Errors: 0, Skipped: 31** |
| IT lane actually ran | `grep -oE "Running net\.aim_ai\.wms\.[A-Za-z0-9_.$]*(IT\|IntegrationTest\|E2ETest)$" \| sort -u \| wc -l` | **122** — matches the brief's 121 + 1 (`StockunitSkipLockedIT`; `ReplenishRedirectLockOrderIT` was already in the 121 baseline as the gate's 2 reds). The IT lane is not short, so the green is real |
| mutation | `mvn -o -B -ntp org.pitest:pitest-maven:mutationCoverage -DtargetClasses=…ReplenishmentOrderMaintenanceService` | 236 mutants, 177 killed (75%), test strength 83%; **on the diff's changed lines: 25 mutants, 22 KILLED** |

⚠ This lane's Testcontainers logged *"Reuse was requested but the environment does not support the
reuse of containers"*, so each IT class got its own container. That removes the shared-container
false-red hazard for this run; it also means the numbers above are a clean, independent lane.

Per-class, the classes this ticket touches or claims:

| class | result |
|---|---|
| `unit.repo.StockunitSkipLockedContractTest` | 3 / 0F |
| `integration.repository.StockunitSkipLockedIT` | 3 / 0F |
| `service.ReplenishRedirectLockOrderIT` | 4 / 0F |
| `unit.service.…ServiceUnitTest$Sbdev3637TargetLockAcquisition` | 19 / 0F (10 U-param rows + U-C,F,G,H×2,I,J,K,L) |
| `unit.service.ReplenishmentOrderMaintenanceServiceReassignTest` | 15 / 0F |
| `unit.service.ReplenishmentFirstTouchInvariantUnitTest` | 3 / 0F |
| `service.ReplenReassignOnNonReplenishableMoveIT` | 6 / 0F |
| `integration.PostgresDeadlockDetectorControlIT` (AC-7 positive control) | 1 / 0F |
| `integration.service.ReplenishmentOrderMaintenanceServiceIntegrationTest` (SBDEV-2234 regression) | 1 / 0F |
| `integration.service.ReplenishorderRedirectSourceIT` | 25 / 0F |
| `unit.config.{NeverMatcher…,TestClassTransactionManager…,OptionalSafety}ArchTest` | 4 / 5 / 1, all 0F |

---

## 2. AC-2 — the `SKIP LOCKED` claim, checked with a second instrument

The executor's claim that Hibernate renders `PESSIMISTIC_WRITE` on PostgreSQL as
`for no key update`, not `for update`, is **CORRECT**, and I confirmed it without running the test.

`javap -p -c` on `org/hibernate/dialect/PostgreSQLSqlAstTranslator.class` from
`~/.m2/.../hibernate-core-6.6.39.Final.jar`:

```
  protected java.lang.String getForUpdate();
    Code:
       0: ldc           #61                 // String  for no key update
```

`PostgreSQLDialect.class` itself carries only `" for update nowait"`, `" for update skip locked"`,
`" for share"` — the legacy non-AST path. The JPQL `@Query` finder renders through the SQL AST
translator, so the live clause is `for no key update … skip locked`.

**Does IT-3c still discriminate?** Yes. The two assertions are separate, not disjoined:

```java
.matches(s -> s.contains("for update") || s.contains("for no key update"));   // lock applied at all
...
.contains("skip locked");                                                      // the discriminator
```

`"for no key update"` does **not** contain the substring `"for update"`, so the first leg genuinely
needs both spellings. The second leg is unconditional and is the only token the plain finder cannot
also produce — exactly the signal AC-2 needs. The assertion as written is sound.

IT-3b independently corroborates the clause is a real write lock: a **non-autocommit** holder takes a
plain `SELECT … FOR UPDATE`, and the subject skips it. Two modes that did not conflict could not
produce that skip. That also settles AC-10's F4 half — both finders render the same
`for no key update`, so `changeReservedAmount`'s own `findByIdForUpdate` stays a same-mode no-op.

**AC-2: VERIFIED.**

---

## 3. Acceptance criteria

| # | status | evidence |
|---|---|---|
| AC-1 | **VERIFIED** | `targetAcquisitionRows()` carries all four rows with the planned ids — `asc-wide (10,99)`, `asc-boundary (10,11)`, `desc-wide (99,10)`, `desc-boundary (11,10)`. Wide and boundary pairs are **different**, closing the `[NEW-7]` trap. Each row asserts both halves (`verify(…).findByIdForUpdate*(targetId)` **and** `verify(…, never())` on the other) with the literal id, never `any()`. 19/19 green |
| AC-2 | **VERIFIED** | §2 above. IT-3a/b/c green; `StockunitSkipLockedContractTest` pins `@Lock(PESSIMISTIC_WRITE)` + exactly one `jakarta.persistence.lock.timeout` hint whose value is exactly `"-2"` |
| AC-3 | **VERIFIED** | rows `null-source`, `null-target`, `move-null-target` all present and green. Code: `targetIsBelowHeldSource` guards `targetId != null`; the `existsById` arm guards `candidate.stockUnitId == null \|\|` before `existsById`. PIT: all three `NegateConditionalsMutator`s on line 749 (the two null guards and the `>`) **KILLED**; the negate on the `existsById` guard line **KILLED** |
| AC-4 | **VERIFIED** | `boolean skipLocked = !recalcPath \|\| targetIsBelowHeldSource(currentSource, candidate.stockUnitId);` — `!recalcPath` short-circuits, so the move path skip-locks regardless of ids **and** regardless of a null source. Rows `move-asc`, `move-desc`, `move-null-source` green |
| AC-5 | **VERIFIED — checked in the code, not only by test name** | Recalc: `ensureValidSource` returns `null` on `CONTENDED` **before** reaching `cancelOrder`. Move: `if (redirectSource(...) == RedirectOutcome.NO_CANDIDATE) { cancelOrder(...); }` — `CONTENDED` falls past it and the method returns normally, so the move's own writes commit. On the `CONTENDED` path the only statements executed are the `existsById` read and two `LOG.warn`s: **no write, no reserve, no `setRollbackOnly`** anywhere in the arm. The scoping is stated correctly in the `RedirectOutcome` javadoc (*"It is not a claim that the transaction is clean"*). U-F / U-G green |
| AC-6 | **VERIFIED — the one both reviewers flagged** | `catch (FacadeException e) { … return RedirectOutcome.NO_CANDIDATE; }`, with the reason in-line (*"the shared transaction is ALREADY rollback-only by the time this arm runs"*). `CONTENDED` is not reachable from that arm. Graded on **both** paths — `U-H (recalc)` and `U-H (move)` are two separate tests, both green |
| AC-7 | **PARTIAL** | Post-fix half **VERIFIED**: IT-1e green — both legs commit, `legASeized && legBSeized` non-vacuity gate, both orders exactly `PROCESSABLE` bound to their original SUs, both reservations unchanged (exact post-state, never a disjunction). IT-2 green — `blockedStatement()` is null on the descending edge; its CONTROL asserts the ascending edge **does** block with a non-null `backend_xid` **and** that the redirect then lands on the target, so neither test is vacuous. Pre-fix half (today's code raises `40P01`, `pg_stat_database.deadlocks` +1) is **not reproducible from this tree**: IT-1c/IT-1d were gate-only assertions, the work is one squashed commit with no red-first record on disk, and the lane's positive control `PostgresDeadlockDetectorControlIT` proves only that the counter is live in the lane |
| AC-8 | **VERIFIED** | Stated as a limit: *"⚠ Scope limit: this closes the TARGET-acquisition edge and nothing more. It does NOT make the move path deadlock-free"*. `git grep -n -i "deadlock.free"` over `src/main`+`src/test` returns 3 lines, and both in the changed file are **negations**; `git grep -n "id-ordered\|id ordered" -- src/main/java` returns **zero** (positive control: the same instrument returns the `deadlock-free` lines above, so it is not a broken scan), so no "all Stockunit locks are id-ordered" claim exists. The two residuals are numbered **1.** and **2.** in separate paragraphs and are **not** collapsed: `transferStockToUnitLoad :202/:277` is given its own ABBA counterexample and the sentence *"always-skip-locking this line WOULD close it"*; `cancelReplenishmentOrder` is given the distinct reason *"runs through the SOURCE acquisition … Nothing done at THIS line can close it"* |
| AC-9 | **MISSING** | IT-4 was never written. `ReplenishmentOrderMaintenanceServiceIntegrationTest` is **not in the diff** (`git diff --name-only` → absent), and no starvation test for a deferred redirect exists anywhere. (`ReplenishOrderJobSweepStarvationTest` is the pre-existing SBDEV-3624 sweep test, a different subject.) Positive control: the same grep finds 6 files containing `starv`, so it is not a broken scan |
| AC-10 | **VERIFIED** | `ReplenishmentFirstTouchInvariantUnitTest` 3/3 green, and it was **tightened**, not left alone: `verify(stockunitRepository, never()).findByIdForUpdateSkipLocked(candidateId)` was added with the literal id, paired with the positive `InOrder` row on the same run, closing the documented `ignoreStubs()` weakening. F4's half holds for the reason in §2 — both finders render the same lock mode |
| AC-11 | **PARTIAL** | §4 below |
| AC-12 | **VERIFIED** | `BUILD SUCCESS`, 7810/0F surefire, 627/0F failsafe, 122 IT classes, measured by this lane adjacent in time. **Zero** failures, so no flaky rerun was needed |
| AC-13 | **VERIFIED** | §5 below |
| AC-14 | **VERIFIED** | U-J (vanished row → `NO_CANDIDATE`) and U-K (`RESERVED` order → `REDIRECT_NO_HEAL`, still no cancel) both green. PIT killed both `NegateConditionalsMutator`s on the `candidate.stockUnitId == null \|\| !existsById(...)` line and the one on `!Objects.equals(order.getState(), PROCESSABLE)`. The one-directional raciness is stated in-code and is **not** claimed as tested |

### Plan §0 in-scope rows

Only sites **1, 2, 3** are marked in scope. Site 2 is the fix. Sites 1 and 3 are reference points and
are untouched in `src/main`, with site 3's pin rewritten as §7.3 requires. Sites 8, 11, 12, 16, 17 and
`getStockUnitsByItemDataIdForUpdate` are left live and are each named in AC-8's residual rule, both
in-code and in `wms2-transaction-osiv-boundary-map.md` §8.5. Site 14's same-mode-no-op requirement
holds (§2). **No in-scope row was skipped.**

---

## 4. AC-11 — how many mutants were actually run

**Plainly: I reproduced the PIT-reachable subset myself; 7 of the 13 mutants are not PIT-reachable
and I could not reproduce them.** The executor reports spot-checking M-7 and M-6 only, and there is
no on-disk record of the rest.

PIT scoped to `ReplenishmentOrderMaintenanceService`, JDK 21, targets the three unit classes:
**25 mutants land on the diff's changed lines, 22 KILLED.** The three that did not:

| line | mutator | status | reading |
|---|---|---|---|
| 749 `targetIsBelowHeldSource` | `ConditionalsBoundaryMutator` (`>` → `>=`) | SURVIVED | **This is M-6b, and the plan predicted exactly this survivor and marked it EQUIVALENT.** Confirmation, not a gap — do not "repair" it |
| 649 `redirectSource` | `NullReturnValsMutator` on `return NO_CANDIDATE;` in the `if (!skipLocked)` arm | SURVIVED | **A second equivalent mutant the plan does not name.** On the recalc path `null` and `NO_CANDIDATE` both fall through `ensureValidSource`'s final `cancelOrder`, so the two are indistinguishable; the line is unreachable on the move path, where the difference would show. Behaviourally equivalent, not an untested assertion — the line **is** executed (SURVIVED, not NO_COVERAGE) |
| 586 `redirectSource` | `NullReturnValsMutator` on `return NO_CANDIDATE;` in the `newRequested <= 0` arm | NO_COVERAGE | A **pre-existing** uncovered branch. The line counts as changed only because `return false` became `return NO_CANDIDATE`; it is not a new assertion |

Mutants whose intent PIT confirmed, by mutator and line:

- **M-6** (invert the sign) — three `NegateConditionalsMutator`s on line 749, **all KILLED**.
- **M-6b** — `ConditionalsBoundaryMutator` on 749, **SURVIVED as predicted**.
- **M-11** (drop the `targetId != null` guard) — covered by the 749 negates, **KILLED**.
- **M-4** (collapse the two `targetStock == null` cases) — the `NegateConditionalsMutator` on
  `if (!skipLocked)` is **KILLED**.
- **M-9 / M-13** (the `existsById` disambiguation and its null guard) — both negates on that line
  **KILLED**.
- **M-10** (the no-heal premise) — the negate on the `PROCESSABLE` comparison **KILLED**.

Not reproducible by PIT, and not reproduced by anyone on disk: **M-1, M-2, M-5, M-8** (manual code or
fixture edits), **M-3** (a lane-wide property change), **M-7** (an annotation value — the executor
reports running this one), and **M-12** (dropping the primary `REDIRECT_CONTENDED` WARN — PIT filters
logging calls, so no `VoidMethodCallMutator` is generated for it). U-I exists, asserts on the exact
token `SBDEV-3637 REDIRECT_CONTENDED` with "exactly once", and is green; its attributable kill is
simply not independently witnessed.

**AC-11 as written claims *"Every new assertion is mutation-checked with an attributable kill except
the three §7.5 names"*. That claim is not supported.** What is supported: the §7.5 table is complete
against §7.2/§7.4 (14 rows, the three uncovered ones named), and the PIT-reachable half of it is
confirmed by this lane.

---

## 5. AC-13 / Fix G — the doc edits

All four Fix G targets landed:

- `design/wms2-replenishment-design.md` — "Who re-sources an order" **row 1 Locks cell** fully
  rewritten (it now names `findByIdForUpdateSkipLocked`, the `-2` hint, the descending/move rule, the
  `CONTENDED` defer and the WARN) and carries the scope limit plus the live
  `transferStockToUnitLoad` ABBA. The stale `verified_by` is corrected: SBDEV-3638 and SBDEV-3622 are
  now recorded as merged, each with the `merge-base --is-ancestor` SHA and a stated positive control.
  The **SBDEV-3621 residual bullet stands**, with the required explicit sentence: *"⚠ SBDEV-3637 does
  NOT close this residual, and must not be read as closing it."*
- `architecture/wms2-transaction-osiv-boundary-map.md` — §8.5 successor sub-bullet (carrying the
  residual **rule**, not a count) **and** a 2026-10-05 changelog row.
- `workflows/wms2-replenish-workflow.md` — the "three outcomes, not two" bullet **and** a changelog row.
- `architecture/wms2-function-to-docs-map.md` — §9 Replenishment row extended, `last_verified`
  deliberately not bumped, per house convention.

⚠ **Two further `sbdocs/` files are dirty in the working tree and are NOT this ticket's:**
`data-dictionary/wms2-sysprop-catalog.md` and `workflows/wms2-multi-unitload-replenish.md` both carry
**SBDEV-3641** content (`MsgUnitLoadSourceNotReplenishable`, branch
`bugfix/SBDEV-3641-multi-ul-source-eligibility`). Pre-existing, unrelated — flagged only so a blanket
`sbdocs` commit does not sweep them into SBDEV-3637.

---

## 6. The two off-plan checks the brief asked for

### `NeverMatcherNullBlindnessArchTest` (+11 lines, not in plan §5)

**Legitimate rail registration, not unscoped drift.** The change is a single allow-list count bump —
`"ReplenishmentOrderMaintenanceServiceUnitTest:7"` → `":10"` — plus ten lines of comment justifying
it. It is structurally identical to the `TestClassTransactionManagerArchTest` entries the plan *does*
anticipate, and it is **forced**: the three new `anyBoolean()` positions sit in U-F (two) and U-G
(one), all at argument 3 of `changeReservedAmount`, declared `boolean zeroIfNegative`. Without the
bump the rail goes red. The comment reads the signature at its declaration rather than inferring it
from the matcher name, and explains why `anyBoolean()` is required there (a bare `any()` returns null
and NPEs at unboxing). The rail class itself ran 4/4 green. Plan §5 is the thing that is incomplete,
not the diff.

### No test weakened, disabled, deleted or renumbered

`git diff origin/develop...HEAD -- 'src/test/**' | grep '^-'` returns **exactly 7 removed lines**.
Every one accounted for:

1. `- *   <li>make {@code redirectSource} never succeed → kills <b>AC2</b> and <b>AC8</b></li>` —
   replaced by a 13-line expansion splitting the mutant into `always NO_CANDIDATE` and
   `always CONTENDED`, exactly as plan §5 requires. **Strengthened.**
2. `- "ReplenishmentOrderMaintenanceServiceUnitTest:7",` — the rail bump above.
3–5. three comment lines in `…ReassignTest`, rewritten in place.
6. `- lenient().when(stockunitRepository.findByIdForUpdate((Long) candidateRow[0]))` — re-pointed to
   `findByIdForUpdateSkipLocked` because the move path is now unconditionally skip-locked.
7. `- lockOrder.verify(stockunitRepository).findByIdForUpdate(99L);` — became
   `findByIdForUpdateSkipLocked(99L)` **and gained a new complement**,
   `verify(stockunitRepository, never()).findByIdForUpdate(99L)`.

The SBDEV-3618 Fix D pin kept its ascending `42 → 99` fixture ids rather than flipping them to keep
the old line green — which is precisely the rewrite-not-renumber the plan demanded, and the in-code
comment says why a flip would have destroyed the pin's content.

`grep -nE "^\+.*@(Disabled|Ignore)"` over the test diff: **none added** (positive control: the same
token is found in 3+ existing test files, so the instrument works). `git diff --numstat` shows no test
file with deletions beyond the 7 lines above and no file removed. Failsafe's 31 skips and surefire's 1
are all pre-existing.

---

# PASS

Two criteria short of a clean sweep, neither blocking the code:

- **AC-9 — MISSING.** No IT-4. **To close:** add the starvation case to
  `integration/service/ReplenishmentOrderMaintenanceServiceIntegrationTest` — hold the target past one
  sweep with a non-autocommit holder, release, run the next `recalculateForItem`, assert the order is
  `PROCESSABLE` *with a source*. AC-9 already states it is bounded evidence rather than a proof, so
  this is a one-test gap, not a design hole. Alternatively, Nam strikes AC-9 and the plan records that
  Fix E's WARN token is the only instrument for starvation.
- **AC-11 — PARTIAL.** The AC claims blanket attributable kills; 7 of 13 mutants are manual-only and
  have no record. **To close:** either run M-1, M-2, M-5, M-8 and M-12 by hand and record each kill
  (M-3 and M-7 are lane/annotation mutants the executor reports having done), or narrow AC-11's
  sentence to *"the PIT-reachable mutants are killed; M-1/M-2/M-3/M-5/M-7/M-8/M-12 are manual and were
  checked at <date> / were not run"*. Also add the line-649 `NullReturnVals` survivor to §7.5 as a
  **second** documented equivalent mutant beside M-6b, so a future reader does not try to repair it.
- **AC-7 — PARTIAL, informational.** The post-fix half is fully proved by this lane. The pre-fix
  `40P01` half is a gate-time property that a squashed commit cannot carry; if that red-first record
  matters for the PR, the gate lane should attach its output.
