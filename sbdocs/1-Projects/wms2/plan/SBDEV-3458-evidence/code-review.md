---
ticket: SBDEV-3458
lane: independent code review
reviewer: review-3458 (Opus 5, 1M)
date: 2026-09-23
worktree: /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3458
branch: bugfix/SBDEV-3458-parcelmonitor-it-fixture-cleanup
head: 8cb3d5b8
base: origin/develop @ b87ec747
verdict: CHANGES REQUESTED (comment text only — the code is correct)
---

# SBDEV-3458 — independent review

## Verdict

**CHANGES REQUESTED**, narrowly.

The **code** is correct and I would approve it as written: the purge is complete, the
hooks fire where they must, and nothing it deletes can belong to anyone else. Two of the
seven questions I was asked to check turned up something, and one of them is a
confidently-worded factual claim that is wrong on three independent counts. Per the
instruction on this ticket — *"a confidently-worded false claim is a finding at the same
severity as a code defect"* — that is a Medium and it should be corrected before merge,
because the javadoc is a permanent artifact that teaches a future reader a false rule
about Hibernate they will then apply somewhere it matters.

Everything else is a nit or a recommendation.

## Summary

| # | Severity | Finding | Item |
|---|---|---|---|
| 1 | **Medium** | The javadoc/commit claim the two-transaction split is *required* by Hibernate DML ordering. The mechanism cited is wrong three separate ways; one transaction would have worked. | 1 |
| 2 | **Medium** | `nanoTime`-suffixed keys are the better fix, are already this repo's convention on this exact lane, and solve a case cleanup cannot. | 7 |
| 3 | **Medium** | Under two concurrent `mvn verify` runs on one machine the fix converts a loud duplicate-key into a misleading *"Order … not found"*. Live condition in this very session. | — |
| 4 | Low | The split trades atomicity away: a failure between tx1 and tx2 orphans the batch **permanently** — the purge can only reach a batch through its order. | 1 |
| 5 | Low | The UNIQUE-index claim is sourced from Hydra **prd** `pg_index`. The test never touches prd; the authoritative instrument is in-repo and was not cited. | 6 |
| 6 | Low | Latent self-deadlock: the `@AfterEach` purge opens `REQUIRES_NEW` while the outer tenant transaction is open. Safe *only* because the test body touches these rows exclusively inside `requiresNewTx()`. Nothing warns the next editor. | 4 |
| 7 | Info | Purge is complete — confirmed row-by-row. No cascade, no association, no audit row. | 3 |
| 8 | Info | `REQUIRES_NEW` genuinely suspends and commits; the before-hook cannot change the test's meaning. | 4 |
| 9 | Info | No collision possible. `PARCELMON-*` has exactly one producer, across two instruments and full history. | 5 |
| 10 | Info | Sibling sweep clean — all 35 `BasePostgresIntegrationTest` subclasses checked. | — |
| 11 | Info | Every other factual claim in the javadoc and commit message verified **true**. | 6 |

`mvn -o -B -ntp test-compile` → **EXIT=0** in this worktree. I ran no `verify` and no IT; the
sibling `clean verify` in `SBDEV-3458-run` (PID 32631) was left undisturbed throughout.

---

## 1. (Medium) The two-transaction split is not required, and the stated mechanism is wrong

> ```java
> * <p>⚠ Two SEPARATE transactions, deliberately. {@code customerorder} FKs
> * {@code customerorder_batch} through {@code orderbatch_id}, so the order row must be gone
> * before the batch is removed. Doing both in one transaction would make that depend on
> * Hibernate's flush ordering, which orders DML by entity type rather than by call order —
> * the same property that makes delete-then-reinsert-the-same-key unsafe in this codebase.
> ```

**The FK direction is right.** Verified:

```sql
-- src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:5609
ALTER TABLE ONLY public.customerorder
    ADD CONSTRAINT fkqd6gjnmjxh0ocg2txrnt0g7o2 FOREIGN KEY (orderbatch_id) REFERENCES public.customerorder_batch(id);
```

No `ON DELETE CASCADE`. `customerorder` is the child; the order must go first. That half of
the comment is correct.

**The ordering claim is not.** "Hibernate … orders DML by entity type rather than by call
order" is wrong here on three independent counts, any one of which is sufficient:

