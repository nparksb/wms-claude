---
ticket: SBDEV-1581
lane: architect consult (T2, single pass, read-only)
base: origin/develop 944cc789 (worktree .claude/worktrees/wms2-api/SBDEV-1581)
date: 2026-10-18
---
# SBDEV-1581 EmptyPalletCleanupJob: architect consult

**Verdict.** The planned shape is sound. Change three things. (1) Lock each pallet with a **native `FOR UPDATE SKIP LOCKED` scalar-id query**, not the JPA `@Lock` finder. (2) Run the per-pallet transaction in a method on `UnitloadBusinessService`, modelled on `recoverPalletFromNirvana`, so it cannot be bypassed by self-invocation. (3) Seed `ACTIVATED='false'` and use migration **V2.2.41**, because V2.2.40 is taken.

## Q1 Race safety: per-pallet protocol

**Precedent already in the code.** `UnitloadBusinessService.recoverPalletFromNirvana` (:909-980) does almost exactly this job for Nirwana:
`LockReads.forUpdate(entityManager, Unitload.class, unitloadId, unitloadRepository::findByIdForUpdate)` (:911) → re-checks type, lock, location and emptiness under the lock (:918-939) → `relocateEmptiedContainer(unitload, CODE_CONTAINER_RELOCATED_EMPTYPOOL, null, comment)` (:980). The comment there reads *"Same-bean self-invocation joins THIS transaction, so all writes are atomic per pallet."* Clone that method, not the club-batch service.

**What exists on `UnitloadRepository`:**
- `findByIdForUpdate` (:32-38) and `findByLabelidForUpdate` (:127-133) are `@Lock(PESSIMISTIC_WRITE)` and wait. The bound is the 5 s `lock_timeout` from `LockTimeoutHibernateJpaDialect`.
- There is **no** SKIP LOCKED finder on `UnitloadRepository`. The precedent is `StockunitRepository.findByIdForUpdateSkipLocked` (:115-122, `@QueryHints(lock.timeout = "-2")`). Its javadoc gives two rules: (a) `0`/NOWAIT is wrong because `55P03` aborts the transaction; (b) an empty result means either "locked" or "gone".

**Why the job should NOT simply clone `findByIdForUpdateSkipLocked`.** Hibernate renders PESSIMISTIC_WRITE as **`FOR NO KEY UPDATE`** on PostgreSQL (`LockReads.java:38-45`, measured by `StockunitSkipLockedIT`). `FOR NO KEY UPDATE` does **not** conflict with the `FOR KEY SHARE` that every FK insert or update takes on its parent row. Both `stockunit.unitload_id` and `unitload.carrierunitload_id` are FKs to `unitload(id)` (`V2.2.00__base_v2_schema.sql:4922` and `:4930`/`:5082`/`:5330`).

So with the JPA lock, take an operator transaction that has *already inserted* a stockunit, or set a child's `carrierunitload_id`, on pallet X but has not committed yet. It does not make the job skip X. The job's `findByUnitloadId` emptiness check runs under READ COMMITTED and cannot see the uncommitted row. The job moves X, then the operator commits stock onto a pallet that is now sitting in EmptyPallets.

The writers that do not lock the carrier are real. `transferUnitLoadToCarrierCore` (:408ff) reads the destination with a plain `findById`. `StockunitService.create` (:175-182) inserts directly.

**Recommended finder.** Add a new method on `UnitloadRepository`:
```java
@Query(value = "SELECT id FROM unitload WHERE id = :id FOR UPDATE SKIP LOCKED", nativeQuery = true)
@RestResource(exported = false)            // SdrLockingSearchNotExportedContextTest also detects SQL-spelled locks (SBDEV-3286 S-1)
Optional<Long> lockIdForUpdateSkipLocked(@Param("id") Long id);
```
- Full `FOR UPDATE` conflicts with an in-flight `FOR KEY SHARE`, so a pallet that an operator is filling right now is **skipped**, not moved.
- An operator who starts *after* the job takes the lock blocks for the length of one pallet transaction (milliseconds; bounded by `lock_timeout`), then proceeds. That outcome is the same as any ordinary concurrent move.
- It returns a **scalar**, so it creates no `EntityEntry`. A following plain `findById` is then the row's first touch, which satisfies the SBDEV-3244/3286 first-touch rule (`UnitloadRepository.java:68-77,108-118`; `LockReads` :23-33).
- The native SKIP LOCKED precedent is `OutboxMessageRepository.findAndClaimPending` (:55).
- The `LockReads` javadoc (:43-45) warns that hand-written `FOR UPDATE` adds an FK-share wait and a deadlock shape. Here the FK-share wait is the whole point. No deadlock can form, because the job holds **one row lock only**. `relocateEmptiedContainer` calls `transferUnitLoadToLocation(..., ignoreLock=true, ...)` (:673), and that skips the destination-location lock (:243-247). `CONTAINER_RELOCATED_EMPTYPOOL` is `PASS_THROUGH`, not `BLOCK_REALIGN` (`PickLineActivityCodeClassifier.java:50`), so no Pickingorder pre-walk locks are taken (:235-238). `processTransfer` (:510ff) writes only the unitload row and a `unitload_record` insert. The job therefore cannot be one leg of a lock cycle.

