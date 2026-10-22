---
ticket: SBDEV-1581
lane: review A (correctness / concurrency / transactions), independent, read-only
worktree: .claude/worktrees/wms2-api/SBDEV-1581
reviewed: git diff origin/develop...HEAD (9e2bd5c1, 60c782c2)
date: 2026-10-18
verdict: APPROVE (fix M-1 and M-2 before the PR, per the fix-every-finding house rule)
counts: Critical 0 · High 0 · Medium 2 · Low 7
---
# SBDEV-1581 review, lane A: correctness, concurrency, transactions

## How this was checked
- I read the whole diff: the job, the job service, `relocateEmptyStoragePallet` and `disqualification`, both repository methods, the `SchedulingConfiguration` clone, the migration, and all new and changed tests.
- I read the existing code these depend on: `relocateEmptiedContainer` (:619-685), `transferUnitLoadToLocation` (:220-343), `processTransfer`, `recoverPalletFromNirvana`, `AdvisoryLockService` two-key, and `BasePostgresIntegrationTest`.
- **Clone parity was checked mechanically.** I normalised the names in `configureEmptyPalletCleanupGroups` against `configureStaleClubBatchCleanupGroups` (147 lines) and diffed them. They differ only in one comment ("SIX"→"SEVEN"). I did the same for `EmptyPalletCleanupJob` against `StaleClubBatchCleanupJob`: the only differences are javadoc and comments, plus the service call.
- **PRD read-only queries, 2026-10-18.** I ran the selection predicate plus "in use" overlaps on WineCo PRD (`wsl-wineco-prd`) and c1wh PRD:
  - WineCo PRD: **72 candidates**.
  - **c1wh PRD: 18 candidates.**
  - On both: 0 with `carrierunitload_id`, 0 referenced by `fix_location_assignment`, `pickingorder_unitload`, `cyclecount_position` or `billoflading_position`, and 0 by `goodsreceiptposition` (WineCo).
  - c1wh has exactly 1 `EmptyPallets` location.
- **Nothing was run in the worktree.** No build was run and `target/` was not touched.

## Focus answers (summary)
1. **Transactional: yes.**
   - `relocateEmptyStoragePallet` is `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`. It is called cross-bean from `EmptyPalletCleanupJobService`, so the proxy applies.
   - `EntityNotFoundException` is a `RuntimeException`, so it rolls back too.
   - `relocateEmptiedContainer` and `transferUnitLoadToLocation` are self-invoked (REQUIRED), so they join the per-pallet transaction. The `FOR UPDATE` row lock is held until that transaction commits.
   - **The recheck reads fresh data.** It is a new EntityManager per transaction, the lock is a scalar so it creates no EntityEntry, and there is no Hibernate L2 cache (`@Cache` or `use_second_level_cache` match nothing in `src/main`). Under READ COMMITTED each statement after the lock sees the latest committed row.
   - **Only M-1 is missing:** no test proves any of this through the proxy.
2. **Can it move a non-qualifying pallet?** I found no way to move a pallet that is non-empty, locked, outside a storage area, or of the wrong type: each predicate is rechecked under the lock. `relocateEmptiedContainer`'s emptiness guards run under the lock, and uncommitted FK writers are skipped (`UnitloadSkipLockedIT`). Two gaps remain:
   - "In use" is defined only by stock, children and `entity_lock`. See L-4 and L-5.
   - The accepted post-commit TOCTOU. See L-6.
3. **Isolation is correct.**
   - Per pallet: try/catch in the loop, and each pallet has its own transaction.
   - Per tenant: the clone's catch and finally.
   - `TenantContext` is cleared in the per-tenant `finally`.
   - The advisory lock is released in the inner `finally` on every path after `tryLock` returns true. It is not released when busy, which is correct.
4. **D′ parity is verbatim:**
   - spec derivation goes through `deriveSpecForCurrentTenant` on both sides;
   - membership is decided at fire time;
   - the activation check runs after the lock, as in the sibling;
   - the metrics bean is `emptyPalletCleanupJobMetrics`, matching the `@Qualifier`;
   - the method is added to `CONFIGURED_JOB_NAMES` and placed before the single-trigger read.
5. **Tests are mostly well-built.** They have positive controls, assert by id, use a timing bound, and avoid `any()` on primitives. The exceptions are M-1 (a transactional mutant survives) and L-2 (weak `never()`).
6. **Javadoc:** one stale count label (L-7). The other claims I checked are accurate.

## Findings

### [MEDIUM] M-1: no test sees whether the per-pallet method is transactional; deleting `@Transactional` survives the suite
- **File:** `src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java:1038`
  ```java
  @Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
  public EmptyPalletRelocation relocateEmptyStoragePallet(Long unitloadId, String comment) ...
  ```
