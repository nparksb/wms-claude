# Review — `79dc3642` "make IT-1e's two-leg interleaving deterministic"

Lane: `lane-relandreview` · 2026-10-05
Worktree: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3637-reland`
Subject: `79dc3642` only, +271/−65 in `src/test/java/net/aim_ai/wms/service/ReplenishRedirectLockOrderIT.java`.
Parent `089e88e7` (verbatim restore) not re-reviewed.

**Verdict: APPROVE-WITH-FIXES** — 1 MEDIUM + 4 LOW, all in prose/diagnostics. The mechanism is sound:
barrier 3 is correctly placed, cannot deadlock, and the retry boundary is drawn where the brief asks.

| Severity | Confidence | Finding |
|---|---|---|
| MEDIUM | HIGH (timings) / MEDIUM (exhaustiveness) | F1 — barrier-timeout message's headline diagnosis is unreachable under this lane's timeouts; residual 4 overstates the masking risk |
| LOW | HIGH | F2 — `size() == 2` retries the `>2` case instead of failing on it |
| LOW | HIGH | F3 — `bothSeized` asserted before `failures`, so a leg that dies before seizing reports the wrong cause |
| LOW | HIGH | F4 — "barrier-2 alone would have sufficed iff this reads 1" is a counterfactual the measurement cannot support |
| LOW | HIGH | F5 — residual 1 calls IT-2 CONTROL "a single-threaded probe"; it is not |

---

## The seven items, answered

### 1. Is barrier 3 actually before commit, with the source lock still held? — **YES**

`leg(...)` runs everything inside one `TransactionTemplate` callback:

> `new TransactionTemplate(tenantTransactionManager).execute(status -> {`
> `    stockunitRepository.findByIdForUpdate(stockUnitId).orElseThrow();`
> …
> `        sourceBarrier.await(60, TimeUnit.SECONDS);`
> `        move(unitloadId, laneId, moveBarrier);`
> `        commitBarrier.await(60, TimeUnit.SECONDS);`

`commitBarrier.await` is the last statement before `return null`, and `TransactionTemplate.execute`
commits only after the callback returns — so the await is strictly pre-commit. The source lock is
`findByIdForUpdate(stockUnitId)`, a `SELECT … FOR UPDATE` taken as the first statement of that same
transaction; PostgreSQL holds a row lock to transaction end, so it is still held at the barrier.
Both halves of the claim check out.

### 2. Can barrier 3 deadlock? — **Not on this fixture.** The skip-lock claim is true of the code, not just the comment

The load-bearing line is `ReplenishmentOrderMaintenanceService`:

> `boolean skipLocked = !recalcPath || targetIsBelowHeldSource(currentSource, candidate.stockUnitId);`

and the move path's only call site passes `recalcPath = false`:

> `if (redirectSource(order, lockedSource, share, false) == RedirectOutcome.NO_CANDIDATE) {`

`!recalcPath` short-circuits to `true`, so `findByIdForUpdateSkipLocked` is used unconditionally on
the move path. The comment block above it says the same thing ("move path -> SKIP LOCKED
unconditionally") and for once the comment and the branch agree.

I then enumerated the *other* lock acquisitions each leg can take between barrier 2 and barrier 3, to
check none of them is a blocking wait on a row the other leg holds. **Derivation:** `grep -n
"ForUpdate\|processTransfer\|advisory" src/main/java/.../UnitloadBusinessService.java` for the entry
method, plus a read of `reassignOrCancelForMovedStockUnit` and `redirectSource` end to end, plus
`git grep -n getNextSequenceNumber -- src/main/java` to check for a shared counter row.

| Acquisition | Shared between the legs? |
|---|---|
| `locationRepository.findByIdForUpdate(destination)` | **Not executed** — guarded by `if (!ignoreLock)`, and `move(...)` passes `ignoreLock = true` |
| `pickLineRealignmentService.lockOwningPickingorders(...)` | Reached (`CODE_MANUAL_TRANSFER` is BLOCK_REALIGN) but locks **nothing**: the fixture seeds no `pickingorder` rows |
| `replenishorderRepository.findByIdForUpdate(probeId)` | Disjoint — probe is `findIdByStateLessThanAndStockunitId(FINISHED, movedStock.getId())`, so leg A → O1, leg B → O2 |
| `stockunitRepository.findByIdForUpdate(movedStock.getId())` | Own source, already held — re-lock is a same-mode no-op |
| target acquisition | `findByIdForUpdateSkipLocked` — never waits |
| `SequenceTransactionService.getNextSequenceNumber` (`los_sequencenumber`, a genuinely shared row) | **Not on this path** — its six call sites are BOL, label printing, order/parcel monitor, picking order, replenish order; none is reached by `transferUnitLoadToLocation` |

So no leg can block before barrier 3, and the javadoc's "neither leg ever waits on a database lock"
holds for this fixture. **Blind spot, worth knowing but not a finding:** it holds *because* the
fixture seeds no picking orders — `lockOwningPickingorders` is a plain blocking `findByIdForUpdate`
and would become a shared edge if a future revision of `seedInvertedPair` ever gave both unit loads
stock backing the same picking order. The enumeration is complete for compiled Java call sites
reachable from `transferUnitLoadToLocation`; it is blind to anything reached reflectively or through
a Spring proxy whose target I did not open, and to triggers/rules in the DB.

### 3. The retry boundary — **correct**

Walking the loop body in order:

- `assertThat(observed.bothSeized()).isTrue()` → AssertionError escapes the loop → **immediate**.
- `assertThat(observed.failures()).isEmpty()` → **immediate**. `failures` is populated from the two
  `Future<Throwable>` results, and `leg(...)` ends in `catch (Throwable t) { return t; }`, so it
  catches everything including `Error`.
- A barrier timeout arrives as `IllegalStateException` from the
  `catch (BrokenBarrierException | TimeoutException e)` arm, i.e. inside `failures` → **immediate**.
  The arm ordering is safe: `await` throws only `InterruptedException`/`BrokenBarrierException`/
  `TimeoutException`, none of which is a `RuntimeException`, so the preceding
  `catch (RuntimeException e) { throw e; }` cannot swallow one.
- `a.get(120, TimeUnit.SECONDS)` timing out throws out of `runInvertedPairChoreography` (declared
  `throws Exception`) and out of the test → **immediate**, never retried.
- Only `interleaved = contendedLines.size() == 2` being false, with both assertions already passed,
  continues the loop.

That is exactly the single retryable condition the commit claims. A deadlock cannot be swallowed:
40P01 arrives as an exception on a leg, lands in `failures`, and fails on the attempt that produced
it. See **F2** for the one edge the equality test mis-routes.

### 4. `hasSize(2)` still strict — **YES**

> `.hasSize(2);`

Unchanged, on a `List<String>`. No `hasSizeBetween`, no `isNotEmpty`, no disjunction. The post-state
block below it is still six exact equalities (`replenState(O1)==PROCESSABLE`,
`boundStockUnit(O1)==S1`, `reserved(S1)` `isEqualByComparingTo(REQUESTED)`, and the O2/S2 mirrors) —
no "either redirected or deferred" anywhere. The in-code warning against weakening it is now carried
twice (comment + assertion message), which is appropriate given it was the rejected revision.

### 5. The blocked-backend snapshot — **does not throw, does not swallow, and distinguishes three readings**

- **Never throws:** the whole body is a try-with-resources wrapped in `catch (Exception
  diagnosticFailed)`. `open()` declares `throws SQLException`, and a null
  `AppPostgresDBContainer.container` would give an NPE — both are `Exception` and both land in the
  UNAVAILABLE branch. It is called inside a string concatenation that builds an
  `IllegalStateException` whose `cause` is the original barrier exception, so it cannot replace the
  failure it describes.
- **Three readings are genuinely distinct:** non-zero → "the blocking-acquisition regression";
  zero → "no row-lock wait was in progress"; the `catch` → "UNAVAILABLE — the snapshot query itself
  failed … this says nothing either way". A bare `0` that means "probe broken" is not reachable.
- **It scans the right database.** `open()` is `DriverManager.getConnection(c.getJdbcUrl(), …)`
  against `AppPostgresDBContainer`, and the filter is `datname = current_database()`. That this is
  the same database the tenant pool routes to is established by IT-2, which parks a `FOR UPDATE` on
  an `open()` connection and measures the tenant-side worker blocking on it — that test is green, so
  the two connections see the same rows. `WHERE datname = current_database()` therefore cannot
  silently filter everything out.
- **Does not use a pooled connection**, so it cannot itself deepen a pool stall.

One way it *can* mislead is covered under **F1**.

### 6. The five residuals — four TRUE, one overstated; one wording error

1. *Does not prove each leg took the changed edge* — **TRUE.** IT-1e grades only the two
   `REDIRECT_CONTENDED` lines; an always-skip-locked implementation satisfies it, and only
   `ascendingEdgeRedirect_blocksHoldingItsEarlierLocks` (which asserts `blockedStatement()`
   `.isNotNull()`) separates them. See **F5** for the "single-threaded" wording.
2. *Does not prove production ever interleaves this way* — **TRUE.**
3. *The 2-leg count is read from a LOG TOKEN* — **TRUE**, and the sharpest of the five: the
   post-state assertions all describe a do-nothing state, so a service that logged the token without
   taking a lock would pass the whole test. Correct to call the token load-bearing and untested.
4. *Barrier 3 can disguise a real regression as a harness timeout* — **overstated.** See **F1**.
5. *Scheduling is constrained, not eliminated* — **TRUE.**

**Nothing material missing** that I found, measured as: I re-derived each residual against the code
it names, then looked for a sixth by asking what else a reader of a red would need. The nearest
candidate is already implied by residual 3 (the appender is attached to the
`ReplenishmentOrderMaintenanceService` logger, so a concurrent recalc on another thread in the same
context would inflate the count) — but the IT context runs no scheduled jobs, so I did not raise it.

### 7. Token matching — **exact and disjoint**

`linesContaining(captured, "SBDEV-3637 REDIRECT_CONTENDED")` filters with `m.contains(token)` over
`getFormattedMessage()`. `git grep -n "REDIRECT_CONTENDED\|REDIRECT_NO_HEAL" -- src/main src/test`
(positive control: the grep returns 17 hits across 3 files, so it is not a broken-instrument zero)
shows exactly one producer of each in `src/main`:

> `LOG.warn("SBDEV-3637 REDIRECT_CONTENDED replenishOrder={} target={} path={} state={}",`
> `LOG.warn("SBDEV-3637 REDIRECT_NO_HEAL replenishOrder={} state={} — no recalc sweep selects"`

`…REDIRECT_NO_HEAL…` does not contain the substring `SBDEV-3637 REDIRECT_CONTENDED`, so the count
cannot pick it up. The appender is attached to the service's own logger, not ROOT, so another class
logging the same literal cannot inflate it. The in-code warning about keeping the token exact is
preserved and now appears at both the assertion and the class javadoc.

---

## Findings

### F1 — MEDIUM — the barrier-timeout message's headline diagnosis is unreachable under this lane's timeouts

`ReplenishRedirectLockOrderIT.leg`, barrier-timeout arm:

> `"if BOTH legs timed out here, the likeliest cause is NOT a slow machine. It is that the move "`
> `+ "path's target acquisition became BLOCKING again (skip-locked removed or bypassed). Both legs "`
> `+ "then block holding their own source, neither reaches this barrier…"`

That cannot happen in this lane. `src/test/resources/application-postgres-integration.properties`
sets `wms.tenant.lock-timeout-ms=10000`, and `deadlock_timeout` is PostgreSQL's 1000ms default
(`src/main/resources/application.properties` records it as measured on Hydra prd and WineCo UAT;
IT-1a asserts the ordering directly). So if the target acquisition became blocking again:

- **mutual block** (the described shape) → PostgreSQL's detector fires at ~1s → `40P01` on one leg →
  lands in `failures` → the `isEmpty()` assertion fires, with a message already written for exactly
  that case;
- **one-sided block** → `55P03` at 10s → same path.

Either way a leg dies 50 seconds before the 60s barrier could expire. The regression surfaces at the
`failures` assertion, not as a harness timeout — the opposite of what the message tells the reader,
and `blockedBackendSnapshot()` would report **zero** in both cases because the blocked backend has
already errored out by the time the surviving leg's barrier expires. Residual 4 in the class javadoc
inherits the same overstatement.

*Why it matters:* this is a message written specifically to stop a reader dismissing a red as flaky
infrastructure. Pointed at a cause the configuration rules out, it sends them to re-verify
skip-locked (which will be fine) while the actual cause — a leg dead before its await, a pool stall,
or an acquisition on a path where `SET LOCAL lock_timeout` is not seated — goes unexamined.

*Remedy:* reword the arm and residual 4 to:
- state that a reinstated blocking acquisition surfaces as `40P01` (~1s) or `55P03` (10s) on the
  `failures` assertion, not here, and name IT-1a as what pins that ordering;
- state that a 60s barrier timeout therefore means something **else**: a leg that died before
  reaching its await, a connection-pool stall, or a lock acquisition that `SET LOCAL lock_timeout`
  does not reach;
- keep the snapshot, but add that a **zero does not exclude** a blocking regression that already
  aborted — it only says nothing was waiting at the instant of the timeout.

*Confidence:* HIGH that the three timeouts are 1s / 10s / 60s and ordered that way. MEDIUM that
*nothing* on this path can block past 60s — derived by enumerating lock acquisitions reachable from
`transferUnitLoadToLocation` (table in §2); blind to acquisitions I did not open and to any statement
running outside the tenant transaction manager, where the `SET LOCAL` bound does not apply.

### F2 — LOW — `size() == 2` retries the `>2` case instead of failing on it

> `interleaved = contendedLines.size() == 2;`

Three or more `REDIRECT_CONTENDED` lines in one attempt is not the scheduling artefact the retry
exists for — it is a new production behaviour (a second redirect attempt per leg) and a real signal.
Today it falls into the retry branch, logs "did NOT interleave (3 REDIRECT_CONTENDED line(s), no
failures)", re-seeds, and burns all three attempts before failing at `hasSize(2)` with a message
claiming the choreography "never interleaved". The end state is still red, so nothing ships broken —
but the diagnosis handed to the reader is wrong and three times slower than it needs to be.

*Remedy:* `interleaved = contendedLines.size() >= 2;` — `>2` then falls straight through to
`hasSize(2)` and fails on the attempt that produced it, like every other non-scheduling signal.

### F3 — LOW — `bothSeized` is asserted before `failures`, so a leg that dies before seizing reports the wrong cause

The `bothSeized` assertion runs first and its message does not include `observed.failures()`. If a
leg throws before `seized.set(true)` — e.g. `findByIdForUpdate(stockUnitId).orElseThrow()` on a
fixture that did not commit — the other leg waits out barrier 1, both end in `failures`, and the red
the reader sees is "NON-VACUITY: both legs must have taken their OWN source lock", with the actual
exception nowhere in the output.

*Remedy:* either assert `observed.failures()).isEmpty()` **first** (an exception is strictly more
informative than a derived boolean), or append `" Failures: %s"` + `observed.failures()` to the
`bothSeized` message. The first is cleaner and matches the ordering the class javadoc already
implies.

### F4 — LOW — "barrier-2 alone would have sufficed iff this reads 1" is unsupported

> `log.info("SBDEV-3637 IT-1e: interleaving {} after {} attempt(s) of {} (barrier-2 alone would "`
> `        + "have sufficed iff this reads 1", …`

With barrier 3 in place, an attempt count of 1 is the *expected* reading precisely because barrier 3
forces the interleaving — it says nothing about whether barriers 1–2 alone would have. The
parenthetical invites the next reader to conclude barrier 3 is redundant, which is the exact change
that produced the incident this commit is fixing.

*Remedy:* `"(barrier 3 should make attempt 1 sufficient; any count above 1 is itself a finding worth "
+ "reporting)"`.

### F5 — LOW — residual 1 describes IT-2 CONTROL as "a single-threaded probe"

> `*       so in a single-threaded probe, not here.</li>`

`runRecalcProbe` opens two raw `java.sql.Connection`s (`holder`, `observer`), parks a non-autocommit
`FOR UPDATE` on one, runs `recalculateForItem` on a **single-thread executor**, and polls
`pg_stat_activity` from the main thread. That is three threads of execution and a deliberately
concurrent lock holder. The distinction residual 1 is actually drawing is that IT-2 has **one
service-under-test worker against a parked holder**, not two symmetric legs.

*Remedy:* "…and it does so with a single worker against a parked holder connection, not with two
symmetric legs."

---

## Positive observations

- **Barrier 3 is placed at the only point that works.** Inside `execute`, after `move(...)` returns,
  before the lambda does. One statement earlier (inside `move`, after the transfer) would have been
  equivalent; anywhere outside `execute` would have been useless. The javadoc explains *why* the
  placement is load-bearing rather than just asserting it.
- **The deadlock-freedom argument is stated as a property of the production branch, not of a
  comment**, and the branch (`!recalcPath ||`) actually has that property. That is the
  invariant-over-instance form.
- **Discovery and decision are separated cleanly.** `runInvertedPairChoreography` returns an
  `Interleaving` record and asserts nothing; the caller decides what is retryable. This is what makes
  the retry boundary auditable at all, and it is a strictly better shape than the inline version it
  replaces.
- **Fresh `CyclicBarrier`s and a fresh `ListAppender` per attempt.** A reused barrier would stay
  broken across attempts and a reused appender would accumulate lines across them — both would have
  produced exactly the kind of false green this class exists to avoid. The record's javadoc says so
  explicitly ("A fresh appender per run, so the lines are per-run").
- **The re-seed is justified rather than assumed:** `seedTopology()` opens with `wipe()`, and the
  same `wipe()` already runs in `@AfterEach` **after** committed leg moves on every green run — so
  the mid-test re-seed is covered by the same evidence that keeps the class green today.
- **`hasSize(2)` is defended in two places**, and the rejected "either redirected or deferred"
  disjunction is named in the javadoc with the reason it was rejected. That is the right way to stop
  a weakening from being re-proposed.
- **`blockedBackendSnapshot()` cannot replace the failure it describes** — it is concatenated into
  the message while the original barrier exception stays as `cause`.
- **The "What this test does NOT guarantee" block is genuinely useful**, and residual 3 in particular
  is a limit most authors would not have written down.

## Instruments and their limits

- `lsp_diagnostics` is **unavailable** in this environment (`Language server 'jdtls' not found`), so
  type safety is not independently confirmed here. It is covered by the evidence supplied with the
  brief: the full suite on this branch reports BUILD SUCCESS with surefire 7814/0F/1S and failsafe
  635/0F/31S, which cannot happen if this file does not compile.
- Per the brief I did **not** run Maven. Nothing I found contradicts the supplied run evidence; the
  five-green-runs result is consistent with barrier 3 making the first attempt interleave, which is
  what the mechanism predicts.
- Every "only/never/exactly/no" sentence above carries its derivation inline; the two that carry real
  blind spots are the §2 lock enumeration (compiled Java call sites reachable from
  `transferUnitLoadToLocation`; blind to reflective/proxy dispatch I did not open) and F1's
  exhaustiveness claim.

---

**APPROVE-WITH-FIXES** — F1 should be fixed before this lands (it is the message a future reader will
be standing in front of during an incident); F2–F5 are cheap and this repo fixes Lows in the same
pass.
