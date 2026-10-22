---
ticket: SBDEV-3458
lane: independent review of the CORRECTED revision (third review; this commit never reviewed)
reviewer: final2-3458 (Opus 5, 1M)
date: 2026-09-23
worktree: /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3458-final2 (detached)
head: 7aa1d455
predecessors: dec515f0 (reviewed, CHANGES REQUESTED) <- 8cb3d5b8 (reviewed, CHANGES REQUESTED)
base: origin/develop @ b87ec747
pr: "#399 (v2/wms2-api)"
verdict: CHANGES REQUESTED (claims only) — the Java is correct and PR #399 is safe to merge
---

# SBDEV-3458 — review of `7aa1d455`

## Verdict

**The code is correct and PR #399 is safe to merge.** `7aa1d455` is test-only, touches one
file, compiles clean, closes four of the prior lane's seven findings, and does not weaken the
SBDEV-2232 proof in any way I could construct. The pool-shutdown hardening is a net
improvement and — importantly — **cannot make the failure output worse**, for a reason the
commit does not give.

**CHANGES REQUESTED on the claims.** The false sentence this revision exists to remove is
gone and the correction is honest about why. But the defect *class* recurred in a new form,
which is exactly what I was asked to look for: **the commit's "WHAT FIXES IT" attribution is
unscoped, and its scope excludes the container the commit's own headline verification ran
against.** On that container it is the run-unique keys — demoted in the message to "defence in
depth for CONCURRENT builds" — that make the run green, not the `@AfterEach`. Finding 1.

Finding 2 is a second prose overclaim, in the new pool-shutdown comment: it states a guarantee
`shutdownNow()` cannot provide and attributes it to a failure mode in which the branch it
guards cannot execute.

Neither requires a code change. Both are an amend.

## Summary

| # | Severity | Finding | Brief item | Fix |
|---|---|---|---|---|
| 1 | **Medium** | "WHAT FIXES IT is the `@AfterEach`" / "the keys are defence in depth for CONCURRENT builds" is true only on a *clean* container. On the polluted container the commit's own `VERIFIED` bullet 1 used, the keys are what make it green and the hook alone would be red on run 1. The javadoc's orphan-tolerance argument silently depends on the keys being load-bearing. | 1, 5 | amend |
| 2 | Low | The pool-shutdown comment claims interrupting means "no `FOR UPDATE` lock outlives the test" (interrupts do not unblock pgjdbc socket I/O), names a failure mode in which the branch cannot run, and says the second failure lands "on top of the real one" (JUnit 5 attaches it as *suppressed*, and the real assertion is checked first). | 2, 5 | amend/comment |
| 3 | Low | `pool.awaitTermination(5, TimeUnit.SECONDS)` at line 250 discards its return — in a change whose stated defect is "awaitTermination's return was discarded". | 2, 5 | 1 line |
| 4 | Low | Commit message: "there is no before-hook **at all** now". `BasePostgresIntegrationTest:87` carries an inherited `@BeforeEach baseSetUp()` that JUnit runs. It only logs, so the substantive claim survives; the javadoc's narrower "no before-hook **here**" (line 105) is correct. | 1, 5 | amend |
| 5 | Low | Three prior-lane Lows carried forward unaddressed (its findings 3, 4, 6) against the standing "fix Lows in the same pass" rule. Verified each still open. | — | javadoc |
| 6 | Info | **Claim 1 holds.** The design structurally cannot repair pre-existing residue — verified three independent ways. Nothing in the file or message implies it can. | 1 | — |
| 7 | Info | **Claim 3 holds.** The null resets were genuinely dead. No `@TestInstance` anywhere in the hierarchy, no `junit-platform.properties` in the repo, no lifecycle override in the pom, one `@Test`, no `@RepeatedTest`. | 3 | — |
| 8 | Info | **Claim 2 holds.** `BasePostgresIntegrationTest` is Testcontainers-backed; `BaseIntegrationTest` really is the H2 one. Bonus: the old `{@link}` did not resolve, the new one does. | 4 | — |
| 9 | Info | **The SBDEV-2232 proof is intact.** The delta is confined to lines between the latch waits and the assertions; nothing it touches feeds an assertion. | 6 | — |
| 10 | Info | **The pool-shutdown trade lands in favour of the change** — it cannot corrupt a passing run and cannot mask a real failure. The reason is assertion *ordering*, which the comment does not mention. | 2 | — |
| 11 | Info | Every other factual claim re-verified true, independently of the prior lane. | 5 | — |