- **Confidence:** HIGH
- **What each test covers:**
  - `UnitloadBusinessServiceRelocateEmptyStoragePalletTest` uses a Mockito spy with no proxy.
  - `EmptyPalletCleanupJobServiceUnitTest` mocks the business service.
  - `UnitloadSkipLockedIT` wraps the finder in its **own** `TransactionTemplate`.
  - `EmptyStoragePalletCandidatesIT` tests only the selection.
  - So no test calls `relocateEmptyStoragePallet` through the Spring proxy on PostgreSQL.
- **Failure scenario: someone removes the annotation**, or changes it to the landlord TM, `REQUIRES_NEW` or `NOT_SUPPORTED`. The memory note "Tx tests blind to propagation/readOnly" describes this class of mutant.
  1. The SKIP LOCKED query runs in the repository's own read-only transaction, and the row lock is released when that statement ends.
  2. `relocateEmptiedContainer` is self-invoked, so its `@Transactional` does not apply either.
  3. Every write after step 1 then autocommits with no lock: the unitload update, the `unitload_record` insert and the lock clear.
  4. The FOR KEY SHARE protection, which is the core claim of the consult, is silently gone.
  5. A `BusinessException` thrown midway would leave partial writes.
  6. **Every test stays green.**
- **The same blind spot applies to the orchestrator.** Adding `@Transactional(tenantTM)` to `EmptyPalletCleanupJobService.cleanupEmptyPallets` would let one RuntimeException mark the shared transaction rollback-only. The commit would then throw `UnexpectedRollbackException` and discard every move of the run. The javadoc warns about this, but nothing pins it.
- **Fix:** add one PostgreSQL IT (or extend `UnitloadSkipLockedIT`) that calls `unitloadBusinessService.relocateEmptyStoragePallet` through the autowired bean with `NOT_SUPPORTED` and a committed fixture:
  - (a) Happy path. Assert by id:
    - `storagelocation_id` = EmptyPallets;
    - `entity_lock` = 0;
    - one `unitload_record` row with `CONTAINER_RELOCATED_EMPTYPOOL` and the job comment.
  - (b) Hold the row from a second backend → `SKIPPED_BUSY`, and the pallet has not moved.
  - (c) Rollback. Insert a committed stockunit after selection but before the call, or stub nothing and seed a child → the call throws `BusinessException`, and **no** `unitload_record` row or location change persists.
  - (d) Optionally, an ArchUnit or reflection pin:
    - `relocateEmptyStoragePallet` carries `@Transactional` with `value = "tenantTransactionManager"` and default propagation;
    - `cleanupEmptyPallets` carries no `@Transactional`.
  - **Mutation-check:** deleting the annotation must turn (c) red.

### [MEDIUM] M-2: per-pallet failures never reach metrics; a tenant failing 100% of moves records `success` and advances `last_success`
- **Files and snippets:**
  - `schedulejob/EmptyPalletCleanupJob.java:248-249`
    ```java
    emptyPalletCleanupJobService.cleanupEmptyPallets();
    jobMetrics.tenantSuccess(tenantName);
    ```
  - `service/job/EmptyPalletCleanupJobService.java:393-397`: the catch only counts, and only WARNs.
- **Confidence:** HIGH
- **Scenario: one tenant cannot complete any move.**
  - Possible causes:
    - a seed has no `EmptyPallets` row, so `relocateEmptiedContainer` throws `EntityNotFoundException`;
    - a `location_constraint` on EmptyPallets' location type rejects Cart, so `relocateEmptiedContainer` throws `BusinessException`;
    - the tenant DB is flapping.
  - What happens: every candidate throws, `Result.failed == candidates`, and the job still records `tenantSuccess` and `markLastSuccess`. Grafana shows a healthy job every night while nothing moves, and the only signal is up to 500 WARN lines.
  - The `Result` record that would expose this is computed and then discarded at the call site.
- **Why this is not just inherited:** `StaleClubBatchCleanupJobService` shares the shape (it returns `void`), so this is parity with the sibling. But this job **built** the counts and then dropped them.
- **Fix:** take the `Result` in `runFor`. The minimum is a counter, e.g. `jobMetrics.tenantItems(tenant, "failed", n)`, or a `rowsProcessed`-style counter tagged by outcome. The stronger option is to treat `failed > 0 && moved == 0` as `tenantFailure(tenant, "AllMovesFailed")` so that it withholds `last_success`. The same counter covers busy/gone, which the implementation report lists as an open item. Add a unit test where the service returns `Result(3,0,0,0,0,3)` and assert the metric and `never().markLastSuccess()`.

