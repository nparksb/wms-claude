# SBDEV-3241 — review of the bucket-2 repairs (6 re-enabled tests, 4 files)

Reviewer lane: `review-3241-bucket2`. Read-only; no git state touched, no maven run.
Target: uncommitted working tree at
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3241`, branch
`bugfix/SBDEV-3241-2099-marker-audit`, diffed against `b907f20f`.

## Verdict

The three job/controller repairs are **correct**. `CustomerorderBatchRepositoryTest`
**passes, but for a different reason than the one it documents**, and two of its new comments
assert a mechanism that is not operating. Nothing here is a test-correctness failure — but four
Medium items should land before this commits, because three of them are *false statements written
into the test source*, which is the exact failure mode this ticket exists to clean up.

**0 Critical · 0 High · 4 Medium · 7 Low.**

---

## Answers to the five questions asked

**Q3 (control flow behind the strengthened `verify`s) — CORRECT.** On the empty-tenant path both
jobs call each of the three exactly once. `CleanUpOldMessagesJob.runFor`
(`src/main/java/net/aim_ai/wms/schedulejob/CleanUpOldMessagesJob.java`): `findByActiveTrue()` once,
then `if (active.isEmpty()) { LOG.warn; jobMetrics.markLastSuccess(); return; }` — the `return`
means the *second* `markLastSuccess()` site (`if (!anyFailure) jobMetrics.markLastSuccess();`) is
never reached, so `times(1)` holds. `finally { markLastRun(); recordDuration(...); }` gives exactly
one `markLastRun()`. `ReleaseExpiredPickingOrdersFromUserJob.runFor()` has the identical shape.
No double-call risk in either.

**Q4 (STRICT_STUBS in `ProcessPick`) — CLEAN.** `PickingController.processPick`
(`src/main/java/net/aim_ai/wms/controller/mobile/PickingController.java:349`) calls
`pickingorderepository.findById(orderId)`, so the retarget is right. All three tests use every stub
they declare: `shouldReturnOrderWhenSuccessful` (findById, position findById, isToteLabel→true,
processPick→order — all four consumed), `shouldReturnErrorWhenNotTote` (isToteLabel→false short-
circuits *after* both lookups, so both lookup stubs are still consumed), `shouldReturnErrorWhen
BusinessException` (all four consumed). No orphan stub, nothing unreachable. `grep findByIdForUpdate`
over the test file returns nothing, so no leftover from the old shape.

**Q2 (test isolation) — this is a real problem, but not the one you were worried about.**
Rollback is not protecting these rows *at all*, and the explicit `flush()` is not what makes them
visible. See M-1 and M-2. The narrow answer: A9 and A10 **do** see each other's batches, and neither
becomes flaky or order-dependent, because both assert by id (`contains` / `doesNotContain`) rather
than by emptiness. That was the right call and it is what saves the pair.

**Q1 (seeding correctness) — the rows are right; the fixture only exercises 2 of the 5 predicates.**
See M-3. `LIMIT 500` is not a practical hazard (see L-6).

**Q5 (invalidated comments)** — four, listed as M-2, M-4, L-1 and L-4.

---

## Medium

### M-1 — `@PersistenceContext` without `unitName = "tenant"` injects the **landlord** EntityManager; `entityManager.flush()` is a no-op for the seeded rows

`src/test/java/net/aim_ai/wms/unit/repo/CustomerorderBatchRepositoryTest.java:32-33`

```java
@PersistenceContext
private EntityManager entityManager;
```

There are two persistence units in this application and the landlord one is `@Primary`:

- `src/main/java/net/aim_ai/wms/landlord/config/LandlordDatabaseConfig.java:43-58` —
  `@Primary` on `landlordEntityManagerFactory`, `persistenceUnit("landlord")`,
  `packages("net.aim_ai.wms.landlord.model")`.
- `src/main/java/net/aim_ai/wms/landlord/config/TenantDatabaseConfig.java:54-73` —
  `tenantEntityManagerFactory`, `persistenceUnit("tenant")`, `packages("net.aim_ai.wms.model")`,
  **not** primary.

A bare `@PersistenceContext` resolves to the `@Primary` EMF, i.e. **landlord**. `CustomerorderBatch`
and `Customerorder` live in `net.aim_ai.wms.model` — the *tenant* unit. So the injected
`EntityManager` has never heard of these entities and `flush()` flushes an empty landlord
persistence context. The line does nothing.

Every other test class in this repo that injects an EntityManager for tenant entities names the unit
explicitly — four of four:

- `src/test/java/net/aim_ai/wms/integration/service/WarehouseStockReportServiceStreamIT.java:51`
- `src/test/java/net/aim_ai/wms/integration/service/SequenceTransactionServiceConcurrencyIT.java:87`
- `src/test/java/net/aim_ai/wms/integration/service/CustomerorderBatchServiceParallelStreamRegressionIT.java:68`
- `src/test/java/net/aim_ai/wms/integration/service/BillofladingServiceFinishTransferIT.java:69`

all `@PersistenceContext(unitName = "tenant")`. This new file is the only one that omits it.

**Do not "fix" this by adding `unitName = "tenant"`.** That would make `flush()` throw
`TransactionRequiredException`: the test-managed transaction runs on the landlord transaction
manager (M-2), so a tenant shared-EM proxy would have no transaction to join. The correct fix is to
**delete the `EntityManager` field and both `flush()` calls**, and rewrite the comments per M-2 —
the rows are already committed by the time the query runs.

### M-2 — the seeded rows are **committed, not rolled back**, and that (not the flush) is why the query sees them

The chain, all citable:

1. `BaseRepositoryIntegrationTest` is annotated bare `@Transactional`
   (`src/test/java/net/aim_ai/wms/common/base/BaseRepositoryIntegrationTest.java:29`) with no
   `transactionManager` qualifier. Spring's `TestContextTransactionUtils` then looks for a bean
   literally named `transactionManager` — **there is none** (`grep` over `src/main`+`src/test` for
   `PlatformTransactionManager transactionManager` / `@Bean("transactionManager")` returns zero;
   positive control: the same grep for `PlatformTransactionManager` alone hits
   `LandlordDatabaseConfig:62` and `TenantDatabaseConfig:75`) — and falls back to
   `getBean(PlatformTransactionManager.class)`, which resolves the `@Primary` one:
   **`landlordTransactionManager`** (`LandlordDatabaseConfig.java:60-65`).
2. `CustomerorderBatchRepository` and `CustomerorderRepository` are in `net.aim_ai.wms.repo.jpa`,
   which `TenantDatabaseConfig.java:22-26` binds with
   `transactionManagerRef = "tenantTransactionManager"`.
3. `SimpleJpaRepository.save` is `@Transactional`. Under `tenantTransactionManager`,
   `TransactionSynchronizationManager` has no resource bound for `tenantEntityManagerFactory` (only
   the landlord EMF is bound by the test transaction), so `PROPAGATION_REQUIRED` starts a **new**
   transaction on a **separate connection** and **commits** it.

Net: `clubBatch()` / `childOrder()` commit. The test-method rollback is on the landlord unit and
does not touch them. The native query then sees them because they are committed — not because of
`entityManager.flush()`.

Corroborating evidence that this is the pre-existing reality and not a theory:
`src/test/java/net/aim_ai/wms/integration/repository/CyclecountRepositoryIntegrationTest.java:38-51`
— same base class — carries a `@BeforeEach` `cleanupTestData()` that hunts down and deletes leftover
`CC-TEST*` rows. That helper is dead weight if rollback worked.

**Consequences.** H2 is `jdbc:h2:mem:wms_integration;DB_CLOSE_DELAY=-1`
(`src/test/resources/application-integration.properties:11`), so the 3 batches + 5 orders this
change adds survive for the life of that Spring context and are visible to every other class sharing
it (~20 `unit/repo/*` classes plus the `*H2Test` service/controller classes with the same context
key).

**Blast radius today: nil.** I checked — `grep -n "hasSize\|isEmpty()"` across
`src/test/java/net/aim_ai/wms/unit/repo/*.java` returns 10 hits, none of them over `customerorder`
or `customerorder_batch` (they are stockunit / advice / user / unitload / query-derivation
assertions). And the mechanism is **pre-existing, not introduced here**: `saveAndFind()` in this same
class and `CustomerorderRepositoryTest` already leak rows the same way.

So: not a blocker, but the change increases the leaked-row count 8-fold in this table pair while
the comments claim the opposite discipline. Worth a line on the ticket as a latent infrastructure
defect (`BaseRepositoryIntegrationTest` should specify
`@Transactional("tenantTransactionManager")`, or the repo tests should clean up after themselves) —
that fix is out of scope for this commit and would need its own regression pass over all 32
subclasses.

### M-3 — the fixture exercises only 2 of the 5 predicates; three mutants survive it, including the one that matters

Native query at `src/main/java/net/aim_ai/wms/repo/jpa/CustomerorderBatchRepository.java:35-44`.
Every seeded batch is `state = 530` and every one has at least one child order. Predicate by
predicate:

| Predicate | Discriminated? | Why |
|---|---|---|
| `cb.type = 'CLUB'` | **yes** | your `'PICK_PACK'` mutant killed it |
| `cb.state >= :minState` | **no** | no batch below 520 exists → *clause removed* survives |
| `cb.state < :finishedState` | **no** | no batch at/above 700 exists → *clause removed* survives |
| `EXISTS (… co.orderbatch_id = cb.id)` | **no** | no childless CLUB batch exists → *clause removed* survives |
| `NOT EXISTS (… co.state < :finishedState)` | **yes** | your drop-the-clause mutant killed it (A10) |
| `LIMIT :batchSize` | no | needs 501 rows; not worth chasing (L-6) |

The `EXISTS` gap is the substantive one. That clause is what stops a **freshly created CLUB batch
with no orders yet** from being reported stale and finalized by
`StaleClubBatchCleanupJobService.cleanupStaleBatches`
(`src/main/java/net/aim_ai/wms/service/job/StaleClubBatchCleanupJobService.java:43-47`). Delete it
and the fixture stays green.

This is the `mutation-fixture-needs-a-row-in-the-dominant-value-band` trap verbatim — a single
mid-band value (530) cannot discriminate a band predicate. Three cheap rows in A9 close all three:

```java
clubBatch("BATCH-A9-EMPTY", WmsConstants.State.ORDER_BATCH_CLUB_RUN_FINISHED); // no children
CustomerorderBatch below = clubBatch("BATCH-A9-BELOW", 510);
childOrder("ORD-A9-BELOW", below.getId(), WmsConstants.State.FINISHED);
CustomerorderBatch done = clubBatch("BATCH-A9-DONE", WmsConstants.State.FINISHED);
childOrder("ORD-A9-DONE", done.getId(), WmsConstants.State.FINISHED);
// …then doesNotContain(emptyBatch.getId(), below.getId(), done.getId())
```

Note that adding those makes `clubBatch`'s javadoc (L-4) false as written.

### M-4 — "Deleting that branch now turns this test red" is **false**, in both job tests

`CleanUpOldMessagesJobUnitTest.java:87-90` and
`ReleaseExpiredPickingOrdersFromUserJobUnitTest.java:62-65`:

> `// … runFor MUST consult the tenant list and MUST record the occurrence as a success before`
> `// returning early (… "No tenants configured" branch). Deleting that branch now turns this test red.`

Delete `if (active.isEmpty()) { LOG.warn(...); jobMetrics.markLastSuccess(); return; }` from either
job and trace it: `active` is empty → the `for` loop body never runs → `anyFailure` stays `false` →
`if (!anyFailure) jobMetrics.markLastSuccess();` fires once → `finally` fires `markLastRun()` once.
All four assertions still hold. **The test stays green.**

This is the same equivalence you already identified for the negated-conditional survivor
("the fall-through path produces identical mock interactions") — it applies to branch *removal* too,
so the in-code comment contradicts your own PIT note.

Two ways out, either is fine:

- **Reword** to what the assertions actually pin: *"the empty-tenant path records exactly one
  success and one run, and does no work"* — true, useful, and honest about not covering the branch.
- **Make it true** by also pinning the log line, mirroring the `messagesAt(Level.INFO)` /
  `ListAppender` pattern that already exists three nested classes down in this very file
  (`CleanUpOldMessagesJobUnitTest.java:151-181`, and its use at `:255-257`). Asserting the
  `"No tenants configured"` WARN kills branch-removal outright.

Everything else in these two repairs is accurate: the `SyspropRepository` → `SyspropService`
diagnosis matches the constructors (`CleanUpOldMessagesJob.java:110-116`,
`ReleaseExpiredPickingOrdersFromUserJob.java:117-124`), all six mocks now match all six parameters
in each, and the `markLastRun` PIT claim holds (the only other assertion touching that gauge is
`doesNotTouchTheWholeRunGauges`, which asserts the gauge **is zero** — a mutant removing
`markLastRun()` keeps it zero, so it survived until these lines existed).

---

## Low

**L-1 — three now-unused `import org.junit.jupiter.api.Disabled;`.**
`PickingControllerUnitTest.java:17`, `CleanUpOldMessagesJobUnitTest.java:25`,
`ReleaseExpiredPickingOrdersFromUserJobUnitTest.java:12`. Each file's last `@Disabled` was removed by
this diff. `CustomerorderBatchRepositoryTest` correctly dropped its import — the other three should
match. Won't fail the build; it's an inconsistency inside one commit.

**L-2 — `verify(tenantDbConfigurationRepository).findByActiveTrue()` is close to redundant.**
`BaseUnitTest` uses `@ExtendWith(MockitoExtension.class)`
(`src/test/java/net/aim_ai/wms/common/base/BaseUnitTest.java:18`), whose default strictness is
`STRICT_STUBS`. The existing `when(...findByActiveTrue()).thenReturn(emptyList())` already fails the
test with `UnnecessaryStubbingException` if the call disappears. The `verify` does add a genuine
exactly-once pin that the stub does not, so keep it — just don't credit it with more than that
(see M-4).

**L-3 — magic numbers where the constants exist and are used two lines away.**
`CustomerorderBatchRepositoryTest.java:99/114/121` use `530` = `WmsConstants.State
.ORDER_BATCH_CLUB_RUN_FINISHED`; `:116` uses `650` = `WmsConstants.State.PACKED`; `:92` uses `500` =
`StaleClubBatchCleanupJobService.MAX_CANDIDATES_PER_RUN` (`public static final`,
`StaleClubBatchCleanupJobService.java:22`). The same helper already spells `WmsConstants.State
.FINISHED` in full, so the mix is inconsistent. Using `MAX_CANDIDATES_PER_RUN` in particular keeps
the test tracking production if the cap ever changes.

**L-4 — `clubBatch`'s javadoc will be false as soon as M-3 lands.**
`:62` — *"A CLUB batch inside the query's window: ORDER_BATCH_ACTIVATED(520) <= state <
FINISHED(700)"* — but the method takes `state` as a free parameter and enforces nothing. It reads as
an invariant the helper guarantees. Reword to *"…caller supplies the state; the query's window is
520 <= state < 700"*.

**L-5 — stale `@Nested @DisplayName("doCalculation")` in both job tests.**
`CleanUpOldMessagesJobUnitTest.java:77` and
`ReleaseExpiredPickingOrdersFromUserJobUnitTest.java:50`. `doCalculation(Boolean)` was deleted by
SBDEV-3198 step 5; these nested classes now exercise `runFor` / `runForCurrentTenant`. Pre-existing,
but this change is what makes those tests appear in the surefire report again, so the wrong name is
now reader-facing. Rename to `runFor / runForCurrentTenant`.

**L-6 — `LIMIT 500` truncation: not a hazard, confirmed rather than assumed.**
Only committed CLUB batches could crowd the seeded ids out of a 500-row window. I grepped every
`OrderBatchType.CLUB` / `"CLUB"` occurrence in `src/test` (21 hits outside this file) — all of them
are in pure-Mockito unit tests (`CustomerorderServiceUnitTest`, `CustomerorderBatchServiceUnitTest`,
`ManageOrderServiceUnitTest`, `ViewDtoServiceUnitTest`, `ClubLineControllerUnitTest`,
`OrderRestControllerUnitTest`, `BillofladingServiceUnitTest`) with no database behind them. Zero
other classes commit a CLUB batch to the shared H2. Nothing to do.

**L-7 — precision nit in A10's comment.** `:119-120` — *"which is exactly how this test passed
vacuously for months"*. It was `@Disabled`; it never ran, so it never passed. *"would have passed
vacuously"* is the accurate form. Same class of overclaim the previous commit was cleaning up.

**L-8 — `ANY_SPEC` javadoc slightly overstates.** `CleanUpOldMessagesJobUnitTest.java:70-72` says the
spec "is exercised again"; on the empty path `spec` is only interpolated into the WARN message
(`LOG.warn("No tenants configured. Skipping {} for {}.", JOB_NAME, spec)`) — no comparison, which
the sentence's own second half concedes. Harmless; flag only because this ticket is about comments
that assert more than the code does.

---

## Things I checked that are fine — stated so they don't get re-derived

- **`@Mock JobMetrics` on a `final` class works here.** `JobMetrics` is `public final class`
  (`src/main/java/net/aim_ai/wms/schedulejob/JobMetrics.java:11`), but `pom.xml:374-378` pulls
  `mockito-inline` 5.2.0 explicitly, and there is ample precedent —
  `ReplenishOrderJobUnitTest.java:75` already does `@Mock private JobMetrics jobMetrics`. No
  `MockMaker` resource file overrides it.
- **`@InjectMocks` wiring.** Both jobs have a single 6-arg constructor and both tests now declare
  exactly those six mock types. Mockito's constructor injection ignores the `@Qualifier` on the
  `JobMetrics` parameter, which is correct here.
- **No new STRICT_STUBS exposure from the added mocks.** Unused *mocks* are not strict-stub
  violations; only unused *stubbings* are. The two new mocks in each job test carry no stubs.
- **`adminTriggerDoesNotConsultTheTenantList` is not destabilised by the new mocks.** It relies on
  `TenantContext` being unset; even with a polluted ThreadLocal it would call
  `findByTenantNameAndWarehouse` (which returns `Optional.empty()` by default) and refuse, and the
  assertion is on `findByActiveTrue`, which is unreachable either way.
- **Entity fixtures are complete.** `clubBatch` sets all three `@NotNull` columns on
  `CustomerorderBatch` (`number`, `state`, `clientId`); `childOrder` mirrors the field set that
  `CustomerorderRepositoryTest.findsByNumber` already uses, and `orderbatch_id` is the right column
  (`Customerorder.java:29-30`). No FK constraints exist to violate (no JPA associations in this
  codebase).
- **The `<`-vs-`<=` boundary on `co.state < :finishedState` IS pinned.** A9's children sit exactly at
  `FINISHED` (700); a `<=` mutant would count them as open and turn A9 red.
- **The `ProcessPick` regression is genuinely pinned without an extra `verify`.** If production
  reverted to `findByIdForUpdate`, the `findById(1L)` stub goes unused → `UnnecessaryStubbing
  Exception`, *and* the unstubbed `findByIdForUpdate` returns `Optional.empty()` →
  `EntityNotFoundException`. Adding `verify(..., never()).findByIdForUpdate(anyLong())` would be
  belt-and-braces, not new coverage. No change needed.
- **The class-level notes written in `b907f20f` are accurate.** `git show b907f20f~1` confirms the
  `@Nested` class in `ReleaseExpiredPickingOrdersFromUserJobUnitTest` did carry a class-level
  `@Disabled("… SBDEV-2099 env skip")` at line 43, so the second test's "the enclosing `@Nested`
  class carried an `@Disabled`" comment is correct as written.

---

## Recommended disposition

Land the three job/controller repairs as-is (plus L-1). For
`CustomerorderBatchRepositoryTest`, before committing:

1. **M-1 + M-2** — delete the `EntityManager` field and both `flush()` calls; replace the two
   comment blocks (`:29-31`, `:53-55`) with the real mechanism: *each repository `save()` runs on
   `tenantTransactionManager` and commits its own transaction, so the native query sees the rows —
   and, note, the test-level rollback does not remove them.*
2. **M-3** — add the three fixture rows so `EXISTS` and both state-band predicates become
   discriminating, and adjust L-4's javadoc.
3. **M-4** — reword or strengthen the branch claim in both job tests.
4. **L-3 / L-5 / L-7 / L-8** — cosmetic, same pass.

M-2's underlying infrastructure defect (`BaseRepositoryIntegrationTest` rolls back the wrong
transaction manager for all 32 subclasses) belongs on the ticket as a finding, not in this commit.
