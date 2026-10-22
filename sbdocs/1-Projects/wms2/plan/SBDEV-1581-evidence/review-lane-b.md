---
ticket: SBDEV-1581
lane: independent review B (Flyway seed, scheduler wiring, test rails, docs claims)
reviewer: critic (read-only; no mvn run in the worktree)
worktree: .claude/worktrees/wms2-api/SBDEV-1581
range: origin/develop...HEAD = 9e2bd5c1, 60c782c2 (branch feature/SBDEV-1581-empty-pallet-cleanup, LOCAL ONLY)
date: 2026-10-18
verdict: ACCEPT-WITH-RESERVATIONS
counts: Critical 0 · High 0 · Medium 2 · Low 7
---
# SBDEV-1581 review, lane B

## Verdict

**ACCEPT-WITH-RESERVATIONS.** Nothing blocks merge. The migration is correct and idempotent, and its guard matches the runtime read. Version and lock id are free on every remote ref. The scheduler wiring is a faithful clone, and the updated test counts follow from the arithmetic rather than having been bumped. The job does nothing until a per-tenant flag is flipped. The two Mediums are process items about reservations and the catalog. The Lows are stale count prose, two hand-enumerated rails, and seed-test depth.

## What was verified (and how)

| Check | Result | Evidence |
|---|---|---|
| Migration idempotent, guard = runtime read | PASS | `V2.2.41` guards each INSERT with `WHERE NOT EXISTS (... syskey = 'X' AND workstation = 'DEFAULT')`. The runtime read is `SyspropService.getSysvalue` → `SyspropRepository.findSysvalueBySyskey` (`SyspropRepository.java:30`), i.e. `syskey = :syskey and workstation = 'DEFAULT' order by client_id LIMIT 1`. The axes match. |
| id via `nextval('public.seqentities')` | PASS | Same as the V2.2.36 precedent. `AbstractBaseEntity` uses `allocationSize=1`, so a raw `nextval` cannot collide with a Hibernate block. |
| description < 255 | PASS | Measured lengths are 148, 128 and 108. `SyspropMigrationDescriptionWidthTest` also scans this file. The `additionalcontent` column exists in the base dump (`text`). |
| groupname / additionalcontent / hidden | PASS | `'Backend'`, `'true / false'`, `'0-23'`, `'0-59'` and `hidden=false` are identical to the stale-club rows in `V2.2.00__base_v2_schema.sql:2692-2694`. `client_id 0` exists on all four PRD tenants (queried). |
| Version V2.2.41 free | PASS (now) | After `git fetch origin`, I swept `ls-tree` across every `origin/*` ref. `V2.2.39` is on develop and many branches. `V2.2.40` exists only on `origin/fix/SBDEV-3672-chunk-bol-shipped`. No `V2.2.41__` and no other `V2.2.40__` exists anywhere. `db/check-migration-version-collision.sh V2.2.41` → `FREE … RESULT: clear.` |
| JobLockId 100011L unique | PASS (now) | `git grep -nE "100_?011\|1000011"` over every remote ref finds 0 hits outside this branch. `JobLockIdUniquenessUnitTest` reflects over the holder. |
| Out-of-order gap (V2.2.40 not on develop) | PASS | `app.flyway.out-of-order=true` (`application.properties:260`) is wired into the tenant migrator (`StartupFlywayMigrator:295`). If 1581 merges first, V2.2.40 later applies out of order with a WARN. The two migrations are independent (sysprop rows vs. an outbox column). |
| PRD baseline | INFO | wineco, hydra, c1wh-shipitez and nywh-shipitez PRD are all at Flyway `2.2.38`. None has an `EMPTY_PALLET%` row, so nothing is shadowed. All four have `NEW_CRON_JOB_ACTIVATED=true/DEFAULT`, so `EMPTY_PALLET_CLEANUP_ACTIVATED` is the only gate. That is why seeding it `'false'` is load-bearing. |
| Timer-slot claim "off the 02:55 / 03:00 slots" | PASS | Hydra and WineCo PRD: CLEAN_UP_OLD_MESSAGES 02:55, STALE_CLUB 03:00, STOCK_SUMMARY 03:00 (hydra) / 17:00 (wineco). |
| Seed consistency test pins + mutation | PASS (see L6 for depth) | `EmptyPalletCleanupSeedConsistencyTest` pins the Java defaults to their literal values (false/3/15), so a two-sided flip to `'true'` fails. It also pins `'KEY', 'VALUE'` adjacency count == 1 and the guard regex count == 1. These catch a changed literal, a dropped workstation arm, a missing guard, and a copy-paste guard on the wrong key (that gives count 2 / 0). |
| `CONFIGURED_JOB_NAMES`, constructor, field | PASS | `EmptyPalletCleanupJob.JOB_NAME` is added to the list. The constructor parameter and field are added, and every test construction site (`SchedulingConfigurationUnitTest` ×3, `SchedulingReconcileIdempotencyUnitTest` ×1) passes the mock in the right position. |
| `configureEmptyPalletCleanupGroups` clone | PASS | Diffed against `configureStaleClubBatchCleanupGroups`. The only changes are the job reference, the log label and the catch prose. It has the same walk-scoped restore, the same additive per-spec gate, the same ground-truth return, and its own outer catch. |
| Ordering in `configureAllTasks` | PASS | It is the last grouped call and comes before the single-trigger `onlyIfMissing(releaseExpired…)`. That keeps the single-trigger read dependent on every grouped restore. It is now pinned by the `EXPECTED_TRIGGER_COUNT + 6` showLog-read count. |
| JobMetrics bean / qualifier | PASS | The `@Bean emptyPalletCleanupJobMetrics` method name equals `@Qualifier("emptyPalletCleanupJobMetrics")`. The segment is `empty_pallet_cleanup`, which matches the javadoc. Context load is shown by the full-context ITs in the implementer's run. |
| Reconcile path | PASS | The same method is reused with `reconciling=true`. The additive gate is per registryKey. `aRealCronChange…` asserts `emptyPalletCleanup@0 9 9 * * *@America/Los_Angeles` is added and nothing is cancelled. |
| Updated counts arithmetically correct | PASS | 6 grouped + 1 single = 7. Two zones: 6×2+1 = 13 = 7+6. stale-club LA loses 1 → 7+5. showLog reads: 2×6+1 = 13. Reconcile cron change: 5 grouped stubs read `timerValue` (stale-club's does not) → 7+5. Each of these is derived, not just bumped. |
| Inert until flipped | PASS | `runFor` requires `parseBoolean(NEW_CRON_JOB_ACTIVATED) && parseBoolean(EMPTY_PALLET_CLEANUP_ACTIVATED)` (`EmptyPalletCleanupJob.java:241-242`). A missing row returns null, which parses as false. This is pinned by "EMPTY_PALLET_CLEANUP_ACTIVATED absent (sysprop never seeded): no work". The whole class only schedules under `app.cron=true` (`SchedulingConfiguration:30`, `@ConditionalOnProperty`, default `false`). The sysprop cache TTL is 2 min (`CacheConfig:36`), so a raw-SQL UPDATE flip takes effect within ~2 min with no restart. "Inert" means no mutation. The trigger still fires nightly, takes and releases a per-tenant advisory lock, and records `skipped_not_activated`. |

## Findings

### Medium

**M1. The branch is local-only, so the V2.2.41 and 100011L reservations are invisible to every other session's sweep.**
Evidence: `git branch -r | grep -i 1581` returns nothing. The implementation report's frontmatter says `commits: … (local only — not pushed, no PR)`. Both "free" results above are true only because no other session can see this branch either. That is the failure mode in `flyway-collision-sweep-cannot-catch-a-branch-pushed-later` (SBDEV-3010 and SBDEV-2967-C both claimed V2.2.20). The memory hub records the consequence of a Flyway collision: "Flyway finds two files at one version and fails on every tenant — and a tenant migration failure never aborts application boot, so nothing reports it." A shared lock id would make the two jobs take turns silently.
Mitigated by: `JobLockIdUniquenessUnitTest` fails CI once both lock ids meet on one branch. `wms-merge` preflight re-runs the collision checker.
Fix: push the branch now (a draft PR is fine) so other sessions' sweeps see the claims. Re-run `check-migration-version-collision.sh V2.2.41` and the `100011` remote grep immediately before merge, as the implementer already lists.

**M2. The scheduled-jobs catalog will name the wrong next-free lock id the moment this merges, and that line has misled allocators twice.**
Evidence: `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md:115` says `"The high-water mark is 100010L, so the next free id is 100011L."` `:585` says `"100001L–100010L are all taken, so the next free is 100011L"`. The job inventory still lists six jobs. The consult's item 10 (catalog §1 six→seven, §2 100011, a new §4.x, a §6 row) was explicitly deferred (implementation report, deviation 6). `JobLockIdUniquenessUnitTest`'s own javadoc says this line "has now been wrong twice".
Fix: in the same delivery, update the catalog §1/§2/§4.x/§6 and the two "next free" lines to `100012L`. Better, replace the number with "derive from `AdvisoryLockService.JobLockId`", per `prose-enumerations-rot-state-the-rule`. Add the three sysprops to §6.

### Low

**L1. New ERROR every 5 minutes for any tenant whose DB has not run V2.2.41. This is new noise, because the siblings' timer rows ship in the base dump and this job's do not.**
Evidence: in `configureEmptyPalletCleanupGroups`, `if (!noSchedule.isEmpty()) LOG.error("{}: timer sysprops absent or blank for tenant(s) {} …")` is not gated on `reconciling`. The reconcile re-walks every tenant every cycle. The siblings' `STALE_CLUB_*` timer rows are in `V2.2.00__base_v2_schema.sql:2692-2694`, so every tenant has them. `EMPTY_PALLET_CLEANUP_TIMER_*` exist only after V2.2.41. Any tenant whose V2.2.41 has not landed will log this ERROR 288 times a day:
- a stack with `APP_FLYWAY_MIGRATE_ON_STARTUP=false`;
- a legacy psql-provisioned DB skipped by `StartupFlywayMigrator`;
- a tenant frozen at an earlier failing migration (the hydra V2.2.07 precedent).

The reconcile is registered at `ContextRefreshedEvent`, which comes before the Flyway `ApplicationRunner` completes. So on the first deploy, a reconcile tick that lands mid-migration can also emit it once, transiently. The job is off on such tenants anyway, so the impact is log noise and a misleading "this job will not run" alarm.
Fix: one of the following.
- Downgrade the no-schedule line to WARN for this job.
- Gate the line to `!reconciling`, as the "not configured for any tenant" line already is.
- At minimum, add a sentence to the release note so ops do not chase it.

**L2. Stale "five/six" counts left in current-state prose and assertion messages.** The implementer said historical statements were left as written, but these describe the current state.
- `SchedulingConfiguration.java:683`: `"The five D′ grouped jobs FIRST, deliberately"`. There are six now.
- `SchedulingConfiguration.java:1384`: the stale-club outer catch says `"aborted registration of ALL SIX jobs"`, while the clone's identical catch says `"ALL SEVEN"`. The two copies of the same fact disagree.
- `SchedulingConfigurationUnitTest`: `:60` `"must not prevent the six"`; `:156` `"all six jobs take the error path"`; `:433` DisplayName `"still registers all six jobs"`; `:443` `"all six sysprop-driven jobs"` (the assertion is on 7 triggers); `:494` `"name ALL SIX"`; `:802` `"the six registered triggers are all CronTriggers"`; `:840` `"leave all six"`; `:895` `"all five timer-driven jobs"` (six now, and the test does stub the sixth key); `:1036/:1056/:1076` `"all six job bodies"` (the assertion uses `EXPECTED_TRIGGER_COUNT`=7); `:1311` `"all five grouped jobs' shortfall ERROR"`; `:1483` `"ALL FIVE grouped jobs' HOUR reads"` (the filter below it excludes six).
- `SchedulingReconcileIdempotencyUnitTest`: `:125` `"reschedules its five siblings"`; `:290` `"all five grouped jobs move"`; `:435` `"boot registers the six sysprop-driven jobs"`; `:543` DisplayName `"reschedules only the five sysprop-driven jobs"` (six are sysprop-driven, and five gain a group); `:875` `"for ALL FIVE grouped jobs"`; `:968` `"five of six registered"`.

None of these changes a verdict, but each is a false sentence a future reviewer will trust.
Fix: for each, either re-state it as a rule ("every grouped job", "all `EXPECTED_TRIGGER_COUNT`") or update the number. Rules are preferred, since this file has been re-counted at every step of SBDEV-3198.

**L3. The native `FOR UPDATE` census is half-updated: the header says 2 and the body adds a third, and four sibling copies still say 2.**
Evidence: `LockTimeoutHibernateJpaDialect.java:37` still opens with `"<b>2 native {@code FOR UPDATE} queries</b> outside the 15"`, then appends `"A third since SBDEV-1581: …lockIdForUpdateSkipLocked"`. `CustomerorderBatchRepository.java:30`, `StockunitRepository.java:78`, `BillofladingRepository.java:34` and `PickingorderRepository.java:47` each say `"the 2 native FOR UPDATE queries"`. This is the sibling sweep from `fixing-a-false-claim-tends-to-produce-a-new-one`.
Fix: change the header to 3, and fix the four repository comments (or point them at the dialect javadoc instead of restating a count).

**L4. `everyJobLockIdFitsInt4` is a hand-enumerated rail and omits the new two-key id.**
Evidence: `AdvisoryLockServicePerTenantLockUnitTest.java:262-268` lists eight constants. It omits `EMPTY_PALLET_CLEANUP`, and also, from before this branch, `OUTBOX_DISPATCHER_CLUB` and `PENDING_REVERSAL_RECONCILE`. The new job uses the two-key `(classid int4, objid int4)` form, which is exactly what this rail exists to protect. 100011 obviously fits, so there is no live defect, but the rail no longer covers its population.
Fix: reflect over `JobLockId`'s `public static final long` fields, as `JobLockIdUniquenessUnitTest` does, instead of listing them.

**L5. The reconcile "re-derives per tenant per cycle" pin was not extended to the new job.**
Evidence: `SchedulingReconcileIdempotencyUnitTest.reconcileReadsNoSyspropWhenNothingIsMissing` (`:851`ff) resets and asserts derivation counters for staleClub, stockSummary, cleanUpOldMessages, orderRelease and replenish (each `isEqualTo(1)`). There is no counter for `emptyPalletCleanupJob`, and its stub (`:306-318`) has none. A mutant that skips derivation for this job on reconcile is still killed elsewhere, by `aRealCronChange…` expecting the new `emptyPalletCleanup@0 9 9` group. So this is a symmetry gap, not a hole.
Fix: add an `emptyPalletDerivations` counter to the stub and assert `isEqualTo(1)`.

**L6. The seed test is text-adjacency only, and no IT asserts what V2.2.41 actually writes.**
Evidence: `EmptyPalletCleanupSeedConsistencyTest.assertSeeded` matches `'KEY', 'VALUE'` and the guard regex. It does not pin:
- column alignment (swapping `syskey, sysvalue` in the column list keeps the literal adjacency and passes);
- `workstation`/`client_id`/`groupname`/`hidden`;
- a guard-key swap between two statements (each count stays at 1).

`AppPostgresDBSetupExtension` does execute `db/migration`, so the SQL's validity (columns, 22001 width) is exercised by the IT lane. But nothing asserts that the three rows land readable via `findSysvalueBySyskey`, or that a pre-existing `DEFAULT` row is preserved on re-run (the "keeps ITS value" claim in the file header).
Fix: a small `*IT` that migrates, then asserts `findSysvalueBySyskey(k)` equals the Java default for the three keys. Pre-insert a row with a different value, re-run the three INSERT statements, and assert the value is unchanged and the count is 1. This is cheap, since the harness migrates `db/migration` already.

**L7. The timer descriptions understate when the value is read.**
Evidence: the HOUR/MINUTE descriptions say `"Read at boot and on the 5-minute schedule reconcile."` `runFor` also re-derives the spec at every fire (`EmptyPalletCleanupJob.java:199`) to decide membership. The reconcile is additive-only, so after an edit the old trigger keeps firing into nothing until restart (logged at INFO "matched no active tenant"). An operator who edits the hour sees the new time take effect within ~5–7 min (reconcile + 2-min cache), which is fine. The sentence is incomplete rather than wrong. Do NOT edit the file once it is applied anywhere, because the checksum would break. Today it is applied nowhere, so it is still editable.
Fix (optional, pre-merge only): `"Read at boot, at every 5-minute reconcile, and at each fire; a change applies within ~7 minutes."`

## What's missing (gaps, not defects in the diff)
- No release note or runbook entry in the repo for the per-tenant flip (`UPDATE los_sysprop SET sysvalue='true' WHERE syskey='EMPTY_PALLET_CLEANUP_ACTIVATED' AND workstation='DEFAULT'`). Note the `workstation` arm: the read filters on it. The consult names the flip as a release step, but it currently lives only in sbdocs evidence.
- No metric for "a tenant's V2.2.41 has not landed". `FlywaySchemaMetrics` covers staleness generically, so this is acceptable.

## Open questions (unscored)
- `LockReadRail` (`src/test/.../lockrail/LockReadRail.java:242-251`) classifies `lockIdForUpdateSkipLocked` as locking (native `FOR UPDATE` matches `NATIVE_LOCK`). But its stale-read check walks `entities(result)`, and a scalar `Long`/`Optional<Long>` result has no entity. So the rail cannot see the "entity loaded unlocked earlier in the same session, then locked by id, then `findById` returns the stale cached copy" shape. The per-pallet method opens a fresh transaction, so this is safe today. It is lane A's call whether to note this blind spot on the repository method.
- `EmptyPalletCleanupJobUnitTest:129` DisplayName says "not the stale-club 100006". It is correct (`STALE_CLUB_BATCH_CLEANUP = 100006L`), but it is an instance pin. The real protection is `JobLockIdUniquenessUnitTest`.

## Severity recalibration
- M1 was considered for High (silent all-tenant Flyway failure on collision). It stays Medium because CI's `JobLockIdUniquenessUnitTest` and `wms-merge`'s collision preflight both sit between a collision and production.
- M2 stays Medium rather than Low because it is a named DoD item (consult item 10) and the exact line has caused two misallocations.
- Mode: THOROUGH throughout. No Critical, and fewer than 3 High/Medium, so there was no escalation.
