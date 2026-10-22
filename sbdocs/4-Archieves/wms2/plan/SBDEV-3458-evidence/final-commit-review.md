---
ticket: SBDEV-3458
lane: independent review of the REDESIGNED fix (second review, never-before-reviewed code)
reviewer: final-3458 (Opus 5, 1M)
date: 2026-09-23
worktree: /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3458-final (detached)
head: dec515f0
prior-reviewed-and-now-withdrawn: 8cb3d5b8
base: origin/develop @ b87ec747
verdict: CHANGES REQUESTED (claims only — the code itself is correct and I would merge it)
---

# SBDEV-3458 — review of `dec515f0`

## Verdict

**CHANGES REQUESTED.**

The **code is correct.** The `@AfterEach` is complete, the FK order is right, one transaction
is sufficient, the field capture is safe under every failure path I could construct, and the
redesign was the right call on every axis the prior lane raised. I found no defect in the
93 added lines that would make the test wrong, flaky, or slower. **If the only question is
"does this Java work", the answer is yes and it is safe to merge.**

What blocks it is finding 1: **the commit message's headline verification sentence is
carried over verbatim from `8cb3d5b8`, the design this commit withdrew, and it is not
reproducible under this commit's code.** It also directly contradicts this commit's own
javadoc, four paragraphs apart. Both cannot be true. On a ticket that declares a
confidently-worded false claim equal in severity to a code defect — and in a commit whose
entire subject is documentation honesty — that is the finding, not a nit. Finding 2 is a
second false claim, pre-existing but in the same javadoc block this commit rewrote.

Neither requires a code change. Both require a `git commit --amend` / one javadoc edit and
a force-push.

## Summary

| # | Severity | Finding | Brief item |
|---|---|---|---|
| 1 | **Medium** | `Verified: … a container that started polluted (run 1 repaired it), 0 PARCELMON rows in either table afterwards` is verbatim from `8cb3d5b8`, which had the purge-by-name that made "repaired" possible. Under `dec515f0` there is no such mechanism, and the javadoc says so explicitly. | 4 |
| 2 | **Medium** | Class javadoc still asserts `Uses {@link BaseIntegrationTest} (H2 in-memory)`. The class extends `BasePostgresIntegrationTest`. The false sentence negates the premise of the whole fix — a reused container cannot exist under H2. | 4 |
| 3 | Low | The residue claim undercounts: old fixed-literal runs stranded a `customerorder_batch` row too. The javadoc names only `PARCELMON-ORD-1`; the commit message says "either table". | 4 |
| 4 | Low | The 55-line design javadoc hangs off `private static final String KEY_PREFIX`, which it barely describes. The class javadoc — where a reader looks — carries none of it, and carries finding 2 instead. | 4 |
| 5 | Low | `seededOrderId = null; seededBatchId = null;` are dead under JUnit's default PER_METHOD lifecycle, and misleading: they imply PER_CLASS. | 3 |
| 6 | Low | Nothing warns the next editor why the `REQUIRES_NEW` purge is safe. It is safe *only* because every write in the test body is itself in a `REQUIRES_NEW` transaction. Carried over unaddressed from the prior lane's finding 6. | 3 |
| 7 | Low | On a test-body failure the pool threads may still hold the `FOR UPDATE` lock when `@AfterEach` runs — `pool.awaitTermination(5, SECONDS)`'s return is never asserted. The purge then waits up to 10 s and can fail with a lock timeout, stacking a confusing second failure on the real one. | 6 |
| 8 | Info | `testcontainers.reuse.enable=true` is a per-developer opt-in in `~/.testcontainers.properties`, per the repo's own `AppPostgresDBContainer` javadoc. The new javadoc states it as a given. Scope is reuse-enabled machines; CI never saw this bug. | 4 |
| 9 | Info | `System.nanoTime()` has an arbitrary origin; cross-JVM uniqueness is empirical, not guaranteed. Acceptable — it is the repo idiom and the javadoc already labels the concurrent case unreproduced. | 5 |
| 10 | Info | **The `@AfterEach` is complete.** Two rows created, two rows deleted. No cascade, no association, no audit row, no trigger. Verified row-by-row. | 1 |
| 11 | Info | **Field capture is safe.** No path commits a row whose id is never captured. The asymmetry (batch inside the lambda, order outside) is belt-and-braces, not a bug. | 2 |
| 12 | Info | **`REQUIRES_NEW` suspends and commits correctly** inside the class-level test transaction. | 3 |
| 13 | Info | **The redesign was the right call.** Removing the before-hook entirely is correct, and leaving the predecessor's orphan unpurged is the right trade — I verified the orphan is genuinely inert. | 5 |
| 14 | Info | Every other factual claim in the javadoc and commit message verified **true** — nine of them, listed below. | 4 |