1. **There is no such thing as delete reordering.** Hibernate's `ActionQueue` executes
   action *types* in a fixed sequence (orphan-removals → inserts → updates → collection ops
   → **deletes**), and sorts *within* a bucket only for inserts/updates, and only when
   `order_inserts` / `order_updates` are on. The delete list has no sorter and no
   corresponding setting — there is no `hibernate.order_deletes`. Two `delete()` calls are
   executed in the order they were scheduled.
2. **Those settings are inert for these entities anyway.** They are set —
   `src/main/resources/application.properties:93-94` — but `TenantDatabaseConfig`
   hand-builds the tenant persistence unit's Hibernate map and passes **nothing** from the
   `spring.jpa.properties.*` namespace:
   ```java
   props.put("hibernate.multiTenancy", "DATABASE");
   props.put("hibernate.tenant_identifier_resolver", "…TenantIdentifierResolver");
   props.put("hibernate.dialect", dialect);
   props.put("hibernate.hbm2ddl.auto", ddlAuto);
   props.put("hibernate.temp.use_jdbc_metadata_defaults", "false");
   ```
   `Customerorder` and `CustomerorderBatch` are tenant entities. This is the same mechanism
   `PgLaneFixtures`' own javadoc documents for `validation.mode`.
3. **No test lane sees them regardless.** `src/test/resources/application.properties` exists
   and shadows the main file; `grep -rn "order_inserts\|order_updates" src/test/resources/`
   → nothing.

**The analogy is misapplied.** The delete-then-reinsert-the-same-key hazard this repo has
recorded is a *cross-type* ordering property — Hibernate emits **inserts before deletes**.
Here both operations are deletes, so that property does not apply.

**Answer to the question as asked:** one transaction would in fact have worked. The comment
over-claims. This is not cargo-culting in the sense of copying something meaningless — the
*outcome* (order first) is genuinely required — but the justification asserts a Hibernate
behaviour that does not exist and cites a precedent that does not transfer.

**What I would do:** keep the two-transaction shape if you prefer it (see finding 4 for why
I would not), but rewrite the rationale to what is actually true and load-bearing, e.g.
*"Two transactions so the FK is satisfied by construction rather than by relying on
Hibernate scheduling deletes in call order — which it does, but a future `saveAndFlush` or
an added cascade would not have to preserve."* Delete the "orders DML by entity type"
sentence and the delete-then-reinsert cross-reference outright.

---

## 2. (Medium) The `nanoTime` alternative is better, and is already the convention here

I was asked whether the simpler option is preferable. It is, and the case is stronger than
"simpler": **it is what the sibling class on this exact lane, using this exact fixture
helper, already does.**

```java
// src/test/java/net/aim_ai/wms/service/FixLocationAssignmentServiceIT.java:137-142
Location oldLocation = locationRepository.save(PgLaneFixtures.location("FLA-OLD-" + System.nanoTime()));
Location destination = locationRepository.save(PgLaneFixtures.flowbin("FLA-DEST-" + System.nanoTime()));
…
        PgLaneFixtures.unitload("FLA-UL-" + System.nanoTime(), oldLocation.getId(),
```

`git grep -c nanoTime -- src/test/java/net/aim_ai/wms` returns **13 files**, including six
PostgreSQL-lane ITs. And `PgLaneFixtures`' own javadoc states the rule the fix is working
around:

> ⚠ **`client.name`, `location.name` and `unitload.labelid` are GLOBALLY unique** … any name
> a caller passes to the factories below must be unique per run, not merely unique per client.

`customerorder.externalnumber` is in that same category. The fix chose the one path the
fixture class's own documentation advises against, and did not mention the advice.

The stated reason for preferring cleanup — *"it leaves the DB clean for other classes"* — is
worth weighing honestly:

- **It is real but small.** The residue is one `customerorder` + one `customerorder_batch`
  per run, in a throwaway container, with no unique key on `customerorder_batch.number`. No
  other test reads either row (finding 9).
- **It is partly self-defeating.** The two-transaction split can orphan a batch that no
  future purge can ever reach (finding 4), so cleanup does not actually guarantee the clean
  DB it is chosen for.
- **It does not cover the case `nanoTime` does** (finding 3).

Twenty-two lines of hooks plus a fifty-line javadoc, versus `+ "-" + System.nanoTime()` on
two call sites. I would take the suffix. If you want both properties, the suffix **plus** a
plain `@AfterEach` that deletes by the id the seed already returns is strictly better than
either: no before-hook, no fixed-literal matching, no cross-run interference, and residue
still cleared on the happy path.

I am not treating this as a blocker — the committed fix works for the failure it targets —
but you asked, and I think the simpler option is the right one.