**Instruments.** `mvn -o -q test-compile` → **EXIT 0** in this worktree. `pgrep -fl
"maven|surefire|failsafe"` → empty before starting. **I ran no `verify` and no integration
test**; no Testcontainers connection was opened by this lane. One negative result in this
review (`find` for `junit-platform.properties`) carries a positive control; one grep was
mangled by zsh globbing (`--include=*.java` → `no matches found`) and was re-run quoted rather
than read as a zero.

---

## 1. (Medium) "What fixes it" is unscoped, and its scope excludes the commit's own headline verification

Commit message:

> ```
> WHAT FIXES IT is the @AfterEach, which deletes by the ids captured at seed time.
> ```
> ```
> The run-unique nanoTime keys are defence in depth for CONCURRENT builds.
> ```

`ParcelMonitorViewServiceConcurrencyIT.java:87-90`:

```java
 * <p><b>What actually fixes the reported bug is the {@code @AfterEach} below</b>, which deletes
 * by the ids captured at seed time. Measured: reverting these keys to fixed literals while
 * keeping that hook leaves the class green over repeated runs, because no residue is ever left
 * to collide with.
```

And the same message's lead verification bullet:

> ```
>   - Against a container deliberately seeded with the legacy PARCELMON-ORD-1 row:
>     three consecutive `verify` runs GREEN (46.0s / 42.2s / 64.5s).
> ```

**These do not compose.** Run the stated experiment — fixed literals, hook kept — on *that*
container:

1. Legacy `PARCELMON-ORD-1` is present (the commit says it seeded one deliberately).
2. The seed inserts `externalnumber = 'PARCELMON-ORD-1'` (`PgLaneFixtures.order(..., String
   externalNumber)` → `co.setExternalnumber(externalNumber)`, line 160).
3. `index_customerorder_externalnumber UNIQUE (externalnumber)` fires at flush, inside the
   `REQUIRES_NEW` seed transaction. Verified non-deferrable at
   `V2.2.00__base_v2_schema.sql:3308`.
4. **Run 1 is RED.** The `@AfterEach` never gets a chance; the hook cannot fix a collision that
   happens before it runs, and it deletes only ids it minted, so it can never remove the legacy
   row on a later run either.

So on the polluted container, **the run-unique keys are what makes the build green**, and the
`@AfterEach` prevents *further* accumulation. The message's attribution is inverted for that
case, and demoting the keys to "defence in depth for CONCURRENT builds" excludes their actual
primary role on every machine that hit this bug — because a machine that hit it is by
definition polluted.

The javadoc already depends on this without saying so. Lines 119-122:

```java
 * <p>⚠ Containers polluted by the old fixed-literal runs keep one orphaned
 * {@code PARCELMON-ORD-1} row. It is harmless and is deliberately NOT purged here: nothing
 * generates that key any more, so it can never collide
```

*"Nothing generates that key any more"* is true **only because of the run-unique keys.** So one
paragraph treats them as load-bearing for the sequential polluted case while another, thirty
lines above, calls them concurrency-only defence in depth. Both cannot be the whole story.

**Is the claim flatly false?** No — and I want to be fair about that. On a *clean* container the
`@AfterEach` alone does fix the reported regression (run 1 seeds and cleans, run 2 seeds and
cleans, green forever), and that is presumably the container the "Measured:" sentence used. The
defect is that **the scope is never stated, and the commit's own headline evidence sits outside
it.** A reader who takes "WHAT FIXES IT is the @AfterEach" at face value and reverts the keys —
the exact edit the sentence invites — breaks the build on any machine that ever ran the old
fixture.