`mvn -o -B -ntp test-compile` → **EXIT=0** in this worktree. I ran **no** `verify` and no
integration test; the sibling `mvn -o test` in `SBDEV-3418-final` (PID 60878) is surefire,
not failsafe, and was left undisturbed. No Testcontainers connection was opened by this lane.

---

## 1. (Medium) The commit's verification evidence belongs to the withdrawn design

`dec515f0` commit message:

> ```
> Verified: three consecutive `verify` runs green against a container that started
> polluted (run 1 repaired it), 0 PARCELMON rows in either table afterwards; and a
> full `mvn clean verify` BUILD SUCCESS -- surefire 6,787/0, failsafe 493/0.
> ```

`8cb3d5b8` commit message — the revision this one withdrew:

> ```
> Verified: three consecutive `verify` runs green (33.8s / 34.6s / 35.2s) against a
> container that started out polluted -- run 1 repaired it -- with 0 PARCELMON rows
> in either table afterwards.
> ```

Same sentence, timings dropped. And `8cb3d5b8` is the revision that had the mechanism which
makes "repaired" mean anything:

```java
// 8cb3d5b8, since removed
+    @BeforeEach
+    void purgeResidueFromEarlierRuns() {
+        purgeCommittedFixture();
```

`dec515f0` deletes that hook and states, in its own javadoc, that the consequence is
permanent:

> ```java
>  * <p>⚠ Containers polluted by the old fixed-literal runs keep one orphaned
>  * {@code PARCELMON-ORD-1} row. It is harmless and is deliberately NOT purged here
> ```

Under `dec515f0` the only deletes are `findById(seededOrderId)` and
`findById(seededBatchId)` — ids minted this run. **No code path in this commit can remove a
`PARCELMON-ORD-1` row.** So a container that started polluted cannot finish with "0
PARCELMON rows in either table". The two statements are mutually exclusive, and the one in
the javadoc is the one the code supports.

The only reading that saves the sentence is that the three runs were performed under
`8cb3d5b8` — in which case `dec515f0` ships **no fresh measurement of the property its
message leads with**, and the message says "Verified" anyway. Either way this is the exact
defect shape the repo has recorded twice: *fixing a false claim tends to produce a new one,
because the sibling copies move together and a token grep is not a sweep.* The sentence was
edited (timings removed, clauses reflowed) without being re-checked against the code it now
describes.

I cannot run `verify`, so I am not asserting the runs never happened. I am asserting, from
the code alone, that **they cannot have produced that result on this commit**, and that the
sentence is textually inherited from the revision where they could have.

**What to do.** Amend the message to state what this commit's code can actually produce, e.g.
*"Verified: full `mvn clean verify` BUILD SUCCESS — surefire 6,787/0, failsafe 493/0.
Repeat-run cleanliness re-measured on a container seeded only by this revision: 0 rows from
this run's keys afterwards. The pre-existing `PARCELMON-ORD-1` orphan is still present by
design (see the javadoc)."* Only claim a polluted-container repair if the container is first
re-polluted and the run re-done — and under this design it will not repair it.

---

## 2. (Medium) The class javadoc says this test runs on H2

`ParcelMonitorViewServiceConcurrencyIT.java:47-49`:

```java
 * <p>Uses {@link BaseIntegrationTest} (H2 in-memory) — consistent with all other
 * v2 integration tests. H2 supports {@code SELECT FOR UPDATE} row-level locking;
 * the lock-blocking contract is dialect-independent.
```

Line 53: `class ParcelMonitorViewServiceConcurrencyIT extends BasePostgresIntegrationTest`.
It is a Testcontainers PostgreSQL test and has been since SBDEV-3239. `BaseIntegrationTest`
is in `net.aim_ai.wms.common.base` and is **not imported here**, so the `{@link}` does not
resolve either.

