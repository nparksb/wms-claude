# SBDEV-3258 — adversarial code review

- **Branch**: `bugfix/SBDEV-3258-pg-lane-residue` @ `d6e17668` (10 commits ahead of `origin/develop`, already merged with it)
- **Worktree**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3258`
- **Diff reviewed**: `git diff origin/develop...HEAD` — 12 files, +834 / −334
- **Reviewer constraint**: **no Maven was run** (per instruction — a concurrent build). Every finding
  below is derived from source, the base migration SQL, the Surefire 3.1.2 jar, and the SDR/Spring
  contracts. Nothing here is backed by an execution, and I say so where that matters.

---

## Verdict summary

| Severity | Count |
|---|---|
| Critical | **0** — none found |
| High | 2 |
| Medium | 4 |
| Low | 8 |

The work is **substantially sound**. The three headline claims all survive checking: the `<excludes/>`
drain is valid, the `@MockitoBean → @MockitoSpyBean` fix is *principled* (not a workaround), the
`H2TestExtension` deletion is safe, and the new `UserGroupUserRoleDeleteIT` genuinely kills the mutant
it names. `PgLaneFixtures`' eight hardcoded ids are **all correct** against
`V2.2.00__base_v2_schema.sql`.

The two High findings are both *residual* cross-test pollution — the exact defect class this ticket
exists to eliminate — and both are one-liner fixes.

---

## 1. Fixture constants — VERIFIED against `V2.2.00__base_v2_schema.sql`

Every constant in `src/test/java/net/aim_ai/wms/common/fixtures/PgLaneFixtures.java` checks out:

| Constant | Value | Evidence | Verdict |
|---|---|---|---|
| `SYSTEM_CLIENT_ID` | 0 | `V2.2.00:2377-2378` — `client` seeds **exactly one** row, id 0 "System-Client" | ✅ |
| `SEEDED_BOXTYPE_ID` | 0 | `:2312` — `boxtype` seeds 0..17 | ✅ |
| `SEEDED_AREA_ID` | 1 | `:2502` — `location_area` seeds **0..7**; 1 = "users" | ✅ value; ❌ doc (see L-1) |
| `SEEDED_TYPE_ID` | 1 | `:2544` — `location_type` seeds **0..7**; 1 = "NoRestriction" | ✅ value; ❌ doc |
| `FLOWBIN_LOCATION_TYPE_ID` | 2 | `:2544` — `location_type` id 2 `sltname='flowbin'` | ✅ |
| `SEEDED_ITEMUNIT_ID` | 0 | `:2451` — `itemunit` 0=BOTTLE, 1=PIECE | ✅ |
| `SEEDED_UNITLOAD_TYPE_ID` | 0 | `:3152` — `unitload_type` 0="Default" | ✅ |
| `FLOWBIN_PERMITTED_UNITLOAD_TYPE_ID` | 1 | `:2517` `location_constraint` row `(1,…,'only boxes allowed','ULC000002', 2, 1)`; DDL column order is `… storagelocationtype_id, unitloadtype_id` → **storagelocationtype 2 (flowbin) ⇒ unitloadtype 1 (PickLocation)** | ✅ (column order confirmed from DDL, not assumed) |
| `SEEDED_LOCATION_ID` | 0 | `:2460` — `location` seeds **0..34**; 0 = "Nirwana" | ✅ value; ❌ doc |

The NOT-NULL coverage claims also hold. I diffed each factory against the DDL:

- `location()` sets exactly the 12 non-id/version NOT NULL columns (`xpos,ypos,zpos,name,client_id,area_id,type_id` + 5 booleans) — the javadoc's "all 12" is right.
- `unitload()`, `stockunit()`, `fixLocationAssignment()`, `itemdata()`, `batch()` all cover their tables' full NOT NULL sets.
- `order()` covers all **9** required columns (`externalnumber, prio, state, client_id, orderbatch_id, pickingconfirmationsent, markedforcancellation, boxtype_id, markasvisited`) — the javadoc says "all 8", an undercount that does not affect correctness.
- `customerorder_batch` really is seeded with zero rows (`:2385-2390`), so `batch()` is genuinely required. Correct call.

The `entityLock(0)` line and its comment (product dereferences it) is a good catch and belongs there.

---

## 2. HIGH findings

### H-1 — `WarehouseStockReportServiceStreamIT` permanently commits 10,000 `itemdata` rows and the class javadoc claims the opposite

**`src/test/java/net/aim_ai/wms/integration/service/WarehouseStockReportServiceStreamIT.java:75-127`**

`@BeforeEach seedStockViewRows()` now inserts `SEED_ROW_COUNT = 5_000` rows through
`jdbcTemplate.batchUpdate`. `JdbcTemplate` borrows its own connection and auto-commits — the whole
point of the comment the author wrote 50 lines away in `ClientRepositoryTransactionDetailIT:160-164`.
`@BeforeEach` runs **per method**, the class has **two** methods, and **there is no cleanup at all**.

**Net effect: 10,000 `itemdata` rows are committed into the shared Testcontainers PostgreSQL and live
for the rest of the JVM.** They all carry `client_id = 0` (System-Client) and `putawaylocation_id = 0`.

That is not a hypothetical. `stock_view` is `itemdata LEFT JOIN stockunit LEFT JOIN client LEFT JOIN
unitload` (`V2.2.00:4685-4722`), so every one of those rows becomes a `stock_view` row, and
`stock_history()` (`V2.2.07:29`) scans `stock_view` in full — which means every later
`transaction_detail` / `transaction_summary` call in the lane now aggregates over 10,000 extra rows.

And the class javadoc, **unchanged by this diff**, still says (lines 42-47):

> *"the class-level `@Transactional("tenantTransactionManager")` wraps each test in a read-write
> auto-rollback transaction, **keeping the H2 state clean between runs**"*

That sentence was true when the seed was `em.persist`. It is now false — the seed no longer goes
through the persistence context at all — and it sits directly above the code that breaks it. It also
still says "H2 (used in the integration-test profile)" on a class that runs on PostgreSQL.

**Concrete failure scenario**: the next author adds a PG-lane test that asserts anything absolute over
`itemdata`, `stock_view` or `stock_history` — the same shape as the `isZero()` in
`ActivateTransferAtomicityIT:152` or the `count(*) FROM adviceposition` in
`ReturnAdviceAutoReceiveIntegrationTest:242`. It passes alone, fails in the suite, and the cause is
10,000 invisible rows written by an unrelated class. This is precisely the defect the ticket's own
commit `1c74c0fa` ("stop a jdbcTemplate seed leaking across classes") was written to stop; the fix was
applied to one of the two leaking classes.

*I swept every PG-lane class for global counts and **no existing assertion breaks today*** — the
`ActivateTransferAtomicityIT` count is filtered to `state=505 AND transferlane_id IS NOT NULL`, which
these rows do not match. The severity is for the unbounded latent hazard plus the actively false doc,
not for a current red.

**Fix** (one method):

```java
@AfterEach
void dropSeededRows() {
    jdbcTemplate.update("DELETE FROM itemdata WHERE item_nr LIKE ?", runTag + "-SKU-%");
}
```

and correct the class javadoc's "H2" / "keeping state clean" paragraph.

---

### H-2 — `ClientRepositoryTransactionDetailIT` cleanup is on the happy path only; a failing assertion re-arms the exact poison the author measured

**`src/test/java/net/aim_ai/wms/integration/repository/ClientRepositoryTransactionDetailIT.java:160-167`**

```java
        jdbcTemplate.update("DELETE FROM stockrecord WHERE id = ?", recId);
        jdbcTemplate.update("DELETE FROM itemdata WHERE id = ?", itemId);
        jdbcTemplate.update("DELETE FROM client WHERE id = ?", clientId);
}
```

These three statements are the **last three lines of the test method body**, after ~20 assertions
(`:143-158`). AssertJ assertions throw. If any one of them fails — or if `getTransactionDetail` /
`getTransactionSummary` throws — **none of the DELETEs run**, and the committed `STOCK_RELOCATED` row
survives into the rest of the suite.

The author documented the consequence in the comment immediately above:

> *"Measured: the stray STOCK_RELOCATED row broke FixLocationAssignmentServiceIT in the full suite
> while both classes passed alone."*

So the failure mode is not speculative — it has been observed once already. As written, the *first*
failure of this test converts into a second, misattributed failure elsewhere, which is the worst
possible debugging outcome for a shared-database lane.

(The sibling `FixLocationAssignmentServiceIT` AC-9 has since been scoped by `fromstoragelocation`, so
that *specific* victim is now immune. Anything else scanning `stockrecord`, `itemdata` or `client`
globally is not.)

**Fix**: move the three DELETEs into an `@AfterEach` (runs on failure, and also covers a thrown
`getTransactionDetail`), or wrap the Act+Assert in `try { … } finally { … }`. Record the ids in
fields so `@AfterEach` can see them.

---

## 3. MEDIUM findings

### M-1 — the `isEmpty()` → `allSatisfy(bookend)` swap is *correct in direction* but drops the numeric check the comment claims to have verified

**`ClientRepositoryTransactionDetailIT.java:143-145`**

First, the author's diagnosis is **right**, and I verified it independently. `'BEGINNING'` and
`'ENDING'` are string literals in `transaction_detail`'s body (`V2.2.00:359` and `:426` in the two
UNION branches), and their branches join `stock_history($3) sh INNER JOIN itemdata i … INNER JOIN
client c …` — not `stockrecord`. `stock_view` is `itemdata LEFT JOIN stockunit`, so an `itemdata` row
with no stock still produces a view row (`total_stock` collapses to 0 via the `ELSE 0` arms). So the
two bookends **do** appear for this fixture, and the old `isEmpty()` could indeed never have passed.
That part of the ticket's story holds up.

**But the replacement is weaker than the intent it says it preserves.** The test's own stated contract
is *"the relocation amount of 9784 must not leak"*. That is enforced for the summary (`:149-158`, eight
`isEqualByComparingTo(ZERO)` assertions) and **not at all** for the detail rows — `allSatisfy` inspects
only `getTransaction_name()`.

The bookends' `total` column is **not** a constant. It is `sh.historical_stock`
(`V2.2.00:363`, `:430`), and `historical_stock = total_stock_today - received - returned + shipped -
adjustments` (`V2.2.07:36`). The `received` / `adjustments` terms are an explicit
`(activitycode, type)` allow-list over `stockrecord` — which is exactly the allow-list this test exists
to police.

**Concrete failure scenario the assertion misses**: someone adds `MANUAL_TRANSFER` to the `received`
CASE in `stock_history` (a one-line, plausible edit — `STOCK_REMOVED` and `MANUAL_REMOVAL` are already
in there). Both bookends come back with `total = -9784`. `transaction_name` is still `BEGINNING`/
`ENDING`, so **`allSatisfy` passes and the test stays green** while the report is wrong by 9784 units.

The comment even records that the author *observed* the right thing — *"both bookends came back with
every numeric field 0"* — and then did not assert it. The one-liner is available; `TransactionDetailView`
exposes `getTotal()` (`repo/projection/TransactionDetailView.java:27`):

```java
assertThat(detailRows)
    .as("exactly the two synthetic bookends, both carrying zero stock")
    .hasSize(2)
    .allSatisfy(row -> {
        assertThat(row.getTransaction_name()).isIn("BEGINNING", "ENDING");
        assertThat(nz(row.getTotal())).isEqualByComparingTo(BigDecimal.ZERO);
    });