This is the same species as the sentence this revision removed: a confidently-worded claim
whose supporting condition is not in the code the reader is looking at. Different mechanism,
same shape, and it is in the load-bearing position. The repo has this recorded: *fixing a false
claim tends to produce a new one.*

**What to do.** Two clauses:

- Message: *"On a clean container the `@AfterEach` alone is sufficient (measured). On a
  container already polluted by the old fixed-literal runs — which is every machine that hit
  this bug — the run-unique keys are what make it green, because the hook cannot pre-empt a
  collision at seed time. Both are required; the keys additionally cover concurrent builds,
  and that part is reasoned, not reproduced."*
- Javadoc line 88: scope the "Measured:" sentence with *"on a clean container"*.

---

## 2. (Low) The pool-shutdown comment states a guarantee the mechanism does not provide

Lines 240-251:

```java
        // ⚠ shutdown() does not interrupt, and the return of awaitTermination was previously
        // discarded — so when this test fails for the reason it exists to catch, a pool thread could
        // still be holding its FOR UPDATE lock when @AfterEach runs. The purge would then block on
        // that row until wms.tenant.lock-timeout-ms (10 s, seated on the tenant EMF in
        // TenantDatabaseConfig) expired, and throw a second, louder, misleading failure on top of
        // the real one. There was no after-hook to collide with before SBDEV-3458 added one.
        pool.shutdown();
        if (!pool.awaitTermination(5, TimeUnit.SECONDS)) {
            LOG.warn("pool did not terminate in 5 s — interrupting, so no FOR UPDATE lock outlives the test");
```

Three separable overclaims.

**(a) "interrupting, so no `FOR UPDATE` lock outlives the test."** `shutdownNow()` calls
`Thread.interrupt()`. A thread parked in `Thread.sleep(300)` (line 198) or
`CountDownLatch.await` (line 214) unblocks. A thread parked inside pgjdbc waiting on a row lock
**does not** — pgjdbc reads from a plain blocking `java.net.Socket`, and Java interrupts do not
unblock plain socket I/O. So the mechanism covers the two parking spots that are *not* holding a
DB lock, and does not cover the one that is. The `LOG.warn` string asserts the opposite.

**(b) "when this test fails for the reason it exists to catch."** The reason it exists to catch
is `findByIdForUpdate` returning a stale snapshot instead of blocking (lines 265-271). That
failure is *fast*: thread 2 returns immediately with `PACKED`, both `finally` blocks run, both
latches drop, `awaitTermination` succeeds in microseconds, and the branch never executes. The
assertion at 268 then fails cleanly. For the branch to run at all, a thread must overrun its
10 s latch — which means a DB stall, i.e. precisely case (a), the non-interruptible one. **The
branch is inert in the failure mode it names.**

**(c) "throw a second, louder, misleading failure on top of the real one."** JUnit 5 collects
the test method's throwable and the `@AfterEach` throwable into one `ThrowableCollector` and
attaches the latter as a **suppressed** exception under the former. It is reported *underneath*
the real failure, not on top of it. (The prior lane used the same "louder" framing, so this was
inherited rather than invented; it is still not what JUnit does.)

**Which way does the trade land? In favour of keeping the change — and for a reason the comment
does not give.** I checked both directions the brief asked about:

- **Can interrupting make the output worse — a spurious interrupt exception masking the real
  assertion?** **No, and this is structural rather than lucky.** The branch runs only when
  `awaitTermination` times out, which requires at least one runnable still in flight, which
  requires `t1Done` or `t2Done` to be `false`. Those two are asserted at lines **253-254**,
  *before* `thread1Err`/`thread2Err` at 258-259 and before every state assertion. AssertJ aborts
  on the first failure, so the reported failure is always *"Thread 1 committed within 10 s →
  expected true"* — the real cause. Any `InterruptedException` the interrupt provokes lands in
  `thread1Err`, which is never reached.
- **Can it corrupt a passing run?** **No.** Both latches count down in `finally` blocks, so
  `t1Done && t2Done` implies both runnables are at their last statement and the pool terminates
  in microseconds. The 5 s window cannot expire on a healthy run, so a healthy thread is never
  interrupted.