Pre-existing (present at `b87ec747`, confirmed), so not a regression. I am raising it anyway
because of where it sits: **the false sentence is 18 lines above a 55-line javadoc whose
whole subject is the reused container**, and it contradicts it outright. A reader who starts
at the top of the class learns the test uses an in-memory H2 that dies with the JVM — from
which the entire SBDEV-3458 defect is impossible. This commit rewrote the documentation in
this file at length and had to read past that sentence to do it.

Three lines to delete or correct. Leaving a known-false claim in place in a commit whose
subject is claim accuracy is the thing that makes the next reader stop trusting the accurate
paragraphs too.

---

## 3. (Low) The residue claim undercounts by one row

> ```java
>  * <p>⚠ Containers polluted by the old fixed-literal runs keep one orphaned
>  * {@code PARCELMON-ORD-1} row.
> ```

The old fixture committed **two** rows per successful run — `PARCELMON-BATCH-1` in
`customerorder_batch` and `PARCELMON-ORD-1` in `customerorder`. (The second old run rolled
its whole `REQUIRES_NEW` seed back at the duplicate key, so the count stops at one of each.)
The commit message's own mutation note gets this right — *"strands 1 customerorder + 1
customerorder_batch"* — and says "either table". The javadoc names only the order.

The *harmless* verdict survives the correction, and I verified why rather than taking it:

```sql
-- V2.2.00__base_v2_schema.sql:3692 — the only UNIQUE on customerorder_batch
ALTER TABLE ONLY public.customerorder_batch
    ADD CONSTRAINT uk_hsst0psb47fsttxg3uw9ot1v5 UNIQUE (batchid);
```

It is on `batchid`, not `number`, and `PgLaneFixtures.batch(...)` never sets `batchid` — so
the stranded batch rows are all NULL there, and Postgres permits unlimited NULLs in a UNIQUE
index. Batch rows can never collide with each other at all. (For completeness: the
`UNIQUE (number)` at line 3684 that a grep of this region surfaces belongs to
`pickingorder_position`, a different table.)

Say "one orphaned `PARCELMON-ORD-1` row and its `PARCELMON-BATCH-1` batch".

---

## 4. (Low) The design javadoc is attached to the wrong element

```java
    private static final String KEY_PREFIX = "PARCELMON-";
```

Fifty-five lines of javadoc — the defect history, the mutation evidence, the concurrency
caveat, the withdrawn before-hook, the orphan trade — document a `String` constant equal to
`"PARCELMON-"`. Almost none of it is about the constant. IDE hover on `KEY_PREFIX` will
render the essay; the class javadoc, where a reader actually looks for "what is this test
and what do I need to know", carries none of it and carries finding 2 instead.

Move the SBDEV-3458 block to the class javadoc (replacing the H2 paragraph), keep a one-line
`/** Run-unique key prefix; see the class javadoc. */` on the constant, and keep the
mechanism note on `deleteCommittedFixture()` where it already correctly is.

---

## 5. (Low) The null-resets are dead code that implies the opposite lifecycle

```java
        seededOrderId = null;
        seededBatchId = null;
    }
```

JUnit 5's default is `Lifecycle.PER_METHOD`. Neither this class nor
`BasePostgresIntegrationTest` carries `@TestInstance`, so **a fresh instance is constructed
per test method and both fields are already `null` before every run.** The resets can never
observe a non-null value they need to clear. (The class also has exactly one test method, so
they would be inert even under `PER_CLASS`.)

They are not harmful, but they are not neutral either: a reader infers from them that state
survives between tests here, which is the thing that would make an `@AfterEach` purge
*necessary* rather than merely tidy — and it does not. Either delete them, or keep them and
say why in one clause (*"defensive against a future `@TestInstance(PER_CLASS)`"*), so the
next reader does not reason from a false lifecycle.

---

## 6. (Low) Why `REQUIRES_NEW` is safe here is undocumented, and it is conditional

`BasePostgresIntegrationTest` is `@Transactional("tenantTransactionManager")` (line 61) and
this class redundantly re-declares it (line 52, pre-existing). Spring's test-managed
transaction spans `@BeforeEach` → test → `@AfterEach`, so `deleteCommittedFixture()` runs
**inside** it, and `requiresNewTx()` suspends it. That is correct and it does commit: the
suspend/resume is `AbstractPlatformTransactionManager`'s, and nothing in the outer
transaction is holding these rows.