```

The `hasSize(2)` also closes a second, smaller hole: `allSatisfy` on an **empty** list passes
vacuously, so if a future change made `stock_history` skip zero-stock items this test would silently
become a no-op with no visible signal.

### M-2 — `TransferLaneLeakOnCancelIT`'s javadoc **reintroduces** a false "the lane cannot boot" claim citing the CLOSED SBDEV-2217, and contradicts itself two lines later

**`src/test/java/net/aim_ai/wms/service/TransferLaneLeakOnCancelIT.java:27-38`**

The diff **added** this:

> *"The Postgres lane currently cannot boot a full Spring context — see `BasePostgresIntegrationTest`
> (TODO SBDEV-2217: landlord datasource / outbox_message Flyway gap). The harness is fixed as of
> SBDEV-3239; this now fails on an incomplete Location fixture…"*

immediately followed by the next paragraph:

> *"SBDEV-3258: these EXECUTE now… SBDEV-2217 is CLOSED, so nothing would ever have prompted a
> revisit."*

Both paragraphs are in the file **right now** (verified by reading the working tree, not just the
diff). The first is false on three counts — the lane boots, the fixture is complete, and SBDEV-2217 is
closed — and the second says so.

This is not a cosmetic nit. It is the *precise* failure mode the ticket was opened to eliminate: a
stale marker citing a closed ticket, which is the mechanism by which 14 test classes stayed dead at
~1.4 per month. Landing the fix while re-planting the marker in the same file undercuts the ticket's
own thesis. It reads like a botched merge resolution against the deleted `@Disabled` block.

**Fix**: delete lines 27-31 (`"The Postgres lane currently cannot boot…availability query."`). The
SBDEV-3258 paragraph below already says everything true.

### M-3 — AC-7 asserts an **annotation**, not a rollback; the DisplayName claims otherwise, and the observable state *is* reachable

**`src/test/java/net/aim_ai/wms/service/FixLocationAssignmentServiceIT.java:139-224`**

Credit where due — I checked the parts that could have been theatre and they are not:

- `new BusinessException(sentinel)` → the 1-arg ctor sets `key="placeholder"` and `parameter={sentinel}`
  (`exceptions/BusinessException.java:42-47`). `getMessage()` resolves through the `messages` bundle,
  where **`placeholder=%1s`** (`src/main/resources/messages.properties:10`). In Java, `%1s` is
  *width 1*, not positional — so `String.format("%1s", sentinel)` returns the sentinel unpadded and
  `hasMessage(sentinel)` **does** match. This is the one place in the diff where the known
  `%Ns`-is-not-positional trap works in the test's favour.
- The spy fires at the intended site. `recordRelocation` has exactly two callers in `src/main`
  (`FixLocationAssignmentService:175`, `StockunitService:299`), and the second is not reachable from
  `move()` — so the sentinel really does come from *after* the relocation write and after
  `fixLocationAssignmentRepository.save`, not from one of the nine guards.
- `move()` carries exactly what the reflection block asserts:
  `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`
  (`FixLocationAssignmentService.java:111`).

So the test is *not* vacuous. But two things are wrong with how it is presented and pinned:

**(a) The `@DisplayName` is a claim the test does not make.**

> `"AC-7: a BusinessException after the relocation write marks the transaction rollback-only"`

Nothing in the method observes rollback-only state. The assertions are: the exception is ours, and the
annotation says what it says. A reader scanning the suite for AC-7 evidence gets a stronger impression
than the code supports.

**(b) The rollback-only state IS observable here — the author's three ruled-out approaches did not
include the one that works.** `TransactionAspectSupport.currentTransactionStatus()` does throw inside a
TestContext-managed transaction (correct), and REQUIRES_NEW does lose visibility of the seed (correct).
But `JpaTransactionManager.doSetRollbackOnly` propagates to the underlying `EntityTransaction`, which
is reachable from the bound resource:

```java
EntityManagerHolder holder = (EntityManagerHolder)
        TransactionSynchronizationManager.getResource(tenantEntityManagerFactory);
