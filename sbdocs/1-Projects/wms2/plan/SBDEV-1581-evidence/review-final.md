---
ticket: SBDEV-1581
kind: review
lane: final scoped review of round-2 fix commits
scope: git diff d7c34e17..HEAD (1c255b1b, 0f543795, 7217dd64), worktree .claude/worktrees/wms2-api/SBDEV-1581
date: 2026-10-18
verdict: APPROVE (with one Medium to decide and Lows)
---

# SBDEV-1581 final review, round-2 fixes

Read-only. mvn not run. Evidence: source reads of the diff and of `UnitloadBusinessService` (`relocateEmptyStoragePallet`, `relocateEmptiedContainer`, `transferUnitLoadToLocation`, `processTransfer`), `UnitloadRecordService`, `LockReads`, the seed IT, and `git ls-tree` of origin/fix/SBDEV-3672-chunk-bol-shipped.

**Counts:** CRITICAL 0 · HIGH 0 · MEDIUM 1 · LOW 5 · Open questions 0

## (1) Re-review findings, genuinely fixed?

| Finding | Status | Basis |
|---|---|---|
| M-1 (seed IT red once V2.2.40 lands) | Fixed | No watermark and no table total. Migrates to classpath head with `outOfOrder(true)`, counts only the three keys. V2.2.40 (`INSERT INTO public.los_sysprop`, on the 3672 branch) cannot change any assertion. See (3). |
| M-2 (poison pallet stalls last_success, wording) | Fixed as decided, with a residual: see M-A | Wording is now accurate ("no candidate moved and N failed unexpectedly"). Reason `NothingMovedUnexpectedFailures`. No `AllMovesFailed` or "every candidate failed" text left in `src/`. |
| L-1 orphan javadoc | Fixed | `recordItems` sits after `runFor`; `runFor` is directly preceded by its javadoc. |
| L-2 IT (c) `isNotNull` | Fixed | `.rootCause().hasMessageContaining("SBDEV-1581 IT: forced unitload_record failure")`. |
| L-3 flush-order prose | Fixed | Claim no longer depends on flush order. |
| L-4 untested mutants | Fixed by running them (R8, R9). Not re-run by me. |
| L-5 post-boot tenant | Fixed as documented gap | `else if (!noSchedule.isEmpty())` logs at DEBUG; the unit test asserts nothing at INFO+ and a DEBUG line naming the tenant. |
| L-6 closed count | Fixed at the cited line, mostly: see L-3 below | |
| L-7 catalog nits | Fixed: doubled dash gone, `:37` states the rule, §4.6a documents refused/failed. |

## (2) Refused vs failed: trace

Path: `EmptyPalletCleanupJobService.cleanupEmptyPallets` (not `@Transactional`, deliberately) calls the bean proxy `unitloadBusinessService.relocateEmptyStoragePallet`, which is `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`. Inside: `lockIdForUpdateSkipLocked`, `disqualification`, then `relocateEmptiedContainer` and `transferUnitLoadToLocation` (self-invocations, no second proxy, so no inner transaction boundary and no inner rollback-only marker).

- **Can a transient DB or lock failure surface as BusinessException/FacadeException?** I found no route. Nothing on the path catches and rewraps. The two files with `catch` in this path (`LockReads`) translate to `DataAccessException` (unchecked). `UnitloadRecordService.recordForTransferUnitLoad` declares nothing checked and has no catch. The location `FOR UPDATE` is skipped (`ignoreLock=true`), and the unit-load lock is SKIP LOCKED (returns empty, so SKIPPED_BUSY, not an exception). Optimistic-lock, deadlock, connection and commit failures are unchecked and land in `failed`. `EntityNotFoundException extends RuntimeException`, so a missing EmptyPallets row or type is `failed`.
- **RuntimeException wrapping after a refusal that marked the tx rollback-only?** Not misclassified. The refusal is thrown out of the outermost (only) transactional boundary. It matches `rollbackFor`, the proxy rolls back and rethrows the original checked exception, so the job sees `BusinessException`/`FacadeException`, not `UnexpectedRollbackException`. If the rollback itself fails, Spring throws `TransactionSystemException`, which lands in `failed` (correct). An `UnexpectedRollbackException` at commit would require someone to swallow a runtime exception inside, and nothing on the path does; it too would be `failed`.
- `catch (BusinessException | FacadeException)` before `catch (Exception)` compiles because the two are siblings under `Exception`.

So the split is sound for *transient* failures. The problem is the opposite direction, M-A.

## Issues

### [MEDIUM] M-A: a systemic refusal is now a silent success
File: `EmptyPalletCleanupJob.java` (`if (result.failed() > 0 && result.moved() == 0)`), `EmptyPalletCleanupJobService.java` (`catch (BusinessException | FacadeException e) { refused++;`)
Confidence: MEDIUM
Issue: the location constraint is per TYPE (`locationConstraintService.isUnitloadTypePermitted(destination.getTypeId(), unitload.getTypeId())`), not per pallet. If the EmptyPallets location's type gains a constraint that excludes Pallet (or Cart), then **every** candidate of that type gets `MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION`. Result: `candidates=500, moved=0, refused=500, failed=0`. The run records `tenantSuccess`, `last_success` advances, and the only signal is `items{outcome=refused}` plus 500 per-pallet WARNs. The "one poison pallet" framing in the javadoc and comment ("one pallet that a location constraint always rejects") does not match the mechanism: a constraint rejects a type, so the realistic cases are "all Carts" or "all Pallets". Round-1's original concern (a seed or location-type fault, finding A M-2) is exactly this class, and it is silent again. This round's own metrics are unscraped today (see memory: wms2 metrics exist but nothing scrapes them), so `items{refused}` has no reader.
Failure scenario: an admin adds a location-type constraint on EmptyPallets' type. The nightly job moves nothing from that night on, reports success, and `last_success` stays fresh.
Fix (pick one): (a) charge a tenant failure when `moved == 0 && refused > 0 && refused == candidates` (all refused, i.e. nothing could ever move) while keeping "some moved, some refused" and "single pallet refused among skips" as success; or (b) log one ERROR per run when `moved == 0 && refused >= N` and document in catalog §4.6a that all-refused is success. At minimum reword the javadoc: "a pallet or type that a constraint rejects", and note that all-refused withholds nothing.

