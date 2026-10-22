---
ticket: SBDEV-1581
lane: implementation (T2)
worktree: .claude/worktrees/wms2-api/SBDEV-1581
branch: feature/SBDEV-1581-empty-pallet-cleanup (off origin/develop 944cc789)
commits: 9e2bd5c1, 60c782c2 (local only — not pushed, no PR)
date: 2026-10-18
---
# SBDEV-1581 EmptyPalletCleanupJob: implementation report

## Files changed

Production
- `schedulejob/EmptyPalletCleanupJob.java` (new). A clone of `StaleClubBatchCleanupJob`'s D′ shape: `JOB_NAME = "emptyPalletCleanup"`, `deriveSpecForCurrentTenant` reads `EMPTY_PALLET_CLEANUP_TIMER_HOUR/_MINUTE`, `runFor(spec)` takes the two-key lock `(100011, tenant_db_configuration.id)` and gates on `NEW_CRON_JOB_ACTIVATED` and `EMPTY_PALLET_CLEANUP_ACTIVATED`, and the metrics follow the SBDEV-3725 contract.
- `service/job/EmptyPalletCleanupJobService.java` (new). A non-transactional orchestrator. It selects ids once (cap of 500), then makes one cross-bean call to `relocateEmptyStoragePallet` per id. Each pallet's exception is caught, logged (WARN, with the id) and counted. It returns `Result(candidates, moved, skippedBusy, skippedGone, skippedState, failed)` and logs the same counts.
- `service/UnitloadBusinessService.java`
  - Adds `relocateEmptyStoragePallet(Long, String)` (`@Transactional(tenantTM)`), the `EmptyPalletRelocation` enum and a private `disqualification()` re-check.
  - `LocationAreaRepository` is field-injected, like the backfill repos, so the constructor stays stable.
- `repo/jpa/UnitloadRepository.java` adds two unexported methods:
  - `findEmptyStoragePalletIds(typeNames, emptyPalletsLocation, notLocked, batchSize)`: native, ids only, `ORDER BY u.id LIMIT`.
  - `lockIdForUpdateSkipLocked(id)`: `SELECT id … FOR UPDATE SKIP LOCKED`.
- `service/AdvisoryLockService.java`: `JobLockId.EMPTY_PALLET_CLEANUP = 100011L`. I re-verified 2026-10-18 that no `100011L` exists on any of the 440 `origin/*` refs.
- `schedulejob/JobMetricsConfiguration.java`: new `emptyPalletCleanupJobMetrics` bean, segment `empty_pallet_cleanup`.
- `schedulejob/SchedulingConfiguration.java`
  - Added the job to `CONFIGURED_JOB_NAMES` and as a constructor field/parameter.
  - Added `configureEmptyPalletCleanupGroups`, a verbatim clone of the stale-club method with the job swapped.
  - In `configureAllTasks` it is called last in the D′ block, before the single-trigger `releaseExpiredPicking` line.
  - Updated the current-state prose counts (six→seven jobs, five→six grouped). Historical statements are left as written.
- `service/WmsConstants.java`: three KEY/DEFAULT_VALUE pairs: `false`, `3`, `15`.
- `db/migration/V2.2.41__seed_empty_pallet_cleanup_sysprops.sql` (new). Three idempotent `INSERT … SELECT … WHERE NOT EXISTS (syskey, workstation='DEFAULT')` statements, using `nextval('public.seqentities')` and group `Backend`. `check-migration-version-collision.sh V2.2.41` reported it FREE.
- `landlord/config/LockTimeoutHibernateJpaDialect.java`: the javadoc census of native `FOR UPDATE` queries now names the new finder (commit 60c782c2).

Tests
- New: `integration/repository/EmptyStoragePalletCandidatesIT` (8), `integration/repository/UnitloadSkipLockedIT` (4), `schedulejob/EmptyPalletCleanupJobUnitTest` (17), `unit/service/job/EmptyPalletCleanupJobServiceUnitTest` (5), `unit/service/UnitloadBusinessServiceRelocateEmptyStoragePalletTest` (14), `unit/db/EmptyPalletCleanupSeedConsistencyTest` (2).
- Updated:
  - `SchedulingConfigurationUnitTest`: 3 constructor sites; new mock and derive stub; `EXPECTED_TRIGGER_COUNT` 6→7; per-zone counts +5→+6 and +4→+5; "N/6"→"N/7"; registry keys; and the clone's `runFor` wiring, membership log, registration-read-failure counting and context restore.
  - `SchedulingReconcileIdempotencyUnitTest`: constructor; derive stub; counts +4→+5.
  - `TestClassTransactionManagerArchTest`: registers `UnitloadSkipLockedIT` in `EXEMPT_NON_TRANSACTIONAL`.

## Red before (abridged; full logs in the scratchpad, `logs/red-unit.log`, `logs/red-it.log`)

Production stubs compiled: the selection query was `WHERE 1 = 0`, the per-pallet method returned null, and `runFor`/`deriveSpec`/`cleanupEmptyPallets` were no-ops. Every new test then failed on an assertion or on missing behaviour, never on setup:

```
EmptyPalletCleanupJobUnitTest           Tests run: 15, Failures: 11, Errors: 2   (Errors: UnnecessaryStubbing because no work ran; NPE on a null schedule, since tightened into an isNotNull assertion)
EmptyPalletCleanupJobServiceUnitTest    Tests run: 5,  Failures: 3,  Errors: 1   (countsEveryOutcome… [8 candidates: 2 moved, 1 busy, …])
UnitloadBusinessServiceRelocate…Test    Tests run: 11, Failures: 11              (assertNotRelocated: expected SKIPPED_STATE, was null; MOVED expected)
EmptyPalletCleanupSeedConsistencyTest   Tests run: 2,  Failures: 1               ([a missing file would make every assertion below vacuous])
EmptyStoragePalletCandidatesIT          Tests run: 8,  Failures: 8               (every test: [positive control])
UnitloadSkipLockedIT                    Tests run: 4,  pass   ← the real lock query existed from the start; its red is shown by hand-mutations M10/M11 below
```

## PIT (JDK 21.0.11, pitest 1.19.1)

New classes, targeted at the new tests (`logs/pit-new-classes.xml`):

| Class / scope | Killed | Survived | No coverage |
|---|---|---|---|
| `EmptyPalletCleanupJobService` | 10 | 0 | 0 |
| `UnitloadBusinessService.relocateEmptyStoragePallet` + `disqualification` | 23 | 0 | 0 |
| `EmptyPalletCleanupJob` | 37 | 2 | 0 |

The first pass had these survivors, and I killed them by adding assertions:
- `disqualification` returning `""` instead of its reason (4 survivors, 2 uncovered). Killed by asserting that the refusal reason appears in the log, plus tests for a missing location, a missing area and a row locked but not readable.
- In the job: a removed `stopTenantTimer`, a removed `recordDuration`, `-`→`+` in the duration, and the uncovered read-failure path. Killed with new tests `recordsTheElapsedDuration` and `unreadableTenantIsAReadFailure`, and a `stopTenantTimer` verify.

Remaining survivors are both log-only, and I accepted them:
- `runFor:251`: `-`→`+` in the `"end. took {}ms"` log argument.
- `runFor:282`: the negated `if (anyReadFailure)` that chooses between the two INFO wordings. The metric is passed `anyReadFailure` directly and is asserted.

`SchedulingConfiguration`, targeted at both scheduling test classes (`logs/pit-scheduling-2.xml`):
- `configureEmptyPalletCleanupGroups`: 25 killed, 1 survived, 1 no coverage.
- That is the same shape as its sibling `configureStaleClubBatchCleanupGroups` (25/1/1). Both share the same two non-killed mutants: the per-tenant `TenantContext.clear()` in the walk's finally, and the outer-catch `return false`.
- On the first pass the clone had 6 survivors. Four were killed by test additions that mirror what the sibling already had: `runFor(spec)` wiring, the "emptyPalletCleanup group" membership log, and `recordScheduleRegistrationReadFailure` ×3 verifies.
- The context-restore pair (`if (callerContext != null)` / `setCurrentTenant`) was killed by a new assertion in `callerContextIsRestored`: the count of `CRON_JOB_SHOW_LOG@nywh` reads must equal `EXPECTED_TRIGGER_COUNT + 6` (13). Before this, only the FIRST grouped method's restore was observable.
- Whole class: 221 killed / 20 survived / 7 no coverage, against 208/40 before my test changes. The remaining survivors are in pre-existing methods, which are out of scope.

## SQL hand-mutation (one predicate at a time; script `scratchpad/mut/run.py`, logs `mut/M*.log`)