---

## 3. (Medium) Concurrent runs: a loud failure becomes a misleading one

`testcontainers.reuse.enable=true` means the container is shared not only across *sequential*
builds but across *simultaneous* ones on the same machine. That is not hypothetical here —
this session is running `mvn clean verify` in `SBDEV-3458-run` while I hold `SBDEV-3458`,
and my own briefing warned that both would hit the same postgres.

- **Before the fix:** run B's seed hits the unique index →
  `duplicate key value violates unique constraint "index_customerorder_externalnumber"`.
  Loud, attributable, names the row.
- **After the fix:** run B's `@BeforeEach` deletes run A's *live, committed* seed. Run A's
  thread 1 then does `findByIdForUpdate(orderId)` and gets
  `IllegalStateException("Order " + orderId + " not found")`, or the final assertion reads
  `finalState = -1`. Nothing in that output points at a second build.

The fix does not make concurrent runs work — it changes how they fail, and in the less
diagnosable direction. There is a second-order variant too: `delete()` on a `@Version`-ed
entity emits `DELETE … WHERE id=? AND version=?`, so a purge racing a live run can also
surface as an `OptimisticLockException` from an `@AfterEach`.

`nanoTime` keys make concurrent runs genuinely correct, which is the sharpest argument for
finding 2. If you keep the hooks, say so in the javadoc — the current text claims the
before-hook "repairs that state", which is true for *stale* residue and false for *live*
residue, and does not distinguish them.

---

## 4. (Low) The split can strand a batch permanently

> ```java
> private void purgeCommittedFixture() {
>     Long batchId = requiresNewTx().execute(status ->
>             customerorderRepository.findByExternalNumber(ORDER_EXTERNAL_NUMBER)
> ```

The purge's only route to the batch is through the order's `orderbatchId`. Once tx1 commits
the order delete, that route is gone. If tx2 then fails — lock timeout, connection blip, a
`kill -9` between the two commits — the batch survives with **no order pointing at it**, and
no future `@BeforeEach` or `@AfterEach` can ever find it. It is unreachable residue, forever.

A single transaction is atomic and has no such window. This is the concrete cost of the split
that finding 1 shows was not needed to buy anything.

Note the pre-fix residue did *not* have this problem: the seed's batch and order commit in
one `seedTx`, so a failing seed rolls both back and the leftover pair is always intact and
always findable. The fix introduces the only path in this class that can produce a
half-cleaned state.

**What I would do:** collapse to one `requiresNewTx()` containing both deletes in order, or
locate the batch by number. The latter needs a `findByNumber` on
`CustomerorderBatchRepository` — the javadoc is right that adding a production finder to
serve a test is the wrong trade, so: one transaction.

---

## 5. (Low) The UNIQUE claim is cited from the wrong instrument

> ```java
> * <p>⚠ {@code customerorder.externalnumber} carries a UNIQUE index
> * ({@code index_customerorder_externalnumber}, confirmed on Hydra prd via {@code pg_index}),
> ```

The claim is **true**. But the test lane never touches Hydra prd — it runs
`db/migration` into a Testcontainers postgres. The authoritative instrument is in-repo and
cheaper:

```sql
-- src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:3308
    ADD CONSTRAINT index_customerorder_externalnumber UNIQUE (externalnumber);
```

(and `db/v1-to-v2-onboarding/schema/V1.0.01__wms_tables.sql:201` for the onboarding path, so
the two locations agree). Replace the prd citation with the migration line; a reader who
wants to re-check the claim can then do so without DB access, and the citation matches the
environment the code actually runs in.

Same paragraph, the companion claim — *"`customerorder_batch.number` has no index at all"* —
is **true**. That table carries four indexes and `number` is in none of them:
`customerorder_batch_client_id_index`, `customerorder_batch_staginglane_id_index`,
`index_customerorder_batch_state`, `index_customerorder_batch_state_type`. The conclusion
drawn from it (a stranded batch accumulates rather than breaking anything) holds.

---

## 6. (Low) Latent self-deadlock in `@AfterEach`, undocumented

The `@AfterEach` purge opens a `REQUIRES_NEW` transaction on a **different connection**
while the class-level `@Transactional("tenantTransactionManager")` test transaction is still
open. That is safe *today* for one reason only: the test body performs every read and write
on these two rows inside its own `requiresNewTx()` blocks, so the outer transaction holds no
row lock on them.