assertThat(holder.getEntityManager().getTransaction().getRollbackOnly())
    .as("the participating transaction must be marked rollback-only")
    .isTrue();
```

(Not executed — I could not run Maven. Offered as the direction to try, not as a verified snippet.)

**(c) The reflection pin can go false-RED on a semantically identical annotation.**
`Method.getAnnotation(Transactional.class)` reads the raw annotation with **no Spring `@AliasFor`
merging**. `@Transactional.value()` is an alias for `transactionManager()`. Rewrite line 111 as
`@Transactional(transactionManager = "tenantTransactionManager", rollbackFor = …)` — identical
behaviour — and `tx.value()` returns `""`, failing `:216-220`. It also cannot see a meta-annotated
custom `@TenantTransactional`. Use
`AnnotatedElementUtils.findMergedAnnotation(method, Transactional.class)` instead.

**(d) Minor fragility**: the answer sneaks a *checked* `BusinessException` out of `recordRelocation`,
whose signature (`StockrecordService.java:458-459`) declares **no** `throws`. This works today because
the `@MockitoSpyBean` is a ByteBuddy subclass and the JVM does not enforce checked exceptions at
runtime — but it would become an `UndeclaredThrowableException` the moment a JDK dynamic proxy enters
the chain (e.g. someone extracts a `StockrecordService` interface). Worth a one-line comment.

### M-4 — `ParcelMonitorViewServiceConcurrencyIT` commits its new fixture with fixed business keys and never cleans up

**`src/test/java/net/aim_ai/wms/integration/service/ParcelMonitorViewServiceConcurrencyIT.java:70-78`**

The seed runs inside `requiresNewTx()` — REQUIRES_NEW, so it **commits** — and now persists a
`CustomerorderBatch` *and* a `Customerorder` where before it persisted only the order. There is no
`@AfterEach` and no DELETE anywhere in the class (grep: `requiresNewTx` ×4, `AfterEach` ×0).

Both use **fixed** business keys — `"PARCELMON-BATCH-1"`, `"PARCELMON-ORD-1"` — unlike every other
fixture this diff adds, which suffix `System.nanoTime()`. That is fine for a single run, but it makes
the class non-idempotent against the container database the moment anything reruns it in the same JVM
or a uniqueness constraint is added to `customerorder_batch.number` / `customerorder.externalnumber`.

Since this class had **never executed before**, this is a new leak in practice, not an inherited one:
a committed `state = PACKED` `Customerorder` and a committed order batch now exist permanently for the
rest of the lane. Same class of hazard as H-1; smaller blast radius (2 rows).

**Fix**: nanoTime-suffix the two names, and add an `@AfterEach` deleting by the captured ids in a
`requiresNewTx()`.

---

## 4. LOW findings

- **L-1 — `PgLaneFixtures` javadoc contains three factual errors, one self-contradictory.**
  `PgLaneFixtures.java:33` says `location_area` / `location_type` are *"seeded 0..3"* — both are
  seeded **0..7**. `:53-57` says `location` seeds *"ids 0..2"* — it seeds **0..34**. Worse, `:139-143`
  (`itemdata(...)`) says `putawaylocation_id` points at *"`location`, which **has no seeded row** and
  so must be supplied by the caller"* — which is false, and directly contradicts `SEEDED_LOCATION_ID`
  30 lines above, **and** contradicts `WarehouseStockReportServiceStreamIT:99` which depends on
  seeded location 0 existing. A future author reading the `itemdata` javadoc will conclude the
  seeded-location approach is invalid and re-introduce the created-Location bug the file warns about.
  The constants are right; only the prose is wrong.

- **L-2 — the two reserved id ranges are not disjoint by construction.**
  `ClientRepositoryTransactionDetailIT.nextId()` (`:174-178`) yields `800_000_000 + (nanoTime % 1e9)++`
  → **8.0e8 … 1.8e9**. `WarehouseStockReportServiceStreamIT` (`:94`) yields
  `1_000_000_000 + (nanoTime % 100_000) * 10_000` → **1.0e9 … 2.0e9**, using 5,000 consecutive ids.
  They overlap, both write `itemdata`, and both auto-commit. Actual collision odds are negligible
  (3 ids vs 10,000 in a 1e9 span), so this is Low — but the comment's claim *"This base is far above
  anything either allocator reaches"* is about `TestDataFactory.nextId()` and Hibernate, and does not
  address the sibling test. Separately, `nanoTime % 100_000` gives the stream IT a **1-in-100,000
  chance of colliding with its own second `@BeforeEach`**, which would surface as a duplicate-key
  error attributed to nothing. A static `AtomicLong` base per class would make both disjoint by
  construction.

- **L-3 — the smoke test's only assertion is vacuous and is provably strengthenable.**
  `ClientRepositoryTransactionDetailIT:68` — `assertThat(rows).isNotNull()` on a Spring Data return
  value can never fail. Every UNION branch of `transaction_detail` requires `c.cl_nr = $1`, and the
  client code is `"NO-SUCH-CLIENT-" + nanoTime()`, so `isEmpty()` is guaranteed and strictly stronger.
  Also note the stale comment at `:52` — *"A call with no matching data returns an empty list"* — which
  the sibling test's whole investigation shows is false in general (bookends).

- **L-4 — `totalCount` is computed and never asserted.**
  `WarehouseStockReportServiceStreamIT:133-138` increments `totalCount` in the consumer and never reads
  it. Either assert something with it (`isGreaterThanOrEqualTo(scopedCount.get())`) or drop it.

- **L-5 — fixture variety silently reduced.** The old seed spread rows across 50 clients
  (`sv.setClientId(i % 50)`); the new one puts all 5,000 on `SYSTEM_CLIENT_ID`. The distinctness
  assertion is on `(clientNumber, itemDataNumber)`, so the client axis of that key is now constant and
  the test can no longer detect a client-side fan-out in `stock_view`. Low because the view's
  `itemdata LEFT JOIN client` makes such a fan-out structurally impossible — but the assertion's
  description still promises a two-part key.

- **L-6 — `as()` with a format argument and no format specifier.**
  `WarehouseStockReportServiceStreamIT:171` — `as("every seeded row must be emitted exactly once",
  SEED_ROW_COUNT)`. Harmless (`String.format` ignores the extra arg) but the `%d` was clearly meant to
  survive the edit.

- **L-7 — `hasMessage(sentinel)` is silently coupled to a resource-bundle entry.** Per M-3, the AC-7
  assertion only works because `messages.properties:10` reads `placeholder=%1s`. Change that entry —
  or add a locale-specific bundle without it — and the test fails with a message that points at
  Mockito rather than at the bundle. `hasMessageContaining(sentinel)` is materially more robust for the
  same intent.

- **L-8 — dead code left behind.**
  - `ClientRepositoryTransactionDetailIT`: unused imports `Client` (:4), `ClientDetailView` (:7),
    `BeforeEach` (:8), `Disabled` (:9), `Nested` (:11), `Optional` (:18). Also a stray de-indented
    closing brace at `:168`.
  - `ClientRepositoryIntegrationTest`: the `@Autowired JdbcTemplate jdbcTemplate` field (`:33`) is now
    unreferenced — it existed only for the extracted nested class — plus unused imports `JdbcTemplate`
    (:13), `TransactionSummaryView` (:14), `BigDecimal` (:16), `Disabled` (:8).
  - `WarehouseStockReportServiceStreamIT`: `locationRepository` field (`:62`) and imports `Itemdata`
    (:5), `Location` (:6), `LocationRepository` (:8), `StockView` (:11), `StockCountDto` (:10) are all
    unused now that the seed is raw SQL.
  - `TransferLaneLeakOnCancelIT:125-130`: six consecutive blank lines.

---

## 5. The four specific questions asked

**Q1 — vacuous or weakened assertions?** One real weakening (**M-1**, bookend `total` unasserted +
no size floor). The other two are sound: `FixLocationAssignmentServiceIT` AC-7's reflection pin is
**not** theatre — it goes red if `rollbackFor` is dropped, which is the AC-7 defect exactly — but it
proves nothing about rollback *happening*, and the DisplayName says it does (**M-3**). The
`WarehouseStockReportServiceStreamIT` scoping does **not** hide a failure: `mine.hasSize(5000)`
combined with a **global** `distinct.hasSize(keys.size())` is equivalent in strength for the seeded
rows — a duplicate of any of mine would fail the global check, and a missing one would fail the scoped
count. That change is correct.

**Q2 — fixture correctness?** All eight constants verified against the migration. Zero defects in the
values. Three javadoc errors (**L-1**), one of which contradicts a sibling constant.

**Q3 — cross-test pollution?** **Two real residual leaks.** The explicit cleanup added to
`ClientRepositoryTransactionDetailIT` covers everything it inserts (3 INSERTs / 3 DELETEs, correct FK
order) but only on the happy path (**H-2**). `WarehouseStockReportServiceStreamIT` commits 10,000 rows
and cleans up nothing (**H-1**). `ParcelMonitorViewServiceConcurrencyIT` commits 2 rows and cleans up
nothing (**M-4**). Reserved ranges: safe against `TestDataFactory.nextId()` (`AtomicLong` from 1000)
and Hibernate's generator, but the two new ranges overlap each other (**L-2**).

I swept all 27 PG-lane classes for absolute global assertions. The near-miss worth recording:
`ActivateTransferAtomicityIT:150-155` asserts `count(*) FROM customerorder WHERE state = 505 AND
transferlane_id IS NOT NULL` **`isZero()`**, and `TransferLaneLeakOnCancelIT:96-105` creates exactly
that row shape. It is safe **only** because `TransferLaneLeakOnCancelIT` inherits
`@Transactional("tenantTransactionManager")` and rolls back. If anyone ever gives that test a
REQUIRES_NEW seed, `ActivateTransferAtomicityIT` starts failing depending on class order. Worth a
comment on one side or the other.

**Q4 — the pom `<excludes/>`?** **Valid, and it means what the author intends.** Plexus'
`CollectionConverter` maps an element with zero children and no text to an *empty list*, not null.
Surefire 3.1.2's `AbstractSurefireMojo.getExcludeList()` then substitutes `getDefaultExcludes()` when
the list is empty — I confirmed both `getDefaultExcludes` and the literal `**/*$*` are present in
`maven-surefire-common-3.1.2.jar`'s `AbstractSurefireMojo.class` constant pool. So the net effect is
**identical to deleting the element**: no user excludes, plus Failsafe's default inner-class exclude
`**/*$*` re-engages (it was suppressed while the list was non-empty). Lane selection is unchanged —
`<includes>` is untouched. No defect. Stylistically I would delete the element rather than
self-close it, but the explanatory comment is anchored to it, which is a fair reason to keep it.

**Q5 — anything deleted that should not have been?** No.
- `H2TestExtension` was **genuinely dead**: `git grep H2TestExtension origin/develop -- src/` returns
  only two *prose* hits in `LoggerAttributionUnitTest`, both of which the diff updates in place. There
  is no `@ExtendWith(H2TestExtension.class)` anywhere, on either revision. It armed 14
  `System.setProperty` calls that would have been JVM-global in a shared fork — deleting it removes a
  real landmine, and keeping the `isCandidateComponent` guard while noting the offender is gone is the
  right call.
- The nested-class move is correct and the diagnosis behind it is right: a `@Nested` class cannot
  select a different base class from its enclosing one, so a move was the only fix. Both methods came
  across intact.
- `MessageCleanupBatchServiceIT`'s `@MockitoBean → @MockitoSpyBean` is **principled, not a workaround**.
  `@MockitoBean` replaces the *bean definition*, removing the `RepositoryFactoryBeanSupport` that
  `Repositories` / `ResourceMappings` reads its SDR metadata from — hence "Message (mapping exists but
  exported=false)". `@MockitoSpyBean` replaces only the *product singleton*, leaving the FactoryBean
  definition in place, so the metadata survives. The `when(...).thenAnswer` → `doAnswer(...).when(...)`
  rewrite is the required form for a spy. Behaviour of the assertion is unchanged.
- `UserGroupUserRoleDeleteIT` is the strongest new artifact in the diff. I traced the mutation by hand:
  with `R_DECOY.id == G_TARGET.id`, correct (`grouplist_id = 900100`) removes `(G_TARGET, R_PLAIN)`;
  mutant (`rolelist_id = 900100`) removes `(G_OTHER, R_DECOY)`. Both delete 1, and only the
  `linkExists` pair separates them — which is exactly what the test asserts. `deleteByGroupId` is
  `@Modifying(flushAutomatically = true)` with no `clearAutomatically`, and the test supplies the
  `em.clear()` itself. It seeds through `em.createNativeQuery` (inside the tenant transaction), so it
  **rolls back cleanly** — the one new class in this diff with no leak.

---

## Merge verdict

**Approve with two required fixes.**

The direction, the diagnoses and the fixture work are all sound, and the ticket delivers what it
claims: six previously-dead classes now execute, the exclusion list is legitimately empty, and the
new coverage is real (the mutation analysis in `UserGroupUserRoleDeleteIT` is genuinely load-bearing).
No Critical findings. Nothing in `src/main` is touched.

**Before merge** (both are a few lines, both are the ticket's own subject matter):

1. **H-1** — add an `@AfterEach` DELETE to `WarehouseStockReportServiceStreamIT` and fix the class
   javadoc's "H2 / keeps state clean" paragraph, which is now false at the exact point of the leak.
2. **H-2** — move `ClientRepositoryTransactionDetailIT`'s three DELETEs into `@AfterEach` so a failing
   assertion cannot re-arm the poison the author already measured once.

**Strongly recommended in the same pass** (M-1 and M-2 are one line each, and M-1 is the difference
between a report-contract lock and a name check):

3. **M-1** — add `.hasSize(2)` and a `getTotal()` zero-check inside the `allSatisfy`.
4. **M-2** — delete the resurrected "the Postgres lane currently cannot boot… SBDEV-2217" paragraph
   from `TransferLaneLeakOnCancelIT`.
5. **M-3** — rename the AC-7 test/DisplayName to describe what it asserts, and swap
   `getMethod(...).getAnnotation(...)` for `AnnotatedElementUtils.findMergedAnnotation(...)`.

**Follow-up ticket or opportunistic** — M-4 and the L-series.

**Caveat on this review**: no test was executed. Every "this passes / this fails" statement above is a
source-level derivation. The claims most worth re-checking against a real run are M-1's premise that
exactly two bookend rows come back, and M-3(b)'s suggested `EntityManagerHolder` probe.