So: keep the code, fix the words. Something like *"`shutdown()` does not interrupt and the
`awaitTermination` result was discarded, so a wedged pool thread could still be inside its
transaction when `@AfterEach` runs; the purge would then block on that row for
`wms.tenant.lock-timeout-ms` (10 s on this profile) and JUnit would attach the lock-timeout as a
suppressed exception under the real failure. `shutdownNow()` releases the two interruptible
parking spots (`Thread.sleep`, `CountDownLatch.await`); a thread blocked inside the JDBC driver
is not interruptible and will still have to wait the lock out. The `t1Done`/`t2Done` assertions
below deliberately precede every other assertion so that the real cause is reported first."*

---

## 3. (Low) The second `awaitTermination` return is also discarded

```java
            pool.shutdownNow();
            pool.awaitTermination(5, TimeUnit.SECONDS);
```

Line 250. The stated defect being fixed is *"awaitTermination's return was discarded"* — and the
fix reintroduces it one line below. There is genuinely nothing further to escalate to, so this
is presentation, not behaviour. Either log the result or say in the comment that the second wait
is best-effort. (Total worst-case cost here is 20 s of latch waits + 10 s of termination waits
before `@AfterEach`; bounded, and only on an already-failing run.)

---

## 4. (Low) "There is no before-hook at all now" is literally false

Commit message:

> ```
>     - A @BeforeEach purging by NAME. … Deleting by captured id cannot do that, so there is
>       no before-hook at all now.
> ```

`BasePostgresIntegrationTest.java:87-90`:

```java
    @BeforeEach
    void baseSetUp() {
        log.debug("Starting PostgreSQL integration test: {}", getClass().getSimpleName());
    }
```

JUnit runs inherited `@BeforeEach` methods, so one does execute. It only logs, so the
substantive point — *nothing purges by name* — is intact, and the javadoc's own phrasing at line
105 (*"which is why there is no before-hook **here**"*) is precise and correct. Raising it only
because on this ticket the message is reviewable text and "at all" is a completeness word.

---

## 5. (Low) Three prior-lane Lows carried forward unaddressed

`7aa1d455` closes the prior lane's findings **1, 2, 5 and 7**. It leaves **3, 4 and 6** open.
Against the standing rule (Nam, 2026-08-26: fix Low findings in the same pass), a fourth
revision that does not take them is a choice worth stating rather than a gap worth hiding.
Verified each still open in this worktree:

| Prior # | Finding | Status at `7aa1d455` |
|---|---|---|
| 3 | The orphan claim undercounts by one row | **Partially closed.** Line 75 now names both literals in the *history* paragraph. The *orphan* paragraph at 119-120 still says *"keep one orphaned `PARCELMON-ORD-1` row"* — singular, order only; the stranded `customerorder_batch` row is still unmentioned there, and the commit message's own mutation note says "1 customerorder + 1 customerorder_batch". |
| 4 | 55 lines of design javadoc hang off `private static final String KEY_PREFIX` | **Open.** Now ~54 lines (70-124) on a `String` constant equal to `"PARCELMON-"`. The class javadoc gained the H2 correction but none of the design narrative. |
| 6 | Nothing documents *why* the `REQUIRES_NEW` purge is safe, and it is conditional | **Open.** `grep` over `deleteCommittedFixture`'s javadoc (130-141) for `outer|suspend|test transaction` → **0**. The hook is safe only because every touch of these rows in the test body is itself inside `requiresNewTx()`; one plain repository call in the test body would enlist in the outer test transaction, take the row lock, and make the suspended-sibling DELETE block on its own test — a 10 s stall and a lock-timeout in an after-hook. |

---

## 6. (Info) Claim 1 holds — the design structurally cannot repair residue, and nothing says otherwise

The brief's headline question. Confirmed three independent ways:

| Could anything repair pre-existing residue? | Evidence |
|---|---|
| A `@BeforeEach` in the class | **None.** The only hook is `@AfterEach deleteCommittedFixture()` (line 142). |
| An inherited `@BeforeEach` | `BasePostgresIntegrationTest:87` — exists, but is `log.debug(...)` and nothing else. |
| The Testcontainers extension | `AppPostgresDBSetupExtension implements BeforeAllCallback` only; its own javadoc says *"it starts and migrates, and nothing more."* No `TRUNCATE`, no Flyway `clean`, no `DELETE`. |
| The `@AfterEach` itself | `findById(seededOrderId)` / `findById(seededBatchId)` — ids minted this run. No name predicate, no `deleteAll`, no query. Cannot reach a row it did not create. |

And the message/javadoc are consistent with that: the `VERIFIED` block says *"tolerated, not
repaired"*, the javadoc says *"deliberately NOT purged here"* and *"`docker rm` the container if
the tidiness matters."* **No sentence anywhere in the commit implies the residue is cleaned.**
The specific failure that produced this revision did not recur. (Finding 1 is about a different
claim — what makes the run *green* on that container — not about repair.)

---

## 7. (Info) Claim 3 holds — the null resets were genuinely dead

Every route by which the fields could carry between methods, checked:

| Route | Result |
|---|---|
| `@TestInstance(PER_CLASS)` on the class | `grep TestInstance` over the IT → no match (positive control on the same file: `Transactional` → 2 hits) |
| `@TestInstance` on `BasePostgresIntegrationTest` | none — the class carries only `@SpringBootTest`, `@ActiveProfiles`, `@Import`, `@ExtendWith`, `@Transactional` |
| Global default override via `junit-platform.properties` | **None in the repo.** `find . -name junit-platform.properties -not -path ./target/*` → empty. Positive control on the same `find`: `src/test/resources/*.properties` returns 4 files, so the instrument works. |
| `junit.jupiter.testinstance.lifecycle.default` in the pom | `grep` over `pom.xml` → no match |
| `@RepeatedTest` / `@ParameterizedTest` | none — the class has exactly one `@Test` (line 154) |

Default `Lifecycle.PER_METHOD` therefore applies: a fresh instance per method, both fields
already `null`. The resets could never observe a non-null value. Removal is correct, and it also
removes the false implication the prior lane flagged (that state survives between methods here).

---

## 8. (Info) Claim 2 holds — the H2 correction is accurate

| | Evidence |
|---|---|
| `BasePostgresIntegrationTest` is Testcontainers-backed | `@ExtendWith(AppPostgresDBSetupExtension.class)`, `@ActiveProfiles("postgres-integration")`, and `@DynamicPropertySource` binding `AppPostgresDBContainer.container::getJdbcUrl` / `getUsername` / `getPassword` (lines 46-83). `AppPostgresDBContainer:49` → `.withReuse(true)`. |
| `BaseIntegrationTest` really is the H2 one | *"Base class for integration tests using H2 in-memory database"*, `@ActiveProfiles("integration")` |
| The new sentence resolves | `BasePostgresIntegrationTest` is imported (line 3), so `{@link}` resolves. The **old** `{@link BaseIntegrationTest}` did **not** — it was never imported, so the removed sentence was both false and a dangling javadoc reference. Net improvement on two axes. |