The obvious next edit to a concurrency test is an assertion in the body — e.g. a bare
`customerorderRepository.findById(orderId)` outside `requiresNewTx()`. That takes no lock,
but a `save()` or a `findByIdForUpdate()` there would, and the `@AfterEach` delete would then
block on the outer transaction that can only commit *after* the hook returns. Self-deadlock,
bounded by the `lock_timeout` SBDEV-3250 seated on the tenant EMF, surfacing as a confusing
timeout in teardown rather than in the code that caused it.

**What I would do:** one line in the `purgeCommittedFixture` javadoc —
*"Runs in REQUIRES_NEW on a second connection while the outer test transaction is still
open. Do not touch these rows in the test body outside `requiresNewTx()`: a row lock held by
the outer transaction would make this hook block until `lock_timeout`."*

---

## 7. (Info) The purge is complete

Traced every row `PgLaneFixtures.batch(...)` and `order(...)` can produce:

- `batch(String)` sets `number`, `clientId`, `state` → **one** `customerorder_batch` row.
- `order(Integer, Long, String)` sets 8 fields → **one** `customerorder` row.
- Neither entity declares a single association annotation. `grep` for
  `@OneToMany|@ManyToOne|@OneToOne|@ManyToMany|cascade` over `Customerorder.java` and
  `CustomerorderBatch.java` → **zero hits** (consistent with the repo-wide "no JPA
  association annotations" rule). Nothing cascades.
- `AbstractBaseEntity` carries `@EntityListeners(AuditingEntityListener.class)`, which writes
  only `created` / `modified` **on the same row** — no audit or history table.
- No triggers: `grep -ni "CREATE TRIGGER" src/main/resources/db/migration/*.sql` → **zero**.
- `@GeneratedValue(SEQUENCE, generator = "entity_gen")` on `seqentities` burns ids, but a
  consumed sequence value is not a row and nothing here asserts on id continuity.

Two rows created, two rows deleted. Complete — subject to finding 4's orphan window.

---

## 8. (Info) `REQUIRES_NEW` behaves as claimed, and the before-hook is meaning-neutral

- **Hooks run inside the test transaction.** `SpringExtension` implements
  `BeforeEachCallback`, and `TransactionalTestExecutionListener.beforeTestMethod` starts the
  transaction there — i.e. *before* JUnit invokes `@BeforeEach` methods. `@AfterEach`
  likewise runs before the rollback. So yes, both hooks execute inside the Spring-managed
  transaction.
- **Suspension is genuine.** `requiresNewTx()` builds a `TransactionTemplate` over the
  **same** `tenantTransactionManager` the class-level annotation names — verified, the
  `@Qualifier("tenantTransactionManager")` field. `AbstractPlatformTransactionManager`
  unbinds the existing resource, opens a fresh connection, commits it independently, and
  rebinds. The deletes commit. This is not an inference: the class's *seed* already uses the
  identical mechanism and its committing is the entire defect under repair.
- **No change of meaning.** The outer transaction has written nothing when `@BeforeEach`
  runs, so there is no uncommitted state the purge could fail to see or wrongly see. The
  seed then runs in its own `REQUIRES_NEW`, independent of both. The native query in the
  purge bypasses the outer persistence context, which is empty.
- **No added connection pressure.** The purge's two transactions are sequential, so peak
  concurrent connections during the hooks is outer + 1 = 2 — below the outer + thread1 +
  thread2 the test body already reaches.

`BasePostgresIntegrationTest.baseSetUp()` is also `@BeforeEach`; JUnit runs superclass hooks
first. Irrelevant to correctness either way.

---

## 9. (Info) No collision possible with migration data or another class

Two independent instruments, with a positive control (per the "a zero-scan needs a positive
control" rule — `grep` here is `ugrep` and a broken scan is indistinguishable from a true
zero):

| Instrument | Result |
|---|---|
| `git grep -n PARCELMON` | 2 hits, both the new constants |
| `grep -ra PARCELMON src/ pom.xml` | same 2 hits |
| positive control `grep -ra "FLA-OLD-" src/` | 1 hit → instrument working |
| `git log --all -S'PARCELMON'` | one commit: `0ba2c389` |

And the migration seeds no orders at all: `INSERT INTO public.customerorder ` → 0,
`COPY public.customerorder ` → 0 in `V2.2.00__base_v2_schema.sql`. `PgLaneFixtures`'
javadoc independently states `customerorder_batch` is seeded with **zero** rows, which is why
`batch()` exists.

I verified this rather than taking your word for it, as asked. The keys are yours alone. The
only residual exposure is a future developer reusing the literal — which the fixed-literal
design makes silently destructive rather than loud, and which `nanoTime` keys would make
impossible.

**On `findByExternalNumber` (item 2 as asked):** it is `Optional<Customerorder>` over
`SELECT * FROM customerorder WHERE externalnumber = :externalnumber`, nativeQuery. Two
matching rows would raise `IncorrectResultSizeDataAccessException` — this repo's known
non-unique-`Optional` trap. **That state cannot arise**: the UNIQUE constraint at
`V2.2.00__base_v2_schema.sql:3308` is enforced in the very container the test runs against,
which is exactly why the reported failure was a duplicate-key violation rather than a
non-unique-result exception. The finder is safe here. Worth knowing it would *not* be safe if
this pattern were copied to a column without that constraint.

---

## 10. (Info) Sibling sweep — no other class has this defect

Checked all **35** `BasePostgresIntegrationTest` subclasses. Nine use `REQUIRES_NEW`; of the
eight other than the class under review:

- `FixLocationAssignmentServiceIT`, `PickLineRealignmentIT`, `ClientRepositoryTransactionDetailIT`,
  `WarehouseStockReportServiceStreamIT`, `OrderReleaseSectionQueryIT`, `TenantLockTimeoutIT` —
  `nanoTime`-suffixed keys, immune by construction.
- `StockunitBusinessServiceConcurrencyIT`, `UnitloadBusinessServiceConcurrencyIT` — the
  `REQUIRES_NEW` is inside the *assertion* path, not the seed; no committed named fixture.
- `SequenceTransactionServiceConcurrencyIT`, `IdempotencyFilterIT`, `MessageCleanupBatchServiceIT` —
  the `REQUIRES_NEW` mentions are prose about proxy semantics, not committed fixtures.

The fix is correctly scoped to one class. Nothing to propose onto the ticket from the sweep.

---

## 11. (Info) Claims checked and found true

| Claim | Verdict | Instrument |
|---|---|---|
| `customerorder` FKs `customerorder_batch` via `orderbatch_id` | **TRUE** | `V2.2.00…sql:5609`, no `ON DELETE` |
| `index_customerorder_externalnumber` is UNIQUE | **TRUE** | `V2.2.00…sql:3308` (see finding 5 on the citation) |
| `customerorder_batch.number` has no index | **TRUE** | 4 indexes on that table, none on `number` |
| These repositories extend `CrudRepository`, not `JpaRepository`, so there is no `flush()` | **TRUE** | both extend `PagingAndSortingRepository` + `CrudRepository`; neither exposes `flush()`/`saveAndFlush()` |
| `0ba2c389` introduced the literals | **TRUE** | `git show 0ba2c389` adds `"PARCELMON-BATCH-1"` and `"PARCELMON-ORD-1"` inline |
| `0ba2c389` un-excluded the class from the pom | **TRUE** | commit subject and `git log pom.xml` |
| The class had no cleanup from `0ba2c389` until this fix | **TRUE** | no `@AfterEach`/`@BeforeEach` in the file before `8cb3d5b8` |
| `CustomerorderBatchRepository` has no `findByNumber` | **TRUE** | full read of the interface |
| `customerorder_batch` is seeded with zero rows | **TRUE** | no INSERT/COPY in the migration |

Two notes on the `CrudRepository`/`flush()` sentence, which is true but is doing less work
than it appears: it establishes only that the *repository interface* offers no flush, not
that flush order is uncontrollable — an injected `EntityManager` would give it. And given
finding 1, nothing needed forcing in the first place.

---

## What I would change before merge

1. **Finding 1** — rewrite the two-transaction rationale. Drop "orders DML by entity type
   rather than by call order" and the delete-then-reinsert cross-reference. *(required)*
2. **Finding 5** — cite `V2.2.00__base_v2_schema.sql:3308` instead of Hydra prd. *(required,
   one line)*
3. **Finding 4** — collapse to a single transaction, which also discharges finding 1
   entirely. *(recommended)*
4. **Finding 6** — one sentence warning the next editor off touching these rows in the outer
   transaction. *(recommended)*
5. **Findings 2 + 3** — your call, and a real one: `nanoTime` keys are smaller, are this
   repo's convention on this lane, and are the only option that makes concurrent runs
   correct rather than differently-broken. I would take them, with a simple id-based
   `@AfterEach` if you still want the DB left clean. *(recommendation, not a blocker)*