### [LOW] L-1: Result javadoc claims for "refused" are partly unreachable or not deterministic
File: `EmptyPalletCleanupJobService.java`, `Result` javadoc ("a locked destination ({@code STORAGELOCATION_LOCKED}) … Retrying the same pallet tomorrow gives the same answer")
Confidence: HIGH
Issue: (a) `STORAGELOCATION_LOCKED` is thrown only under `!ignoreLock`; `relocateEmptiedContainer` passes `ignoreLock=true`, so it cannot occur on this path. (b) the "has stock"/"is carrier" backstop and `FacadeException("Unitload not found")` (`processTransfer`) fire on a concurrent commit, which is the opposite of "same answer tomorrow". (c) the list reads as enumeration and omits "Unitload not found". The classification outcome is still right (benign races counted as refused). Only the prose overclaims.
Fix: drop the locked-destination item, say "deterministic or race-driven business refusals", and state the rule (checked exception declared by `relocateEmptyStoragePallet`) instead of enumerating.

### [LOW] L-2: a race-driven refusal and a seed-level refusal share one bucket
File: same.
Confidence: LOW
Issue: concurrent-use refusals (L-1b) inflate `items{outcome=refused}` alongside real constraint refusals, so a dashboard on `refused` mixes noise with signal. They were deliberately routed to SKIPPED_STATE by the `disqualification` probe, so the window is small (between the probe and the move, under the unit-load row lock, stock insert is still possible).
Fix: none required; note in the catalog.

### [LOW] L-3: closed job counts survive in tests and one comment
File: `SchedulingConfigurationUnitTest.java:87` and `SchedulingReconcileIdempotencyUnitTest.java:119` ("The seven jobs {@code configureAllTasks} registers (seventh: emptyPalletCleanup…)"); `SchedulingConfiguration.java:341` ("the seventh added since"); catalog `:48` ("seven since SBDEV-1581").
Confidence: HIGH
Issue: the sweep (report row L-6) restated the main-source ones as rules but left these as current-state counts. The test javadocs sit beside `CONFIGURED_JOB_NAMES`-derived data and go stale with the next job. `:341` and `:48` are dated ("since SBDEV-1581"), so they are historical and acceptable.
Fix: reword the two test javadocs to "the jobs `configureAllTasks` registers (the newest: emptyPalletCleanup)".

### [LOW] L-4: seed IT no longer proves V2.2.41 specifically in test 1
File: `EmptyPalletCleanupSeedMigrationIT.seedsTheThreeRows`
Confidence: MEDIUM
Issue: migrating to head and counting the three keys proves the rows exist at head, not that V2.2.41 wrote them. If V2.2.41 were emptied and another migration seeded the same keys, test 1 stays green. What still ties it to V2.2.41: test 2 deletes MINUTE and executes the V2.2.41 file itself (so the file must reseed), and mutants R10 and R11 (value changed, INSERT removed) were reported red. The loss relative to the 2.2.39 watermark is the "absent before" non-vacuity check.
Fix (optional): add `select installed_rank … from flyway_schema_history where version='2.2.41'` plus a check that no other migration file mentions the three keys (`grep` on the classpath resources), or assert the seed file itself has all three `INSERT`s before running.

### [LOW] L-5: seed IT depends on out-of-order tolerance being on
File: `EmptyPalletCleanupSeedMigrationIT.migrateToHead` (`.outOfOrder(true)`)
Confidence: LOW
Issue: head is computed from the classpath alone, so with V2.2.40 present and V2.2.41 absent from history on a fresh DB, both apply in order and it is robust. It is robust to V2.2.40 existing. `outOfOrder(true)` is unnecessary on a fresh DB, but harmless and mirrors production (`app.flyway.out-of-order=true`). No action.

## (4) Changed comments: false or closed-set claims
- New javadoc "never count toward it" (deterministic refusals): true as coded, but see M-A, whose "one pallet" example is inaccurate for a type constraint.
- "Deterministic refusals … Retrying the same pallet tomorrow gives the same answer": L-1.
- Catalog §4.6a (`:389`) says refused is "deterministic, e.g. a location-type constraint". Same caveat as L-1, and it should state the all-refused case (M-A).
- The reconcile DEBUG wording and the "once per boot" gap statement are accurate.

## Positive observations
- The refused/failed split is made on a language-level rule (checked exceptions declared by the facade method) rather than a hand-kept list of message keys, which is the right invariant.
- `onlyRefusalsIsNotATenantFailure` and `refusalsPlusOneUnexpectedFailureIsATenantFailure` pin both edges, and the service test classifies Business/Facade versus optimistic-lock/EntityNotFound.
- The seed IT keeps a per-key shape assertion and the re-run case, and is now decoupled from other branches' sysprop inserts.
- IT (c)'s `rootCause` assertion makes the forced trigger's firing part of the proof.

## Recommendation
**APPROVE.** No CRITICAL or HIGH. Decide M-A (a one-line `refused == candidates` gate, or a catalog sentence) before activating the job on any tenant; fix the Lows in the same pass per project rule.
