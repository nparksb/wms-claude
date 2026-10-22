# SBDEV-3637 — final claim check on `38250904`

**Scope:** the eighth version of the barrier-timeout claim, as written in
`src/test/java/net/aim_ai/wms/service/ReplenishRedirectLockOrderIT.java` (class javadoc residual 4,
the `leg(...)` barrier-timeout arm, `blockedBackendSnapshot()`, the post-loop log).
Read-only; no Maven run. Worktree `.claude/worktrees/wms2-api/SBDEV-3637-reland`.

**VERDICT: CLAIM SOUND** — two MINOR narrowings below, neither of which changes the diagnosis a
reader following the text would reach.

---

## Clause-by-clause

**1. Regression ⇒ BOTH a `40P01`/`55P03` AND a 60s barrier timeout — TRUE.**
Traced in the post-commit file. Barrier 2 is inside the move, immediately before the transfer:
`beforeTransfer.await(60, TimeUnit.SECONDS);` then
`unitloadBusinessService.transferUnitLoadToLocation(ul, dest, true, MOVE, …)`. So both legs clear it
and block mutually. The victim's `RuntimeException` hits `} catch (RuntimeException e) { throw e; }`
and the leg returns through `catch (Throwable t) { return t; }` — it never reaches
`commitBarrier.await(60, TimeUnit.SECONDS);`. The survivor takes the freed lock, finishes, and waits
that barrier out. Both Throwables are collected unconditionally in `runInvertedPairChoreography`
(`if (outcomeA != null) { failures.add(outcomeA); }`, same for B), so both land in `failures`.
Timing fits the enclosing `a.get(120, TimeUnit.SECONDS)`: ~1s (detector) or 10s (`lock_timeout`)
plus the 60s barrier ≈ 61–70s < 120s, so the futures do not time out and the assertion is reached.

**2. A non-arriving thread does not break a `CyclicBarrier`; nothing here calls `reset()` — TRUE.**
`CyclicBarrier` breaks on interrupt, on a *waiting* party's timeout, on `reset()`, or on a barrier
action throwing — never on a party that simply never arrives. Sweep: `git grep -n "reset("` on this
file returns 2 hits, both inside the two prose sentences themselves; positive control `await(`
returns 4 lines in the same file, so the instrument fires. The only interrupt source,
`pool.shutdownNow()`, runs in the `finally` after both `get(...)` calls, so it cannot precede the
timeout.
*Stronger invariant worth preferring over "nothing here":* all three barriers are locals of
`runInvertedPairChoreography()` and never escape it, so no site anywhere can reset them. That
version survives a future edit elsewhere in the class; "nothing here calls reset()" does not.

