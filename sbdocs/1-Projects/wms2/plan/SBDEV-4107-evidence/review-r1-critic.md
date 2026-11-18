# SBDEV-4107 — ralplan round 1 — CRITIC report

Lane: critic-4107 (opus), 2026-11-11, graded on `origin/develop` @ `df30fa62`. Reviewed plan draft 1 independently.
Saved by the parent session (subagents cannot write report files here). Delivered in two messages.

## Part 1

**Principles / alternatives:** Consistent. The DB index is the guarantee, the loser gets a refusal through saveAndFlush plus a catch that matches the constraint name, the lock order is advice→position, and the migration is a forward one. The rejected alternatives (touching the lane row, a unique index on goodsreceipt, auto-retry, CONCURRENTLY) are fairly stated and each is invalidated.

### HIGH
**H1. ITs 3, 4 and 7 cannot go red for the right reason with the named harness.** `HeldRowLockRace.run` hard-asserts "the subject's lock read must be observably BLOCKED BY THE HOLDER" and "belt and braces: the subject must not have completed either". `awaitSubjectBlockedBy` also stops early once `subjectFinished` fires. On develop the subject never blocks in any of the three:
- IT3: the availability query takes no lock.
- IT4: the FK's FOR KEY SHARE is compatible with the holder's FOR NO KEY UPDATE.
- IT7: `updateAdviceWithPositions` takes no lock (`ReceivingService` plain `findById`).

So each test goes red on the harness AssertionError, and the state assertions (2 batches, 2 receipts, duplicate AP number) never run. The "drop the lock → red" mutation fails the same way, so the red is not attributable to the assertion it is meant to protect. Plan §7's "subject never blocks; 2 receipts" describes an outcome the harness cannot express.
**Fix:** add a harness mode, e.g. `allowUnblockedSubject()`. In that mode, "the subject finished while the holder still held its lock" is recorded from the latch, with no timing. The holder then commits, and the test asserts the final state. Post-fix, assert `blocked == true` as a separate assertion. Also specify IT7's holder: raw SQL that locks the advice and inserts an AP, or a service call inside the holder's transaction.

### MEDIUM
**M1. IT5 is vacuous as written.** Its setup is "2 orders at 700 on lane A; `updateStateByIds([one], PACKED)`". PACKED = 650 (`WmsConstants`), so only one row enters `state < 700`. The other row stays at 700, outside the predicate, so the update can never raise 23505.
- Fix the setup: one order at 510 plus one at 700 on lane A, then move the 700 order.
- The plan also does not say whether this is the behaviour we want. The only caller is `finalizeClubLine` (`CustomerorderBatchService`), so a pinned 23505 fails the club-run job. Either record "fail-closed is intended" as a decision, or pin the real invariant instead (a club order never holds a transfer lane).

**M2. The migration risk is misstated.** §6.1 says "If it exceeds about 1.5 s, the 2 s lock_timeout makes it give up", and risk row 1 repeats it. That is wrong: `lock_timeout` bounds the wait to ACQUIRE the lock, not the build. `db/migration/README.md` on develop says so: "While the migration waits for its lock, the writers queued behind it fail at the app's timeout".
- Real risk 1: the SHARE lock on customerorder is held until commit, through all three CREATE INDEX statements. If that takes more than 3 s, app writers to customerorder fail with 55P03, which surfaces as 409.
- Real risk 2: the migration gives up only if a writer holds customerorder for more than 2 s.
- Fix: rewrite the row, measure the build against the 3 s app bound, and put the customerorder index LAST in the file so the hold is shortest.

**M3. The manual test plan cannot tell fixed from unfixed.** Firing "two assign calls in parallel (`&`)" gives a millisecond window. Both develop and the fix will normally show a sequential refusal, from the FOR UPDATE fast path or from the 4038 guards.
- Fix: use a psql holder. BEGIN; run the UPDATE with the lane, uncommitted; call the API; confirm `pg_blocking_pids`; COMMIT before the 3 s app lock_timeout (dev lock-race harness memory).
- "Seeding an out-of-band transfer lane" is not concrete. Say whether to INSERT a location (which NOT NULL columns) or flip `transferlane` on an existing location, and give the restore SQL.
- No endpoints or payloads are named. The two-position receive scenario has the same problem.

**M4. The migration's DO block is under-specified and untested.**
- The staging check exists only as the comment `-- same for customerorder_batch.staginglane_id, state < 530`.
- The RAISE text does not name the lanes, but risk row 5 claims "a readable message names the lanes".
- IT8 checks only `indexdef`, so a typo in the guard ships unseen.
- Fix: write out the full SQL, put `string_agg(lane ids)` in the message, and add an IT that runs the DO block against seeded duplicates and expects the raise.

## Part 2