| # | Mutation | Test that went red (message) |
|---|---|---|
| M1 | `ut.name IN (:typeNames)` → `OR true` | `excludesOtherTypes` [Tote, Case and Default are not returned to EmptyPallets] |
| M2 | `a.useforstorage = true` → `OR true` | `excludesPalletsOutsideStorageAreas` [PutAwayLane, Shipped, Palletizing and two fresh Inbound/Outbound locations …] |
| M3 | `l.name <> :emptyPalletsLocation` → `OR true` | `excludesPalletAlreadyAtEmptyPallets` [pallet … is already at EmptyPallets] |
| M4 | `u.entity_lock = :notLocked` → `OR true` | `excludesLockedPallet:128` [pallet … is locked (To-Delete)] |
| M5 | `COALESCE(u.entity_lock,0) = :notLocked` | `excludesLockedPallet:132` [… has a NULL entity_lock …] |
| M6 | no-stock `NOT EXISTS` → `OR true` | `excludesPalletWithStock` [pallet … holds a stock unit] |
| M7 | no-child `NOT EXISTS` → `OR true` | `excludesPalletWithChild` [cart … carries tote …] |
| M8 | `ORDER BY u.id DESC` | `ordersByIdAndCaps:202` [ORDER BY u.id] |
| M9 | `LIMIT :batchSize + 1` | `ordersByIdAndCaps:209` [LIMIT :batchSize — a cap of 1 returns exactly the lowest candidate id] |
| M10 | lock `FOR NO KEY UPDATE SKIP LOCKED` (what `@Lock(PESSIMISTIC_WRITE)` renders) | `UnitloadSkipLockedIT` IT-b and IT-c [uncommitted stockunit insert / child link takes FOR KEY SHARE …] |
| M11 | `SKIP LOCKED` dropped | IT-b, IT-c error (the lock wait hits this lane's lock_timeout) |
| M12 | `@RestResource(exported = false)` removed from `lockIdForUpdateSkipLocked` | `SdrLockingSearchNotExportedContextTest.noExportedSearchResolvesToALockingRepositoryMethod` |

All 12 were killed. Restore was proved with `git diff --stat` on `UnitloadRepository.java`: the script reported "CLEAN", and so did the post-M12 `git checkout` / `git diff`. M10 confirms the consult's central claim: with the lock that Hibernate's `@Lock(PESSIMISTIC_WRITE)` would render, the job does NOT skip a pallet that an uncommitted transaction is filling.

## Full suite (CI command `mvn -B -ntp clean verify -Pci -Dmaven.javadoc.skip=true -Dspringdoc.skip=true`, log `logs/full-suite.log`)

| Lane | This branch | develop CI baseline |
|---|---|---|
| Unit (surefire) | 8490 run, 0 failures, 0 errors, 1 skipped | 8445 run, 0 failures, 1 skipped |
| IT (failsafe) | 929 run, 0 failures, 0 errors, 23 skipped | 917 run, 0 failures, 23 skipped |

BUILD SUCCESS, with no failures to rerun.
- IT +12 equals my 8 + 4 new ITs.
- Unit +45 against the baseline: my new unit classes add 38. I have not attributed the remaining 7 and did not measure develop locally, so treat the baseline delta as approximate.
- I confirmed every new class from its report XML: 17/5/14/2 unit, 8/4 IT.
- Spring context load with the new beans is confirmed by the full-context `SdrLockingSearchNotExportedContextTest` (5/5) and by every Spring Boot IT in the run.

## Deviations from the consult / brief

1. **No `NeverMatcherNullBlindnessArchTest` ledger entry.** The job test verifies `tryLock`/`unlock` with literal arguments (`tryLock(JOB, 7L)`), not `anyLong()`. That avoids the primitive-unboxing trap without a matcher and names the tenant in each verification, so the inventory stays unchanged. The rule did flag two `never()` sites I first wrote with `anyString()`/`anyLong()` on reference parameters. I widened both to `any()`.
2. **The per-pallet "gone" path uses `existsById`** to split SKIPPED_BUSY from SKIPPED_GONE, as consult step 1 says. The brief said "skip (busy or gone)"; the behaviour is the same, the counts are just finer.
3. **Selection parameters are bound**, not inlined literals: type names, the EmptyPallets name and NOT_LOCKED all come from `WmsConstants`, as the stale-club sibling binds its states.
4. **No v1-to-v2-onboarding copy.** House rule: `v1-to-v2-onboarding/schema/` is the historical V1.0–V2.1 set baked into the base dump (CLAUDE.md "Migration directory layout"; `db/migration/README.md`). V2.2.x seeds such as V2.2.27, V2.2.29 and V2.2.36 have no copy there, and onboarded DBs receive V2.2.x through boot Flyway.
5. **Additional test `UnitloadSkipLockedIT`**, beyond the brief. It proves the FOR UPDATE vs FOR KEY SHARE claim against a real second backend, and it is what makes M10 a meaningful mutant.
6. Consult item 10's sbdocs catalog updates (§1, §2, §4.x, §6) are NOT done; that is outside the worktree scope. The code-side census (LockTimeoutHibernateJpaDialect) is done.

## Open risks / follow-ups

- **Release step needed.** `EMPTY_PALLET_CLEANUP_ACTIVATED` seeds `'false'` on every tenant. Per the consult, product must flip it per tenant with an UPDATE after a dev run. Nothing moves until then.
- **The sbdocs scheduled-jobs catalog** still lists six jobs and a 100010 high-water mark. It should be updated in a docs pass (verify-docs).
- **Inherited survivors.** The clone carries its sibling's two non-killed mutants (walk `clear()`, outer-catch `return false`), which the original review accepted.
- **Selection query cost.** It joins `unitload`→`unitload_type`/`location`/`location_area`, with two anti-joins, once per tenant per night. I have not EXPLAINed it on PRD; the consult measured 72 rows on WineCo. It is low risk at nightly cadence, but worth an EXPLAIN on c1wh (the largest unitload table) before activation there.
- **Fixture id collision.** `UnitloadSkipLockedIT` commits raw-JDBC rows with fixed ids 15810–15816. On a long-reused container, a sequence-generated row could one day collide with them, the same accepted shape as `StockunitSkipLockedIT`.
- **A busy pallet is skipped until the next night.** The busy and gone counts are logged only, with no metric. If ops wants visibility, add a `rowsProcessed`-style counter.
- **Re-fetch before merging.** Re-run `check-migration-version-collision.sh V2.2.41` and the `100011L` remote scan.

---

## Review-fix round (2026-10-18; lanes `review-lane-a.md`, `review-lane-b.md`)

New commits on the branch (no squash, not pushed):
- `a0c1d77c`: lane A behaviour (M-1, M-2, L-1, L-2, L-3, L-4)
- `7d9d1e24`: lane B rails, seed IT and counts (L-1, L-2, L-4, L-5, L-6, L-7)
- `d7c34e17`: native FOR UPDATE census (A-L7, B-L3)

**Red before.** The new tests were written first, with only a no-op `JobMetrics.tenantItems` stub added so they would compile (`logs/red-review-fix.log`). Failures:
- `allMovesFailedIsATenantFailure`, `outcomeCountsAreEmitted`, `partialFailureIsStillASuccess`, `tenantItems_incrementsCounterByNPerOutcome`, and `emptyPalletNoScheduleIsWarnedOnceAtBoot` [the boot pass names the tenant …]
- `refusesAPalletThatGainedStock` / `…GainedAChild`: "Business Can not relocate … has stock!/is carrier!", i.e. counted as failed, not skipped
- `refusesAPalletThatIsAChild`: the move proceeded
- `excludesPalletThatIsAChild` [… would silently detach it from its parent]
- `ordersByPerDayShuffleAndCaps` [ORDER BY md5(id || current_date), id …]
- `RelocateEmptyStoragePalletIT.stockArrivedAfterSelectionIsSkippedNotFailed`: BusinessException "has stock!"
- `NeverMatcherNullBlindnessArchTest` asked for the ledger entry `EmptyPalletCleanupJobUnitTest:1`

The tests that pin behaviour that already existed are red-proved by mutation instead, below: `RelocateEmptyStoragePalletIT` (a)–(c), the seed IT, and the int4 rail.

| Finding | Fix | Proof |
|---|---|---|
| **A M-1** no test sees `@Transactional` on the per-pallet method | New `integration/service/RelocateEmptyStoragePalletIT` (PG, `NOT_SUPPORTED`, committed fixture under client 15820, registered in `EXEMPT_NON_TRANSACTIONAL`). It calls the method through the autowired bean: (a) MOVED; the committed row is at EmptyPallets with entity_lock 0 and ONE `unitload_record` row (CONTAINER_RELOCATED_EMPTYPOOL, job comment, to EmptyPallets). (b) A second backend holds the row → SKIPPED_BUSY, nothing changed. (c) A per-test trigger makes the `unitload_record` insert raise → the call throws and the pallet is **still on the rack** with no audit row. (d) Stock committed first → SKIPPED_STATE. | Mutant R1 (annotation deleted) → red: `aFailureMidMoveLeavesNothingBehind:181 [the unit-load move must roll back WITH the failed audit insert. If the pallet is at EmptyPallets (id 9) here, the move committed on its own …]`. Restored, sha1 verified. |
| **A M-2** per-pallet failures invisible; an all-failed run advances last_success | `JobMetrics.tenantItems(tenant, outcome, n)` → `wms2.cron.<job>.items{tenant,outcome}`. `runFor` keeps the `Result`, increments moved / skipped_busy / skipped_gone / skipped_state / failed, and when `failed>0 && moved==0` records `tenantFailure(tenant,"AllMovesFailed")` (plus an ERROR) instead of `tenantSuccess`. That sets `anyFailure`, so `last_success` does not advance. | Unit tests cover: all five buckets; all-failed → failure, `never` success, `never` markLastSuccess; partial (1 moved, 2 failed) → success; zero candidates → success. PIT: `runFor` 47 killed; `JobMetrics.tenantItems` 1/1 killed. |
| **A L-1** stock or a child committed between selection and lock counted as failed | `disqualification` now probes `stockunitRepository.findByUnitloadId` and `findByCarrierunitloadId` under the lock → SKIPPED_STATE ("has stock" / "is a carrier"). `relocateEmptiedContainer`'s guards stay as a backstop. | Unit tests `refusesAPalletThatGainedStock` / `…GainedAChild`, and IT (d). PIT on `disqualification` and `relocateEmptyStoragePallet`: 29/29 killed. |
| **A L-2** literal-key `never()` | `unreadableTenantIsAReadFailure` → `verifyNoInteractions(advisoryLockService)`. `nonMemberTakesNoLock` → `times(1).tryLock(anyLong(), anyLong())` + the positive literal + `never().tryLock(anyLong())`. `anyLong()` is required because both overloads take primitive longs (declarations read). Ledger `EmptyPalletCleanupJobUnitTest:1` added with its reason. | Job test green; NeverMatcher rail green. |
| **A L-3** cap starvation by pallets that fail every night | Candidates ordered `md5(u.id::text \|\| current_date::text), u.id`. **Why this:** it is a per-day shuffle, so no fixed set of ≥500 failing ids can hold the cap night after night; it needs no state (a "last failed" cursor would need a per-tenant table or column); and it stays deterministic within a day. The cost is losing "lowest id first", which nothing depends on. | `ordersByPerDayShuffleAndCaps` compares our 8 ids' order with the database's own evaluation of the expression over a literal array (8! = 40,320 to one against a false pass), checks determinism on a second read, and checks the cap of 1. Mutant R3 (back to `ORDER BY u.id`) → red at `:237`. |
| **A L-4** a nested pallet qualifies and would be detached | `AND u.carrierunitload_id IS NULL` in the query; `disqualification` refuses "is a child of unitLoad N". | IT `excludesPalletThatIsAChild` with a positive control; unit `refusesAPalletThatIsAChild`. Mutant R2 (predicate → `OR true`) → red `[pallet … sits on carrier …]`. |
| **A L-7 / B L-3** census header said 2 while listing 3; four sibling comments said 2 | Header now says **3** (2 before SBDEV-1581) and records how it was derived (grep of non-comment `FOR UPDATE` lines in `repo/`: Stockunit, Outbox, Unitload). Pickingorder/CustomerorderBatch/Billoflading/Stockunit comments now point at the census instead of restating a number. | `grep -rn "2 native" src/` → 0 hits. |
| **A L-5** "in use" ignores reference tables | **Not implemented**: a product decision. **Accepted residual:** `cyclecount_position`, `pickingorder_unitload`, `goodsreceiptposition`, `billoflading_position` and `fix_location_assignment` are not consulted. The review measured 0 overlap on WineCo (72 candidates) and c1wh (18) PRD on 2026-10-18. Recorded in catalog §4.6a. | — |
| **A L-6** post-commit TOCTOU | No change (accepted in the consult; restated in catalog §4.6a residuals). | — |
| **B M-1** branch not pushed | Not mine, per the coordinator. Not pushed. | — |
| **B M-2** catalog | `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md`: §1 states the job set as "every name in `CONFIGURED_JOB_NAMES`" (seven now); the workload count is stated as a rule, with PendingReversalReconciliationJob noted as missing from the bullets; §2 tryLock/unlock lines re-read (`:182`/`:221`), lock-shape row, `EMPTY_PALLET_CLEANUP 100011L` row, and "next free" restated as a rule derived from `JobLockId` across remote refs (100012L at writing); new §4.6a; §6 row; §9 row; §10 log entry. | Doc only (sbdocs not in git). |
| **B L-1** ERROR every 5 min for tenants without V2.2.41 | In `configureEmptyPalletCleanupGroups` only, the per-tenant "timer sysprops absent" line is **WARN and boot-pass only** (`!reconciling`), and names V2.2.41. **Justification:** the sibling jobs' timer rows ship in the base dump (V2.2.00), so absence there is a fault and keeps its ERROR. This job's rows arrive only with V2.2.41, so their absence is the expected state on a tenant whose Flyway has not reached it, and the job is default-OFF there. The whole-job "not configured for any tenant" ERROR is unchanged. | `emptyPalletNoScheduleIsWarnedOnceAtBoot`: WARN at boot, no ERROR, and nothing on the next reconcile. PIT: the gate's mutants are killed (clone 26 killed vs 25 before). |
| **B L-2** stale five/six counts | Restated as rules ("every job", "every grouped job", `EXPECTED_TRIGGER_COUNT`) in `SchedulingConfiguration` (:683, both outer-catch comments) and 19 DisplayNames, messages and comments across `SchedulingConfigurationUnitTest` / `SchedulingReconcileIdempotencyUnitTest`. Historical statements are left as dated history. "There are six" (liveness detectors) is a correct count of a different thing and stays. | A grep of the remaining "six/five" hits shows only historical or correct ones. |
| **B L-4** int4 rail hand-enumerated | `everyJobLockIdFitsInt4` reflects over `JobLockId`'s `static final long` fields, with a non-vacuity check (≥11, including `EMPTY_PALLET_CLEANUP`). | Mutant R7 (`EMPTY_PALLET_CLEANUP = 2147483648L`) → red `[JobLockId.EMPTY_PALLET_CLEANUP must fit int4 …]`. |
| **B L-5** reconcile derivation pin | `emptyPalletDerivations` counter in the stub; `reconcileReadsNoSyspropWhenNothingIsMissing` asserts 1. | Green. The `deriveSpec` call is mutation-covered by PIT on the clone (26 killed). |
| **B L-6** no IT runs V2.2.41 | New `integration/schema/EmptyPalletCleanupSeedMigrationIT` (own container, migrates to 2.2.39 then 2.2.41, same harness as `DeadCancelSyspropRemovalMigrationIT`). It asserts: the keys are absent before; +3 rows exactly; the runtime read (`workstation='DEFAULT' order by client_id LIMIT 1`) returns each default; the row shape (client 0 / DEFAULT / Backend / not hidden); a pre-existing `ACTIVATED='true'` survives; a re-run of the file adds nothing. | R4 (guard on the wrong key) → red (Flyway migrate fails on the unique key). R5 (HOUR row on workstation `DEFAULTX`) → red `[runtime read of …TIMER_HOUR]`. R6 (MINUTE column list `sysvalue, syskey` swapped) → red `[runtime read of …TIMER_MINUTE]`. |
| **B L-7** timer description incomplete | Both descriptions now read "Read at boot, at every 5-minute reconcile and at each fire; a change applies within about 7 minutes." (180/160 chars). V2.2.41 is applied nowhere yet. | The seed IT and `SyspropMigrationDescriptionWidthTest` are green. |

**Hand mutations, round 2** (`scratchpad/mut/run2.py`, logs `mut/R*.log`): R1–R7 were all killed. The restore was proved by sha1 against pre-run hashes; all four files reported OK.

**PIT, round 2:**
- `EmptyPalletCleanupJob` 47 killed / 2 survived. The two survivors are the same log-only ones as before: the `"took {}ms"` arithmetic, and the INFO wording choice behind `if (anyReadFailure)`.
- `EmptyPalletCleanupJobService` 10/10, `UnitloadBusinessService` new methods 29/29, `JobMetrics.tenantItems` 1/1.
- `SchedulingConfiguration`: the clone is 26 killed / 1 survived / 1 no coverage. That matches the sibling's inherited pair (walk `TenantContext.clear()`, outer-catch `return false`).

**Full suite** (CI command, `logs/full-suite-2.log`):

| Lane | Round 2 | Round 1 | develop baseline |
|---|---|---|---|
| Unit | **8499** run, 0 F, 0 E, 1 skipped | 8490 | 8445 / 1 skipped |
| IT | **936** run, 0 F, 0 E, 23 skipped | 929 | 917 / 23 skipped |

BUILD SUCCESS. The deltas from round 1 are fully attributed:
- Unit +9: job +4, per-pallet +3, JobMetrics +1, scheduling +1.
- IT +7: RelocateEmptyStoragePalletIT 4, seed IT 2, candidates +1.
- Every new class was confirmed from its report XML.

**Note on the shared IT container.** `~/.testcontainers.properties` has no `testcontainers.reuse.enable`, so every run gets a fresh PostgreSQL container. Editing V2.2.41's description therefore cannot meet a stale checksum in this harness.

**Still open after this round:**
- Push and draft PR (B-M1, coordinator-owned).
- The per-tenant flag flip as a release step. c1wh has 18 candidates today and WineCo 72.
- L-5 product decision.
- EXPLAIN on c1wh before activation there (the `md5` order adds a sort over the candidate set, which is small).

---

## Re-review round (2026-10-18; `review-rereview.md`)

New commits (not pushed):
- `1c255b1b`: M-2, L-1
- `0f543795`: M-1, L-2, L-3, L-4
- `7217dd64`: L-5, L-6

Catalog L-7 is in sbdocs, which is not in git.

**Red before** (`logs/red-rereview.log`). `Result` gained the `refused` field first, still with the old classification. Failures:
- `onlyRefusalsIsNotATenantFailure`, `refusalsPlusOneUnexpectedFailureIsATenantFailure`, `allMovesFailedIsATenantFailure`, `outcomeCountsAreEmitted`
- `countsEveryOutcomeAndSurvivesFailures` [10 candidates: … 2 refused (BusinessException, FacadeException), 2 failed …]

The rewritten seed IT and the strengthened IT (c) pinned behaviour that already existed, so they were green on unmutated code. IT (c)'s root-cause assertion passing there is itself the proof that the forced trigger fires. Their red is shown by mutants R8–R11 below.

| Finding | Fix | Proof |
|---|---|---|
| **M-1** seed IT breaks once SBDEV-3672's V2.2.40 (also a `los_sysprop` insert) merges | `EmptyPalletCleanupSeedMigrationIT` has no watermark and no table-total count. It migrates a throwaway DB to the **classpath head**, then counts only `syskey IN (the three keys)` (= 3) and asserts the runtime read and row shape per key. The pre-existing-value and re-run case: migrate to head, set `ACTIVATED='true'`, delete the MINUTE row, exec the seed file twice. Then ACTIVATED is still `'true'`, MINUTE is re-seeded `'15'`, and each key has exactly 1 row. No other migration's rows can change any of these assertions. | R10 (V2.2.41 seeds MINUTE `'16'`) → red in both tests [runtime read of …TIMER_MINUTE] / [the missing row is seeded again with its default]. R11 (HOUR INSERT removed) → red [exactly the three … counted by key] / [one row for …TIMER_HOUR after two re-runs]. |
| **M-2** one poison pallet = permanent tenant failure; wording overstated | `Result(candidates, moved, skippedBusy, skippedGone, skippedState, refused, failed)`. **refused** = `BusinessException` or `FacadeException`. These are the two checked exceptions `relocateEmptyStoragePallet` declares (both `extends Exception`). On its path they are deterministic refusals, read from `UnitloadBusinessService`: `:321` MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION, `:251` STORAGELOCATION_LOCKED, `:261`/`:268` fixed-location, `:551`/`:555` carrier cycle, `:625`/`:628` has-stock/is-carrier. **failed** = any other exception, including `EntityNotFoundException` (a `RuntimeException`, e.g. a missing EmptyPallets row), data-access and commit failures. The job emits `items{outcome=refused}`. A tenant failure is `failed > 0 && moved == 0`, reason `NothingMovedUnexpectedFailures`, and the ERROR reads "no candidate moved and N failed unexpectedly (C candidates, R refused)". The javadoc (runFor metrics, `Result`) and catalog §4.6a say exactly that. Refusals never withhold `last_success`. | Unit tests: only refusals (1 refused, 0 moved) → success and `last_success`; refusals plus 1 unexpected → tenant failure; all six buckets counted; the service classifies Business/Facade → refused and optimistic-lock/EntityNotFound → failed, logging each with its id. PIT: service 11/11 killed (including the new catch); job 48 killed, with the same 2 log-only survivors as before. |
| **L-1** `runFor` javadoc orphaned | `recordItems` moved below `runFor`. | `runFor` is directly preceded by its javadoc. |
| **L-2** IT (c) accepted any exception | `.rootCause().hasMessageContaining("SBDEV-1581 IT: forced unitload_record failure")`. | Green on unmutated code, so the trigger really fires; R1/R8/R9 are red at `:185`. |
| **L-3** flush-order claim | The javadoc now says the pallet update and the audit insert commit or roll back together, and that Hibernate may flush the insert first, which the claim does not depend on. Without a transaction, the update has already committed on its own. | Prose. |
| **L-4** javadoc claimed untested transaction mutants | I ran both instead of narrowing the claim. R8 (`value = "landlordTransactionManager"`) and R9 (`propagation = NOT_SUPPORTED`) are both red at `aFailureMidMoveLeavesNothingBehind:185` [… the move committed on its own …]. The javadoc now names all three checked mutants. | `mut/R8.log`, `mut/R9.log`; restore sha1 OK. |
| **L-5** a tenant onboarded after boot without timer rows is never named | It is still WARN on the boot pass only (no spam). A reconcile pass now logs the same line at **DEBUG** ("reconcile pass; named at WARN only on the boot pass"). The gap is documented at the line, in the method javadoc, and in catalog §4.6a. | `emptyPalletNoScheduleIsWarnedOnceAtBoot`: boot WARN, no ERROR, nothing at INFO+ on the reconcile, and the DEBUG line names the tenant. PIT: the clone has 27 killed (the new DEBUG branch included); its 1 survivor and 1 no-coverage are the sibling's inherited pair. |
| **L-6** "the sixth grouped job" plus other closed counts | "the newest grouped job". A grep (`six|seven|sixth|seventh|five`) over `schedulejob/` and the two scheduling tests found more closed job counts, several of them mine from earlier rounds. Each current-state one is now a rule ("every job", "the jobs", "one cron per `CONFIGURED_JOB_NAMES` job"). That includes `PendingReversalReconciliationJob:56` ("The six SchedulingConfiguration jobs" → the `CONFIGURED_JOB_NAMES` rule) and its `:72` derivation, now dated "six at SBDEV-3321's writing — seven since SBDEV-1581". Left as written: historical statements, counts of other things (six liveness detectors, six sub-ops, fields), and assertion messages tied to asserted literals ("Only 6/7"). | Grep re-run; the remaining hits are historical or not job counts. |
| **L-7** catalog nits | `:49` doubled dash removed, along with that sentence's chained counts. `:37` reduced to the rule: the workload set is whatever the Derivation line returns, and no total is stated. | sbdocs edit. |
| **Open question** (is one stuck pallet meant to page?) | Resolved by the coordinator's decision: no. Refusals are visible on `items{outcome=refused}` and do not stall `last_success`. | — |

The reviewer's plain EXPLAIN on c1wh PRD (Sort over ~21 filtered rows, md5 computed only for those) closes my open item "EXPLAIN on c1wh before activation".

**Hand mutations, round 3** (`mut/run3.py`, `mut/summary3.txt`): R8–R11 were all killed. Restore was verified by sha1 (both files OK).

**Full suite** (CI command, `logs/full-suite-3.log`):

| Lane | Re-review | Review-fix | Round 1 | develop baseline |
|---|---|---|---|---|
| Unit | **8501** run, 0 F, 0 E, 1 skipped | 8499 | 8490 | 8445 / 1 |
| IT | **936** run, 0 F, 0 E, 23 skipped | 936 | 929 | 917 / 23 |

BUILD SUCCESS.
- Unit +2: `onlyRefusalsIsNotATenantFailure` and `refusalsPlusOneUnexpectedFailureIsATenantFailure`. The other changes were edits in place.
- IT unchanged: the seed IT's 2 tests were rewritten in place. I confirmed these from the report XML: SeedMigrationIT 2, RelocateIT 4, job test 23, service test 5.

**Merge note for the coordinator** (re-review M-1 side note): V2.2.40 (SBDEV-3672) and V2.2.41 (this branch) come from two branches. Whichever merges second applies out of order on dev (`app.flyway.out-of-order=true`). The seed IT no longer cares about the order, but the `wms-merge` Flyway preflight should still see both.

---

## Final-review round (2026-10-18; `review-final.md`)

New commit: **`ecb43857`** (not pushed). The catalog row is in sbdocs, which is not in git.

**Red before** (`logs/red-final.log`). `allRefusedIsATenantFailure` and `singleRefusedCandidateIsAllRefused` failed: both expected `tenantFailure("hydra","NothingMovedAllRefused")`, but the run recorded success. The success-side tests passed, as they should.

| Finding | Fix | Proof |
|---|---|---|
| **M-A** a type-wide refusal (every candidate refused) read as success | Rule, exactly as coded and as the `runFor` javadoc states it: a tenant failure iff `candidates > 0 && moved == 0 && (failed > 0 \|\| refused == candidates)`. The reason is `NothingMovedUnexpectedFailures` when `failed > 0`, otherwise `NothingMovedAllRefused`, each with its own ERROR line (the all-refused one names a location constraint on EmptyPallets' type as the likely cause). Refusals among busy / re-check skips with nothing moved stay a success. Catalog §4.6a states the same rule. | Unit tests, one per branch:<br>• all refused (3/3) → failure, AllRefused, no last_success<br>• single candidate refused → failure, AllRefused<br>• refused 1 + busy 1 + re-check 1, nothing moved → success<br>• 1 moved + 2 refused → success<br>• refused 3 + failed 1 → failure, UnexpectedFailures<br>• zero candidates → success (pins `candidates > 0`)<br>PIT on the job: **54 killed** (48 before), with the same 2 log-only survivors (`"took {}ms"` arithmetic; the INFO wording choice behind `anyReadFailure`). All mutants of the new condition and reason branch are killed. |
| **L-1** `Result` javadoc overclaims | It states the rule (the checked exceptions `relocateEmptyStoragePallet` declares) and names two kinds of refusal. **Deterministic:** a location-type constraint, which rejects a whole type. **Race-driven:** a concurrent commit between re-check and move, i.e. the has-stock/is-carrier backstop or "Unitload not found"; these clear on their own. `STORAGELOCATION_LOCKED` is removed, because the move runs with `ignoreLock = true`. | Prose. Service PIT is unchanged at 11/11. |
| **L-2** race and seed refusals share the `refused` bucket | No code change, as the review recommended. Catalog §4.6a now says a `refused` panel mixes signal with benign race noise. | sbdocs. |
| **L-3** "The seven jobs … seventh" in both test javadocs | Both now read "One trigger per job `configureAllTasks` registers … (the newest job: emptyPalletCleanup)". The three test messages "six of seven / all seven" became "all but one register; orderRelease refuses …", "every job was configured" and "reported as all of them". The literal-count strings still asserted against logs ("Only 6/7") stay, because they are what the code prints. | Re-grepped `seven|seventh` over `schedulejob/` (main and test) and the job service. The remaining hits are historical, dated, a time duration, or counts of other things. |
| **L-4** seed IT lost its "absent before V2.2.41" binding | `versionJustBelowSeed` asks Flyway for the highest classpath version below 2.2.41: 2.2.39 today, and 2.2.40 once SBDEV-3672 merges, with no edit needed. The test migrates to that version, asserts the three keys are absent, then migrates to head and asserts presence. There is still no fixed watermark and no table total. | R12: V2.2.41's ACTIVATED insert appended to `V2.2.39__*.sql` → red: `seedsTheThreeRows:156 [non-vacuity: none of the three keys exists at 2.2.39, the last migration before V2.2.41]`. V2.2.39 was restored from a copy and sha1 reports OK. |
| **L-5** `outOfOrder(true)` | Left as is, per the coordinator. | — |

**Full suite** (CI command, `logs/full-suite-4.log`):

| Lane | Final | Re-review | Review-fix | Round 1 | develop baseline |
|---|---|---|---|---|---|
| Unit | **8504** run, 0 F, 0 E, 1 skipped | 8501 | 8499 | 8490 | 8445 / 1 |
| IT | **936** run, 0 F, 0 E, 23 skipped | 936 | 936 | 929 | 917 / 23 |

BUILD SUCCESS.
- Unit +3: 4 new job tests replace 1 (`onlyRefusalsIsNotATenantFailure` became `someRefusedRestSkippedIsASuccess` plus the all-refused cases). The job class is at 26 per its report XML.
- IT unchanged: the seed IT's 2 tests were edited in place.

**Branch commits, oldest first:**
`9e2bd5c1`, `60c782c2`, `a0c1d77c`, `7d9d1e24`, `d7c34e17`, `1c255b1b`, `0f543795`, `7217dd64`, `ecb43857`. All are local; none is pushed.

---

## Docs round (2026-10-19; `review-final-2.md`)

Commit **`ca5e4dea`** (not pushed). It changes only docs, naming and log wording.

**Changes:**
- **M-1 (kept, documented):** one refused candidate out of one is a tenant failure. With a single candidate, a race cannot be told from a constraint, and a race clears the next night. This is now stated in:
  - the `Result` javadoc,
  - the `runFor` rule javadoc and the code comment,
  - catalog §4.6a.

  The pin is `EmptyPalletCleanupJobUnitTest.singleRefusedCandidateIsAllRefused`.
- **L-1:** the "newest job / newest grouped job" wording is now dated or positional ("added by SBDEV-1581", "whichever grouped call sits last below"). The constant's javadoc in both scheduling tests now reads "One trigger per job `configureAllTasks` registers, for a single-zone tenant."
- **L-2:** `fullRegistrationIsReportedAsAllSeven` was renamed to `fullRegistrationIsReportedAsAllOfThem`. A grep found no other reference; the remaining `AllSeven` hits are in `ItemDataControllerUnitTest`, which is unrelated. `TestIdentifierCountArchTest` passes (3/3) and its ledger has no entry for the scheduling classes.
- **L-3:** both tenant-failure ERRORs now use one format, "no candidate moved for T - F (C candidates, N failed unexpectedly, R refused)". The all-refused branch says "every candidate refused; one possible cause is a location constraint on EmptyPallets' type".
- **L-4:** `SEED_VERSION` is derived from the `SEED_FILE` name.

**Classes run** (`mvn -o verify -Dtest=… -Dit.test=EmptyPalletCleanupSeedMigrationIT`, BUILD SUCCESS):

| Class | Run | F/E/S |
|---|---|---|
| EmptyPalletCleanupJobUnitTest | 26 | 0/0/0 |
| EmptyPalletCleanupJobServiceUnitTest | 5 | 0/0/0 |
| SchedulingConfigurationUnitTest | 46 | 0/0/0 |
| SchedulingReconcileIdempotencyUnitTest | 29 | 0/0/0 |
| EmptyPalletCleanupSeedMigrationIT | 2 | 0/0/0 |
| TestIdentifierCountArchTest (rename rail) | 3 | 0/0/0 |

The full suite was not re-run, as instructed: this round changes no behaviour. The last full run is `ecb43857`: unit 8504, IT 936, 0 failures.