**But only because nothing does.** Every touch of the fixture in the test body goes through
`requiresNewTx()` — the seed, both threads, and the final verify at line 263. Add one plain
`customerorderRepository.save(order)` to the test body — the obvious thing a future editor
does — and it enlists in the *outer* transaction, takes a row lock, and the `@AfterEach`
DELETE in a suspended-sibling transaction blocks on its own test's lock. Self-deadlock.

It is bounded rather than infinite, which I confirmed rather than assumed:
`TenantDatabaseConfig:111` seats `new LockTimeoutHibernateJpaDialect(tenantLockTimeoutMillis, dialect)`
on the tenant EMF, and that dialect issues `SET LOCAL lock_timeout` in `beginTransaction`, so
it covers every statement in the transaction, not just pessimistic reads.
`application-postgres-integration.properties:187` sets `wms.tenant.lock-timeout-ms=10000`.
So the failure mode is a 10-second stall and a lock-timeout exception in an after-hook —
loud, but pointing nowhere near the edit that caused it.

The prior lane raised this as its finding 6 and it is still unaddressed. One sentence on
`deleteCommittedFixture()`: *"Safe only because the test body touches these rows exclusively
inside `requiresNewTx()`; a repository call that joins the outer test transaction would make
this hook block on its own test's row lock."*

---

## 7. (Low) A failing test can now produce a second, misleading failure

```java
        pool.shutdown();
        pool.awaitTermination(5, TimeUnit.SECONDS);

        assertThat(t1Done).as("Thread 1 committed within 10 s").isTrue();
```

`awaitTermination`'s boolean is discarded, and `shutdown()` does not interrupt running tasks.
If thread 1 wedges — the failure this test exists to catch — `t1Done` is false, the assertion
at line 242 fails, and `@AfterEach` then runs **while that thread may still hold the
`FOR UPDATE` lock on the row it is about to delete.** The purge waits out the 10 s
`lock_timeout` and throws.

JUnit reports both, so nothing is hidden, but the run goes from "Thread 1 committed within
10 s → expected true" to that plus a 10-second pause and a Postgres lock-timeout stack in a
cleanup hook — and the second one is the louder of the two. This is new: before this commit
there was no after-hook to collide.

Cheap fixes, either one: assert `awaitTermination`'s result (it is a real signal today and
is being thrown away), or use `shutdownNow()`. I would do both.

---

## 8. (Info) The reuse property is a per-developer opt-in, stated as a given

> ```java
>  * Because {@code testcontainers.reuse.enable=true} keeps the container alive between
>  * builds, every SECOND {@code mvn verify} on a machine failed
> ```

True on this machine — `~/.testcontainers.properties` carries
`testcontainers.reuse.enable=true` — but it is not a repo setting, and the repo's own
documentation says so:

```java
// AppPostgresDBContainer.java:21-22
 * <p><b>Reuse.</b> {@code withReuse(true)} is a no-op unless the developer also sets
 * {@code testcontainers.reuse.enable=true} in {@code ~/.testcontainers.properties}
```

"on a machine" carries most of the weight already, so this is Info rather than a finding.
But the scope is worth one clause, because it explains why nobody else hit this and why CI
is not evidence either way: **the bug is invisible to any developer or pipeline without the
opt-in, and repairs itself on a fresh container.**

## 9. (Info) `nanoTime` uniqueness across JVMs is empirical

`System.nanoTime()` is specified with an arbitrary origin, and the javadoc leans on it for
the cross-*build* (i.e. cross-JVM) case. In practice HotSpot on this platform reads a
machine-wide monotonic clock, so two concurrent JVMs share an origin and collide only inside
one nanosecond — but that is an implementation property, not a guarantee, and it is the
weakest link in exactly the claim the javadoc already marks "reasoned, not reproduced".

Not worth changing: `UUID.randomUUID()` would be a guarantee, but `nanoTime` is the
established idiom for this fixture helper on this lane (`FixLocationAssignmentServiceIT:137`,
`"FLA-OLD-" + System.nanoTime()` — verified, 13 files repo-wide use it), and consistency is
worth more here than closing a nanosecond. Noted only so it is not mistaken for a guarantee
later.

---