### [LOW] L-1: stock that arrives and commits between selection and lock is counted as a failure and logged as one
- **Files:** `EmptyPalletCleanupJobService.java:393-397`, together with `relocateEmptiedContainer` at `UnitloadBusinessService.java:624-629`.
- **Confidence:** HIGH
- **Mechanism:** an operator commits a stockunit onto pallet X after the selection query and before the per-pallet lock. Under the lock, `disqualification` passes, because it does not check emptiness. Then `relocateEmptiedContainer` throws `"has stock!"`. That is correctly rolled back, but it is counted as `failed`, with the WARN *"failed to relocate … retried next run"*. In fact it is ordinary concurrent use, the same class of outcome as `SKIPPED_STATE`.
- **Impact:** at night this is noise. Once M-2 lands it becomes a false failure metric.
- **Fix:** run the two emptiness probes (`stockunitRepository.existsByUnitloadId` / `findByCarrierunitloadId`) inside `disqualification` and return `SKIPPED_STATE` ("has stock" / "is carrier"). Keep `relocateEmptiedContainer`'s guards as the backstop.

### [LOW] L-2: two `never()` lock verifications use one literal tenant id, so a lock under any other key passes
- **File:** `src/test/java/.../schedulejob/EmptyPalletCleanupJobUnitTest.java`
  - `:222`: `verify(advisoryLockService, never()).tryLock(JOB, 7L);`
  - `:275`: `verify(advisoryLockService, never()).tryLock(JOB, 9L);`
- **Confidence:** MEDIUM
- **Scenario:** suppose a regression locks the unreadable or non-member tenant under a wrong key, such as `config.getId()+1` or the one-key form `tryLock(JOB)`. Both tests stay green. The literal-argument choice avoids the primitive-unboxing trap, but it narrows `never()` to one exact call.
- **Fix:** use `verify(advisoryLockService, never()).tryLock(anyLong(), anyLong())` plus `never().tryLock(anyLong())`. `anyLong()` is primitive-safe; add the `NeverMatcherNullBlindnessArchTest` ledger entry if that rail asks for it. Alternatively, use `verifyNoInteractions(advisoryLockService)` in the test where no tenant is a member.

### [LOW] L-3: cap starvation; permanently failing candidates occupy the lowest-id slots every night
- **Files:** `UnitloadRepository.findEmptyStoragePalletIds` (`ORDER BY u.id … LIMIT :batchSize`) and `EmptyPalletCleanupJobService.MAX_CANDIDATES_PER_RUN = 500`.
- **Confidence:** MEDIUM
- **Scenario:** some pallets fail deterministically, for example from a location-constraint `BusinessException` (see M-2). They still match the selection, so with `ORDER BY u.id` they are re-selected first every night. If 500 or more such ids accumulate, no higher id is ever moved.
  - Today: 72 candidates on WineCo and 18 on c1wh, so this is theoretical.
  - The same applies to persistently busy rows.
- **Fix:** none needed now. Either note it in the javadoc beside the "drains lowest-id-first" claim, which is only true when the low ids succeed, or, once M-2 is done, alert on a non-zero `failed` count over N nights.

### [LOW] L-4: a pallet that is itself a CHILD (`carrierunitload_id` set) qualifies, and the move silently detaches it from its parent
- **Files:**
  - Selection: `UnitloadRepository.java` has no `u.carrierunitload_id IS NULL` predicate.
  - `disqualification`: no check.
  - `transferUnitLoadToLocation:328-333` sets `carrierunitload_id = null` and saves.
- **Confidence:** MEDIUM
- **Scenario:** an empty Pallet or Cart nested on another unit load in a storage area. This could be an empty pallet stacked on a cart, or a mis-scan in palletizing. The job unlinks it from its carrier and moves it alone, without locking the parent. The parent's tree changes under any operator working on it, and nothing in the result says "detached".
  - PRD today: 0 such rows on WineCo and c1wh.
- **Fix:** add `AND u.carrierunitload_id IS NULL` to the selection and a matching `disqualification` check ("is a child of N"), with an IT predicate test and positive control in `EmptyStoragePalletCandidatesIT`. The alternative is to document deliberately that nested empties are detached.

### [LOW] L-5: "in use" is only stock, children and `entity_lock`; reference tables are not consulted
- **File:** `UnitloadRepository.findEmptyStoragePalletIds`. These FKs to `unitload(id)` are not consulted (`V2.2.00`):
  - `cyclecount_position.unitload_id`
  - `pickingorder_unitload.unitload_id`
  - `goodsreceiptposition.unitload_id`
  - `billoflading_position.source_id`
  - `fix_location_assignment.assignedunitload_id`
  - `customerorder.parcel_id` / `pickingtote_id`: excluded by type anyway.
- **Confidence:** LOW. I measured **0 overlap** on WineCo PRD (72 candidates) and c1wh PRD (18), so this is surfaced, not blocking.
- **Scenarios:**
  - An empty pallet that is the subject of an open cycle-count position. After the move, the count position points at a unit load that is no longer at the counted location.
  - A fixed-location assignment whose `assignedunitload_id` is a Pallet-typed unit load that has been picked empty.