**Operator lock orders, for the record.**
- `StockunitBusinessService.transferStockToUnitLoad`: source SU → source UL → source Location → **dest UL** → dest SU → dest Location (:274/309/313/319/345/350). It locks the destination pallet row, so it serialises with the job.
- Palletize locks **pallet before parcel** (`MobilePalletizeWriteService:273`/`:349`, `:535`/`:555`). Truck loading does the same (`MobileTruckLoadingWriteService:299`/`:308`). Move-UL locks the moved UL (`MobileMoveUnitloadService:367`).
- The job takes only the pallet row, so it is consistent with all of them.

**Per-pallet protocol** (one `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` method, e.g. `UnitloadBusinessService.relocateEmptyStoragePallet(Long id, String comment)` returning an outcome enum):
1. `lockIdForUpdateSkipLocked(id)` → empty → `existsById(id)` to separate SKIPPED_BUSY from GONE (same rule as `StockunitRepository.java:117`). Return without throwing.
2. `findById(id)` (first touch, row now locked).
3. Re-check under the lock: `entity_lock == NOT_LOCKED` (null-safe `Integer.valueOf(...).equals`, as at :680); type name in {Pallet, Cart}; current location's `location_area.useforstorage = true`; current location ≠ `EmptyPallets` (defence in depth: on WineCo PRD, EmptyPallets sits in area *Inbound*, `useforstorage=false`, but seeds vary by tenant). Any mismatch → return SKIPPED_STATE. Do **not** throw.
4. Call `relocateEmptiedContainer(ul, CODE_CONTAINER_RELOCATED_EMPTYPOOL, null, comment)`. Its own emptiness re-checks (:624-629) now run under the lock. A `BusinessException` ("has stock" / "is carrier") rolls back this pallet only.

**Selection query.** Return **ids only** (`List<Long>`, `ORDER BY u.id`, with a cap like `MAX_CANDIDATES_PER_RUN=500` as in `StaleClubBatchCleanupJobService:14`). Returning entities would make step 2 a version-checked lock upgrade. Run it **outside** any transaction. The shape was verified on PRD 2026-10-18: WineCo 72 (all `entity_lock=0`). Hydra returns 0.

## Q2 Reuse `relocateEmptiedContainer`? Yes, with three caveats
- **Transaction semantics.** It is `@Transactional(tenantTM)` REQUIRED (:619). Called from the new method in the same bean, it joins the per-pallet transaction (self-invocation, same as :980). That is what you want. The per-pallet method must be invoked **cross-bean** from the job service so that its own `@Transactional` applies. A loop and a per-pallet method in the *same* bean would silently drop the transaction: the lock would be released at autocommit and every later write would be unprotected. `StaleClubBatchCleanupJobService:33-38` documents the same orchestrator/no-`@Transactional` split.
- **Default branch** (`sendToNirvana`, :650-660). Unreachable once types are filtered in step 3. The step-3 check is still mandatory, because a type can be renamed between selection and lock.
- **Operator on `unitload_record`.** `UnitloadRecordService:50/86` uses `SecurityContextUtils.getUserName()`, which returns `ANONYMOUS = "anonymous"` when there is no authentication (`SecurityContextUtils.java:31,39`). Scheduler threads have none. WineCo PRD already holds `anonymous`-operator rows (1,284 PACKAGING in 30 d). To keep the job's moves attributable, pass a fixed `comment` such as `"EmptyPalletCleanupJob (SBDEV-1581)"`; it lands in the record's additional content. Do not invent a fake principal.
- **No-op path.** The "already on EmptyPallets" return (:666-669) logs WARN and returns without writing. Step 3 makes it unreachable, but count it separately if it is ever hit.

## Q3 Wiring a naive clone would miss (every site that names stale club)
1. `AdvisoryLockService.JobLockId`: the next id is **`100011L`**. `PENDING_REVERSAL_RECONCILE = 100010L` (:271). The javadoc there says to derive from this block, never from the catalog. Remote-ref scan: no `100011L` on any fetched `origin/*` branch. Re-fetch before merging.
2. `WmsConstants`: three key constants plus `_DEFAULT_VALUE` constants, modelled on :1400-1403 and :1531-1534.
3. `JobMetricsConfiguration`: a new `@Bean emptyPalletCleanupJobMetrics` → `new JobMetrics(registry, "empty_pallet_cleanup")` (:46-48). The job constructor's `@Qualifier` must match the **bean method name** (javadoc :13).
4. `SchedulingConfiguration`:
   - add `EmptyPalletCleanupJob.JOB_NAME` to `CONFIGURED_JOB_NAMES` (:68-70);
   - add a constructor field and parameter (:203/:217/:228);
   - add a `configureEmptyPalletCleanupGroups` cloned from :1233-1377;
   - add it to the D′ block in `configureAllTasks` **before** the single-trigger `releaseExpiredPicking` line (:691-697), because ordering is load-bearing per :677-689;
   - the `configured == registeredNow` cross-check (:706-713) then holds automatically;
   - update the prose counts ("six"/"five grouped", :89, :333, :663).