## 10. (Info) The `@AfterEach` is complete — verified, not assumed

`PgLaneFixtures.batch(...)` sets `number`, `clientId`, `state`. `PgLaneFixtures.order(...)`
sets eight scalar columns including three FK **ids**. Both are plain setter-built POJOs.
Two `save()` calls, two rows. Checked for every mechanism that could create a third:

| Mechanism | Result |
|---|---|
| JPA cascade / `@OneToMany` / `@ManyToOne` on `Customerorder` or `CustomerorderBatch` | **None.** The repo uses manual FK ids, no association annotations — grep for `Cascade\|OneToMany\|ManyToOne\|OneToOne\|mappedBy` on both entities returns nothing. |
| `@EntityListeners` / `@PrePersist` / Envers `@Audited` | **None on either entity.** |
| DB trigger on either table | **None.** No `CREATE TRIGGER` touching `customerorder*` in any migration. |
| FK target rows | `client_id=0`, `boxtype_id` and `orderbatch_id` — the first two are migration-seeded rows the fixture references but never creates. Correctly not deleted. |
| Sequence rows (`los_sequencenumber`) | Burned, not inserted — a counter bump, not a row. Nothing to clean. |

Delete order is right and the FK is real:

```sql
-- V2.2.00__base_v2_schema.sql:5610
ALTER TABLE ONLY public.customerorder
    ADD CONSTRAINT fkqd6gjnmjxh0ocg2txrnt0g7o2 FOREIGN KEY (orderbatch_id) REFERENCES public.customerorder_batch(id);
```

No `ON DELETE CASCADE`; `customerorder` is the child; order first. **One transaction is
sufficient**, and the javadoc's reasoning for that is correct on all three counts I checked:
Hibernate's `ActionQueue` sorts only the insert and update buckets and only under
`order_inserts`/`order_updates`; those two are set at
`src/main/resources/application.properties:93-94` but `TenantDatabaseConfig` hand-builds the
tenant persistence unit's property map and passes none of the `spring.jpa.properties.*`
namespace; and `src/test/resources/application.properties` shadows the main file and carries
neither. There is no `hibernate.order_deletes`. Deletes execute in call order.

Also confirmed: the residue is inert for the rest of the suite. No `BasePostgresIntegrationTest`
subclass does an unscoped `findAll()`/`count()` on either repository (all `findAllById` hits
are Mockito stubs in unit tests), and the one query IT that could plausibly see a stray order —
`OrderReleaseSectionQueryIT` — reads `getOrderReleaseInfo`, which projects from
`CustomerorderPositionRepository`. The PARCELMON fixture creates no `customerorder_position`
row, so it cannot appear in that result set at all.

## 11. (Info) Field capture is safe on every path

```java
        Long orderId = seedTx.execute(status -> {
            CustomerorderBatch batch =
                    customerorderBatchRepository.save(PgLaneFixtures.batch(KEY_PREFIX + "BATCH-" + runKey));
            seededBatchId = batch.getId();
            return customerorderRepository.save(PgLaneFixtures.order(
                    WmsConstants.State.PACKED, batch.getId(), KEY_PREFIX + "ORD-" + runKey)).getId();
        });
        seededOrderId = orderId;
```

The question asked was: is there a path where a row commits but its id is never captured,
making it permanently unreachable? **No.**

- **Batch saved, order rejected.** Both saves are in one `REQUIRES_NEW` transaction, so the
  batch never commits. `seededBatchId` then holds an id for a row that does not exist —
  which is exactly what `findById(...).ifPresent(...)` is for. The guard is load-bearing
  here, not decoration; without it this path would throw `EmptyResultDataAccessException`
  out of an after-hook.
- **Commit itself fails.** `index_customerorder_externalnumber` is a plain (non-`DEFERRABLE`)
  UNIQUE, so a duplicate fires at flush, inside the lambda. A failure at `COMMIT` rolls the
  whole transaction back regardless. Nothing commits, nothing to capture.
- **Between commit and capture.** `TransactionTemplate.execute` returns on the calling
  thread and `seededOrderId = orderId;` is the next statement — no intervening call can
  throw. Only a JVM kill fits, which the javadoc already documents as the accepted trade.