The added rationale (*"the reuse defect … is impossible under an in-memory H2 that dies with the
JVM"*) is sound.

---

## 9. (Info) The SBDEV-2232 proof is intact

The delta inserts six comment lines and a four-line `if` between line 239 (`t2Done = ...await`)
and line 253 (`assertThat(t1Done)`). Checked for any weakening:

- `t1Done` and `t2Done` are computed at 238-239, **before** the inserted block. The block cannot
  change them.
- No assertion was added, removed, weakened or reordered. All eight survive verbatim.
- The racing logic (lines 187-235), the latches, the `AtomicInteger` state captures and the
  final DB re-read at 274-281 are untouched.
- The only behavioural reach of the insert is `Thread.interrupt()` on pool threads, and only
  after a latch has already timed out — i.e. only on a run that is already failing at line 253.

Both halves of the original contract still hold: thread 2 blocks on thread 1's `FOR UPDATE`
lock and then reads the committed `PALLETIZED` state (268-271), and the final DB state is
re-read in its own transaction (279-281).

---

## 10. (Info) Why the pool change is safe — the part the comment omits

Stated separately because it is the actual argument for the change and it is not in the code:

**The `t1Done` / `t2Done` assertions deliberately sit at lines 253-254, before every other
assertion.** That ordering is what makes `shutdownNow()` unable to mask anything: the branch runs
only when a latch timed out, and the first assertion evaluated is the one that reports exactly
that. This ordering is now load-bearing and nothing says so — a future editor who moves the
`thread1Err`/`thread2Err` null-checks above it would reintroduce precisely the masking the
comment worries about. One sentence on line 253 would pin it.

---

## 11. (Info) Claims re-verified true, independently

Re-derived rather than inherited from the prior lane:

| Claim | Instrument | Result |
|---|---|---|
| `ADD CONSTRAINT index_customerorder_externalnumber UNIQUE (externalnumber)` in the container's own migration | `V2.2.00__base_v2_schema.sql:3308` | ✅ |
| `fkqd6gjnmjxh0ocg2txrnt0g7o2 FOREIGN KEY (orderbatch_id) REFERENCES public.customerorder_batch(id)`, **no** `ON DELETE CASCADE` | `:5606-5610` | ✅ — so order-before-batch in the hook is right |
| `wms.tenant.lock-timeout-ms` is **10 s** on this lane | `application-postgres-integration.properties:187` = `10000`. Main default is `3000` (`src/main/resources/application.properties:119`) — the comment's "10 s" is correct *for the profile this test runs under*, which is the precise reading, not a sloppy one | ✅ |
| "seated on the tenant EMF in `TenantDatabaseConfig`" | `TenantDatabaseConfig:47` `@Value("${wms.tenant.lock-timeout-ms:3000}")`, seating `LockTimeoutHibernateJpaDialect` (SBDEV-3250, `:116`) | ✅ |
| `FixLocationAssignmentServiceIT`'s `"FLA-OLD-" + System.nanoTime()` idiom | `FixLocationAssignmentServiceIT.java:137` | ✅ |
| `PgLaneFixtures.order(Integer, Long, String)` sets `externalnumber` | `PgLaneFixtures.java:157-160` | ✅ |
| The `nanoTime` caveat is labelled "reasoned, NOT reproduced" in both message and javadoc | lines 92-99 + message | ✅ — correctly hedged |
| "a passing test is not proof this hook works; its evidence is the residue count" | correct, and the right thing to say | ✅ |

The commit's self-correction paragraph (*"an earlier draft … carried a verification sentence
over from the withdrawn revision … Caught in review"*) is accurate about what happened and does
not overstate the remedy. That part is well done.

---

## Is PR #399 safe to merge?

**Yes — the Java is safe.** Test-only, one file, `mvn -o test-compile` EXIT 0, no production
code, no schema, no behaviour change to anything shipped. The `@AfterEach` is complete, the
delete order matches the FK, one transaction is sufficient, the lifecycle reasoning is right,
the pool hardening is a net improvement that cannot mask a failure, and the SBDEV-2232 proof is
untouched. Merging it strictly improves the repeat-run behaviour of `mvn verify` on any machine
with container reuse enabled.

**The commit message is not accurate yet**, and this is revision 4 on a test-only cleanup, so I
will rank rather than just block:

1. **Finding 1 is the one worth an amend.** It is in the "what fixes it" position — the sentence
   a future reader cites and acts on — and the edit it invites (revert the keys, keep the hook)
   breaks the build on every machine that hit this bug. Two clauses.
2. **Findings 2-4 can ride on the ticket** if the goal is to stop the loop. They are prose
   precision in a code comment and a message, and none of them will cause anyone to do the
   wrong thing.
3. **Finding 5** (the three carried-forward Lows) is a judgement call for Nam: the standing rule
   says take them in the same pass, and they are one javadoc reorganisation plus two sentences.
   Prior finding 6 is the only one with teeth — it documents a real self-deadlock a future editor
   can walk into.

If finding 1 is amended, this is a good commit and I would approve it without reservation.