5. Tests that construct `SchedulingConfiguration` positionally will not compile: `SchedulingConfigurationUnitTest` (:141, :614, :823) and `SchedulingReconcileIdempotencyUnitTest` (:184). Their exact registry-key and count assertions (e.g. :1084-1089, :1368-1393, Reconcile :542-603, :922) need a lenient stub for the new job's `deriveSpecForCurrentTenant` and updated counts.
6. `NeverMatcherNullBlindnessArchTest` (:698 ledger): the new job's unit test needs a `"EmptyPalletCleanupJobUnitTest:N"` entry if it uses `never().tryLock(anyLong(), anyLong())`, which it must, because `tryLock(long,long)` is primitive.
7. `SdrLockingSearchNotExportedContextTest`: passes only if the new finder is `exported=false`.
8. **Not required.** `AdminActionController` has no stale-club trigger (its six handlers cover other jobs, :170-200). The onboarding `01-preflight.sh:29` / `05-verify-bridge.sh:7` pin sysprop ids 140-143 for stale club. The new migration uses `nextval('seqentities')` like `V2.2.36`, so they are unaffected. `JobLockId`/job-count anti-drift: none found beyond the above.
9. **Migration number: use `V2.2.41`, not V2.2.40.** `origin/fix/SBDEV-3672-chunk-bol-shipped` already carries `V2.2.40__bol_shipped_chunk_size_and_outbox_message_link.sql`, and that is in flight in this session.
10. Docs: catalog §1 (six→seven), §2 (100011), §4.x new section, §6 summary row; and the `LockTimeoutHibernateJpaDialect` javadoc census (:28-41), which counts locking queries.

## Q4 ACTIVATED seed default: recommend `'false'`
- The house precedent for every mutating cron is off by default. `STALE_CLUB_BATCH_CLEANUP_ACTIVATED_DEFAULT_VALUE = "false"` (`WmsConstants:1403`). Catalog §6 shows `CLEAN_UP_OLD_MESSAGES` and `PICK_TIME_OUT` both default to **false**.
- Flyway runs on **every boot, on every tenant DB** (CLAUDE.md, Database), and that includes dev, UAT, Hydra and any future onboarding. `app.cron` is a JVM flag, not per-tenant (catalog §3.4). `NEW_CRON_JOB_ACTIVATED` is already `true` on WineCo, c1wh and nywh-shipitez PRD (queried 2026-10-18). So `'true'` would start moving pallets fleet-wide at the next 03:xx after deploy, with no per-tenant review. The first run is a 72-pallet bulk move on WineCo, and reversing it means a manual move-back.
- Product wants it running. Meet that with an explicit per-tenant `UPDATE los_sysprop SET sysvalue='true' WHERE syskey='EMPTY_PALLET_CLEANUP_ACTIVATED'` on the three named PRD tenants as a release step, after a dev run proves it. Hydra currently has 0 candidates, so leaving it off costs nothing.
- Pick a TIMER slot away from 02:55 (CleanUp) and 03:00 (StockSummary/StaleClub), e.g. **03:15**, so the backlog run does not share the tenant pool with two other nightly jobs.

## Trade-offs
| Option | Pros | Cons |
|---|---|---|
| Native `FOR UPDATE SKIP LOCKED` (rec.) | Skips a pallet an operator is filling, including uncommitted inserts; never waits | Hand-written lock clause (H2 accepts `FOR UPDATE`); briefly blocks FK inserts on that pallet |
| JPA `@Lock` + hint `-2` (clone of SU finder) | Matches the existing pattern exactly | `FOR NO KEY UPDATE` misses uncommitted stock/child inserts, so it can move a pallet that is being filled |
| Waiting `findByIdForUpdate` | No new finder | A busy pallet stalls the job up to 5 s each; a "wait then move" race remains |
| Seed `'true'` | Zero release steps | Fleet-wide activation incl. dev/UAT/Hydra; irreversible bulk first run without review |

## Residual (accepted, bounded)
An operator who scanned the pallet before the job's commit, and acts on it after the commit, finds it in EmptyPallets. This is the same as any concurrent manual move. The job holds the row for milliseconds and only touches empty, unlocked containers.