**3. The companion entry is the discriminator, and the reader sees it — TRUE. Checked hardest.**
`failures` is asserted FIRST inside the retry loop (`assertThat(observed.failures()) … .isEmpty()`),
before `bothSeized` and before the post-loop `hasSize(2)`, so in the regression shape it is the
assertion that fires. Its own description renders `SQLSTATEs raised: %s` from
`sqlStates(observed.failures())` *and* `Failures: %s` — the whole list. Both entries are therefore
rendered by one assertion, and `SQLSTATEs raised:` sits earlier in that same string than the
timeout text embedded in the `Failures:` list, so "one screen above" is literally the reading order.
Nothing can fire ahead of it: the only earlier exit is a `get(120s)` timeout, which the ~70s worst
case does not reach.
Blind spot the text does not state: `sqlStates` walks `getCause()` only ("Mirrors
`ReplenishmentOrderMaintenanceService.hasSqlCause`: the getCause() chain only"), so a driver
exception reachable only via `getNextException` would print `SQLSTATEs raised: []` while the
companion entry is still in the list. The two sentences then disagree — one keys the discriminator
on the SQLSTATE, the next on list membership ("standing ALONE in the failure list"). The realistic
Spring/Hibernate chain (`…DataAccessException` → `JDBCException` → `PSQLException`) does put it in
`getCause()`, so this is narrow, not a falsifier.

**4. IT-1a pins only `lock_timeout > deadlock_timeout`, nothing about the 60s barrier — TRUE, with
one inaccuracy in "only".** `tenantLockTimeoutExceedsDeadlockTimeout()` contains exactly two
assertions: `.isPositive()` and `.isGreaterThan(deadlockTimeoutMs)`. It never names 60s. The "only"
drops the `isPositive()` control, which is subsumed by the inequality and so harmless — but a
sentence whose point is that the previous version overclaimed should not itself say "only" about a
method with two assertions.

**5. A non-zero `blockedBackendSnapshot()` means *some* backend was waiting — TRUE, one word too
wide.** The query is `WHERE datname = current_database() AND cardinality(pg_blocking_pids(pid)) > 0`
— database-scoped, no pid and no fixture filter, exactly as the text says. The cited comparison is
real: `readBlockedBackend` does assert *"exactly ONE backend may be blocked by this test's holder"*
and filters `holderPid = ANY(pg_blocking_pids(pid))`.
Narrowing: the text says *"a stranger sharing this reused container counts too"*. The filter is the
**database**, not the container — a stranger on the same container but another database does not
count. The error is in the conservative direction (it tells the reader to doubt more than the query
requires), but say "a stranger on this same database".

**6. The post-loop log prints the observed count, not a success word — TRUE.** It now formats
`contendedLines.size()`, and `.hasSize(2)` below grades it; a 3 prints as 3 and then fails. No
contradiction is constructible.

---

## The three failure classes that produced the previous seven

**Sentences asserting what something CANNOT be:** none in the new text. Both rewritten sites are
framed as "read it together with the other entry" and name the mechanism by which the regression
*does* reach the message. The one residual absolute is an **identity** claim rather than a negation:
*"a 40P01 or 55P03 there IS that regression"* (and the javadoc's *"a 40P01/55P03 there IS the
regression"*). It carries no blind spot, and the plan's own §P-7 records a second, knowingly-unfixed
ROLE-order ABBA (`StockunitBusinessService.transferStockToUnitLoad`) that raises the same SQLSTATE.
Suggested narrowing: *"…is that regression's signature; confirm the blocked statement before
concluding, since any ABBA reached from this path raises the same SQLSTATE."*

**Completeness words without derivation/blind spot inline:** `only` (clause 4, see above), `never`
and `nothing` in *"a thread that never calls await does not break a CyclicBarrier, and nothing here
calls reset()"* (true; derivation is one grep, blind spot is the class scope — prefer the locals
argument), and `ALONE` in the discriminator sentence (true, but its blind spot is the `getCause()`-
only extraction noted in clause 3).

**Did the correction land in all sites — YES, no survivor.** Wrap-tolerant sweep (javadoc `*` and
Java `" + "` continuations unwrapped before matching; 1773 `.java`/`.md` files under the worktree
`src`, `sbdocs/1-Projects/wms2/plan` and `sbdocs/3-Resources`) for `cannot reach this barrier`,
`never as a harness timeout`, `IT-1a pins that`, `timeout … means something ELSE`, `NON-ZERO …
move path is blocking`, `ACHIEVED`, `before this 60s barrier could expire`. Positive control
(`barrier`) fired on 23 files, so the instrument works. Live hits: **zero**. Every match for the
retired phrasings is inside `review-reland-fixes.md` / `review-reland-test.md`, which quote them as
findings — the record of the defect, not a copy of it. The plan document
`SBDEV-3637-replenish-redirect-lock-order.md` carries no version of this diagnosis at all. The
sibling javadoc at `leg(...)` — *"A leg that dies before any await leaves the other waiting; that
await expires at its 60s timeout and is re-thrown as a FAILURE"* — already agreed with the new text
and needed no edit.

---

**VERDICT: CLAIM SOUND**