- **Fix:** decide with product whether any of these define "in use". If they do, add a `NOT EXISTS` for open rows, for example open cycle-count positions and any `fix_location_assignment`. In any case, record the decision in the job javadoc so the definition is explicit.

### [LOW] L-6: accepted post-commit TOCTOU; stock can land on a pallet that is already in EmptyPallets
- **File:** the design, accepted in architect-consult "Residual".
- **Confidence:** MEDIUM
- **Scenario:**
  1. An operator transaction reads pallet X without locking it (`StockunitService.create` inserts directly, per the consult).
  2. The job locks X, moves it and commits.
  3. The operator transaction then inserts a stockunit on X. Its FK check waited on our `FOR UPDATE`, then succeeds.
  4. Stock now sits on a pallet at `EmptyPallets`, which is a non-storage, empty-pool location. That is worse than "the operator finds it in EmptyPallets", the wording the consult uses.
- **Bound:** a millisecond window at 03:15. I am recording it so the residual is stated precisely, not to reopen it.
- **Fix:** none required. Optionally, use an EmptyPallets-holds-stock check in an existing monitor as the detector.

### [LOW] L-7: stale bold count in the lock census javadoc
- **File:** `src/main/java/net/aim_ai/wms/landlord/config/LockTimeoutHibernateJpaDialect.java:37`, which now reads `<b>2 native {@code FOR UPDATE} queries</b> outside the 15: … A third since SBDEV-1581: …`.
- **Confidence:** HIGH
- **Issue:** the bold headline still says 2 while the body lists 3. A reader scanning bold labels gets the wrong census. This is the "prose enumerations rot" pattern.
- **Fix:** change the label to `<b>3 native {@code FOR UPDATE} queries</b> (2 before SBDEV-1581)`, or drop the number from the label.

### Informational (not counted)
- **c1wh's first-run blast radius is not in the report.** The implementation report and the `MAX_CANDIDATES_PER_RUN` javadoc cite only WineCo (72). c1wh PRD has **18** candidates today. `NEW_CRON_JOB_ACTIVATED` is true there per the consult, so the activation release step should list c1wh's count as well.
- **The advisory lock is session-level on a landlord pooled connection** (`AdvisoryLockService:182ff`). That is pre-existing, shared with the sibling, and out of scope.

## Open questions (low-confidence, surfaced, not blocking)
- L-5's "in use" definition is a product decision; see above.

## Positive observations
- **The lock choice is correct and proven.** A full `FOR UPDATE SKIP LOCKED` was chosen over `@Lock(PESSIMISTIC_WRITE)`, which renders `FOR NO KEY UPDATE`, and `UnitloadSkipLockedIT` pins it against a real second backend:
  - it uses non-autocommit holders;
  - it has a positive control (IT-a);
  - it bounds the skip at 2 s against the 10 s `lock_timeout`;
  - it proves the pallet is free again after the holder rolls back.
  - Mutant M10 demonstrates the claim.
- **The design avoids lock upgrades and deadlocks.**
  - Selection returns ids only, and the lock is a scalar query, so the following `findById` is the first touch. There is no version-checked lock upgrade (SBDEV-3244/3286).
  - The job holds one row lock only. `ignoreLock=true` and the PASS_THROUGH activity code take no further locks, so no deadlock cycle is possible.
- **`disqualification` is careful.** It is null-safe on `entity_lock`, it covers a missing location or area as "not storage", and its type check keeps `relocateEmptiedContainer`'s retire-to-Nirwana default branch unreachable.
- **The ITs are well-built.**
  - `EmptyStoragePalletCandidatesIT` assigns a positive control to every exclusion and asserts by id.
  - It moves EmptyPallets into a storage area so that the name predicate is independently observable.
  - It spreads fixtures across both areas and both types.
- **Faithful clone.** The D′ shape of `configureEmptyPalletCleanupGroups` and `runFor` is verbatim, verified by normalised diff, so the sibling's reviewed fixes carry over unchanged:
  - M-4 context guard first;
  - malformed-row guard;
  - member flag that separates read failures from tenant failures;
  - lock released in `finally`;
  - context restored after the walk.
- **The seed is safe.** It is default-OFF, idempotent on `(syskey, workstation='DEFAULT')`, and its literals are pinned to `WmsConstants` by `EmptyPalletCleanupSeedConsistencyTest`.

## Recommendation
**APPROVE.** There are no Critical or High findings. M-1, the missing transactional IT, is the one I would not ship without: the whole safety argument rests on that one annotation and nothing guards it. M-2 should land with it. The Lows can go in the same pass.