The asymmetry the brief flagged — batch id captured *inside* the lambda, order id *outside* —
is therefore belt-and-braces rather than a bug: because the transaction is atomic, either
position is safe for either id. I would still capture both the same way, purely so the next
reader does not spend the ten minutes I did working out whether the difference was load-bearing.

One latent constraint worth a comment if the seed ever moves: the lambda writes an instance
field, which is safe only because `TransactionTemplate.execute` runs synchronously on the
JUnit thread, the same thread that later runs `@AfterEach`. Hoisting the seed into the
`ExecutorService` would introduce a real visibility problem with no test that could see it.

## 12. (Info) The lifecycle question, answered

`@AfterEach` runs inside the class-level test transaction; `REQUIRES_NEW` suspends it,
opens a second connection, deletes, commits, resumes. That is Spring's documented
suspend/resume and it works here — see finding 6 for the condition it depends on and finding
5 for the resets.

## 13. (Info) The redesign was the right call

On the specific question of whether removing the before-hook entirely went too far: **no, and
leaving the predecessor's orphan is the correct trade.**

- A purge-by-name reintroduces precisely the cross-build deletion the prior lane objected to.
  There is no narrower version of it: any predicate that matches `PARCELMON-ORD-1` by name
  can be widened by a future edit to match `PARCELMON-ORD-%`, and the class of bug it creates —
  a live fixture deleted out from under a concurrent build, surfacing as
  `IllegalStateException("Order … not found")` — points nowhere near its cause. Trading a
  loud, correct, self-describing duplicate-key error for that is a bad trade at any residue count.
- The orphan is genuinely inert, which I verified independently (finding 10): no unique-key
  collision is possible against it, no suite member can observe it, and nothing generates
  that key any more. It is two dead rows in a container that `docker rm` removes.
- A one-off cleanup of a predecessor's mess does not belong in a permanent `@BeforeEach` in
  any case — it would run forever to fix a condition that stops being creatable the moment
  this commit lands.

The one thing I would add is the instruction the javadoc already implies but does not give:
name the exact command, `docker rm -f <container>`, or better, a `DELETE FROM customerorder
WHERE externalnumber = 'PARCELMON-ORD-1'` one-liner in the ticket, so the tidiness is
available to anyone who wants it without being wired into the test.

## 14. (Info) Claims verified true

For the record, everything else I checked in the javadoc and message holds:

| Claim | Instrument |
|---|---|
| `index_customerorder_externalnumber UNIQUE (externalnumber)` in the container's own migration | `V2.2.00__base_v2_schema.sql:3308` ✅ |
| `fkqd6gjnmjxh0ocg2txrnt0g7o2 … REFERENCES customerorder_batch(id)`, no cascade | `:5610` ✅ |
| `0ba2c389` un-excluded this class and introduced the literals | `git show 0ba2c389` — subject and body match ✅ |
| `FixLocationAssignmentServiceIT`'s `"FLA-OLD-" + System.nanoTime()` idiom | `FixLocationAssignmentServiceIT:137` ✅ |
| `TenantDatabaseConfig` hand-builds the tenant Hibernate map, dropping `spring.jpa.properties.*` | verified ✅ |
| No `hibernate.order_deletes`; `ActionQueue` sorts inserts/updates only | correct ✅ |
| `src/test/resources/application.properties` shadows main and carries neither ordering property | verified ✅ |
| The seed fixture creates exactly two rows | verified row-by-row ✅ |
| "a passing test is not proof this hook works; its evidence is the residue count" | correct, and the right thing to say ✅ |

`externalnumber` is `character varying(255)`; `"PARCELMON-ORD-" + <=19 digits` is 33
characters. No width risk.

---

## Is it safe to merge as-is?

**The code: yes.** I found nothing in the 93 added lines that is wrong, and the parts the
brief asked me to doubt — completeness, field capture, lifecycle, the trade — all hold up
under checking. It is a better fix than the one it replaces, and it is more careful about
what it claims than most commits in this repo.

**The commit as-is: no.** Its lead verification sentence describes a result its own code
cannot produce, inherited from the design it withdrew, and a false claim in a commit message
is permanent in a way a code defect is not — nobody re-derives it later, they cite it. Amend
that sentence and delete the H2 paragraph (findings 1 and 2); findings 3–7 are a javadoc
edit, three deleted lines, and one assertion, and I would take them in the same pass rather
than leave five Lows on a test whose subject is care.