### LOW
- **L1.** The CLAUDE.md item in Fix D is already done on develop. `CLAUDE.md` reads "The IT harness migrates `classpath:db/migration` — production's location (changed by SBDEV-3239)" and names `AppPostgresDBSetupExtension`. Drop the item; the premise of §10.9 is stale.
- **L2.** §2 says of the touch-the-lane-row alternative: "Race test 1 proves it". IT1 never exercises that alternative; it only proves today's lock fails. With an only-locked row EvalPlanQual is never triggered at all. Reword. The decision itself stands.
- **L3.** IT6 says "`deletePosition` the first", but `deletePosition` is private (`GoodsReceiptPositionService`). Go through `delete(position, principal)` instead; that path also runs the finisher.
- **L4.** A§G's claim "grep of generateNumberWith* over src/test = 0" is false. `FileImportControllerUnitTest` mocks `generateNumberWithAdvice` (5 sites). Keep the signature, or list the test updates.
- **L5.** Under Fix C, advice-position numbering inside a transactional loop (`createAdviceWithPositions`) depends on Hibernate auto-flushing before a native query. Add an assertion that a 3-line create numbers `-000000..-000002`.
- **L6.** Risk row 4 says "operators on one advice wait (ms)". A many-case receive takes seconds, and against the 3 s app lock_timeout the second operator gets a 409. Measured on WineCo PRD over 30 days: 241 receipts, 0 with two operators within 5 s, so it is acceptable. Put that evidence in the row in place of "(ms)".
- **L7.** The T7 re-entry census covers only bulk `@Modifying` writers; entity-level `setState` writers are not enumerated. Spot-check: `BillofladingService.transferOrder` sets PACKED but refuses `>= PACKED` first, so it is safe. State the method used.
- **L8.** `AdviceRepository.findByIdForUpdate` needs an explicit `@Query`; a derived name will not parse. Precedent: `AdvicepositionRepository`.
- **L9.** Step 7's mutation list is generic. Name a mutation for each IT (e.g. IT6: revert to count; IT8: alter the predicate).
- **L10.** Length: §3's diagram repeats §2, and several §9 checklist rows are boilerplate. Both can be cut.

### Spot-checks
- **Closed-set claims, all hold:** "updateStateByIds only caller" — one caller, `finalizeClubLine`. "generateNumberWithGoodsReceipt 0 callers" — only its definition matches. "Lane writers" — `TransferOrderService` ×2 and `CustomerorderBatchService` ×1 are the only non-null setters.
- **Citations, verbatim on develop:** `customerorderRepository.save(customerOrder);`, `customerorderBatchRepository.save(orderBatch);`, `goodsreceipts.get(0)`, `// TODO: WMS support team / select the correct one`, the grpCount line, `WHERE c.id IN :ids AND c.state != 800`, `advPositions.size()`, `adviceRepository.findById(advId)`, the a6b8d6b comment, "Do not use CONCURRENTLY here (SBDEV-4092)", `MIGRATION_LOCATION`, V2.2.50 as the highest version. Only L1 is stale.
- **AC mapping:**
  - Census: done.
  - Two-transaction IT per path: blocked by H1.
  - Mutation check: weak (H1, L9).
  - Refusal instead of 500: covered (T1, T2, S1 are `rollbackFor = BusinessException`; callers are controllers only).
  - Flyway check and suite against baseline: present.
  - Docs: present, minus L1.
- **Rollback story:** adequate (either deploy order is safe; the indexes can be dropped in a forward migration).

**VERDICT: ITERATE** (1 High, 4 Medium). This round needs fixes to H1, M1, M2 and M3. The design itself is sound.

---

# ROUND 2 (draft 2), critic-4107, graded on origin/develop @ df30fa62

**Round-1 findings, checked in the text (not only in §12):**
- **Resolved:** H1, M1, M2, M4, L1–L4, L6–L10.
- **Partly resolved:** M3 (the receive scenario still cannot tell fixed from unfixed; see M-b) and L5 (IT 6b's kill is doubtful; see L-c).
- **Confirmed on develop:** `lockById` (scalar, `exported = false`); the endpoints `/v3/transfers/assignTransferLane/{id}/{loc}`, `/v3/clubLine/assignStagingLane/{b}/{loc}` and `POST /v3/receiving/receive`; the existing `RuntimeException` catch in ReceivingController, which the new arm goes in front of.

## New: HIGH
**H-a. A1, the new primary refusal path, has no DB-level test that can fail because of A1 alone.**
- IT 1's kill is "remove BOTH re-check and index". Remove either one alone and IT 1 stays green, because the index catch returns the same message.
- IT 3's holder only UPDATEs the batch and never locks lane L, so S1's `lockById` and the re-check are never exercised. Its refusal always comes from the index.
- A1's only kill is a stubbed unit test, which cannot prove the fresh READ COMMITTED snapshot. That snapshot behaviour is the whole bug, and it is exactly how the "phase-3 lock fix" failed.
- Claims that rest on A1: 6.1 "With A1 it still refuses correctly", "A1 is correct without the index", and §10.12.
- **Fix:** make the refusal source assertable. Capture the "SBDEV-4107: … taken concurrently" WARN, or spy that `saveAndFlush` is never reached. IT 1 and 2 expect it absent; IT 1b expects it present. Add IT 3b: the holder runs `SELECT … FROM location WHERE id=:L FOR NO KEY UPDATE` plus the batch UPDATE, in default (blocked) mode, and expects a refusal with no WARN. Kill: remove the re-check → the WARN appears → red.

## New / residual: MEDIUM
- **M-a. IT 8b cannot be set up as written.** The IT database is migrated from `classpath:db/migration`, so the V2.2.51 indexes already exist and the seed fails with 23505 before the DO block runs. **Fix:** inside the rolled-back transaction, DROP both indexes first (PostgreSQL DDL is transactional), then seed and run the DO block.
- **M-b. The manual "two-position receive" scenario still cannot tell fixed from unfixed code.** The holder only runs `SELECT … FOR UPDATE` and inserts no receipt, so "exactly 1 goodsreceipt" holds on develop too. `FOR UPDATE` also conflicts with the FK's KEY SHARE, so the API call blocks on develop as well. **Fix:** mirror IT 4. Use `FOR NO KEY UPDATE`, have the holder INSERT a goodsreceipt for A, and expect 1 receipt. Develop gives 2, and the call does not block.
- **M-c. IT 9 is not deterministically red on develop** ("lost finish possible"; holder and harness mode unspecified). **Fix:** the holder runs the full `receiveGoods` of position 1 in its own transaction; use `allowUnblockedSubject`. On develop the subject's finisher sees position 1 as unreceived, returns early and commits, so the advice is left unfinished. That is a deterministic red.

## LOW
- **L-a.** The T7 census regex misses 510, ASSIGNED, PALLETIZED and LOADED_TO_TRUCK. Their hits are safe: TransferOrderService assign/activate are guarded, `assignTransferLane` has 0 callers, and ReleaseOrderJobService sets ASSIGNED during release. List them in §0 and state the full constant set.
- **L-b.** `allowUnblockedSubject` must FAIL if the subject neither blocks nor finishes within the probe window, rather than recording `blocked = false`.
- **L-c.** IT 6b's kill ("native query without flush") may not produce red: through JPA, Hibernate 6 native queries flush in AUTO mode. Use a `FlushModeType.COMMIT` hint as the mutation instead.
- **L-d.** IT 5 must name its entry point (`finalizeClubLine` or the repository) and state what the club-run job does after the 23505 (`failJob` → retry or poison), so §10.11 is fully described.
- **L-e.** Open question: S1 now locks location L before writing the batch row. Check that no club-run path holds a batch row and then locks the staging-lane location, which would form a location↔batch cycle.

**VERDICT: ITERATE** (1 High, 3 Medium). Every fix is small; the design and the decisions stand.

---

# ROUND 3 (draft 3), critic-4107: APPROVE

Every round-2 finding is resolved in the plan text, not only in its findings table. Checked against origin/develop.

- **H-a:** a ListAppender catches the WARN, which is logged only when the index refuses, so a test can tell which mechanism refused. Removing the re-check alone turns IT 1 red. IT 1b requires the WARN. IT 3 tests the index only. New IT 3b's kills are attributable: removing `lockById` fails the harness, and removing the re-check makes the WARN appear.
- **M-a:** IT 8b drops both unique indexes inside its rolled-back transaction before seeding, and covers both guards.
- **M-b:** in the manual receive scenario the holder takes `FOR NO KEY UPDATE` and inserts a receipt. Fixed: blocked, then 1 receipt. Develop: not blocked, 2 receipts.
- **M-c:** IT 9 is now forced: the advice ends OPEN on develop and FINISHED after the fix.
- **L-a:** the T7 scan covers every constant below 700.
- **L-b:** the harness fails if the subject neither blocks nor finishes in time.
- **L-c:** IT 6b's mutation is a `FlushModeType.COMMIT` hint.
- **L-d:** IT 5 goes through `finalizeClubLine`. Verified on develop: `ClubRunJobWorker` calls `failJob`, and `METRIC_FAILED = "wms2.clubrun.job.failed"`.
- **L-e:** answered by the Architect's lock-order check (§8 row).

Nit, not blocking: IT 3b goes red on develop through the harness assertion (the subject never blocks on L), not a state assertion. The plan says so, and that is the honest reason.
