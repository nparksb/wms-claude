# SBDEV-4107 — ralplan round 1 — ARCHITECT report

Lane: arch-4107 (opus), 2026-11-11, graded on `origin/develop` @ `df30fa62` plus 2 read-only WineCo PRD queries. Reviewed plan draft 1 independently (did not see the Critic).
Saved by the parent session (subagents cannot write report files here). Delivered in two messages.

## Part 1

**Steelman antithesis (lanes).** The EvalPlanQual (EPQ) problem only exists because the check and the lock are the SAME statement. Under READ COMMITTED, each new statement takes a new snapshot. So "lock the lane rows, then re-run the NOT EXISTS check as a SECOND statement" refuses the loser correctly, with no migration. The code already has the second query: `TransferOrderService` calls `getAvailableTransferLanesForUpdate(...)`, and the unlocked `getAvailableTransferLanes(customerOrderID, State.FINISHED)` is right next to it in `LocationRepository`.
- §2 and §10.10 reject "touch the lane row" on EPQ grounds (A§H), but nobody evaluated the two-statement form. It is the same lock-then-recheck pattern Fix B already uses for receipts.
- With it there is no SHARE lock on the 498k-row customerorder table at deploy on every tenant, no 23505 path, and no Java/DDL predicate coupling.
- This is not a reopening of §10. It is the strongest counter-case, and it feeds the synthesis below.

**Tradeoff tension.** The index is the only guard that holds against every writer, including future code, raw support SQL, and SDR if it is reopened. It costs a startup-time table lock on every tenant, a predicate frozen to 700/530 in DDL, and a hard 23505 on any re-entry path (T7). The lock-and-recheck form is cheap, but it is a convention.

**Synthesis (Low effort).** Keep the indexes as the guarantee.
- In T1/T2, also re-query availability after the locking query.
- In S1, take a lane-row lock (`LocationRepository.lockById` shape) before `getAvailableStagingLanes`.
- Then the refusal comes from the normal path, the 23505 catch is a backstop, and a tenant left at V2.2.50 (§8 row 1) still refuses correctly.

### [High] H1. §6.1 and §8 row 1 get `lock_timeout` wrong
§6.1 says "If it exceeds about 1.5 s, the 2 s lock_timeout makes it give up". It won't. `lock_timeout` bounds only the WAIT to acquire the lock, never the build. Once CREATE INDEX holds SHARE it runs to completion, and writers queued behind it fail with 55P03 at `wms.tenant.lock-timeout-ms=3000` (`application.properties`). `IndexMigrationLockTimeoutUnitTest`'s javadoc says the same: "must give up on its lock BEFORE the app's own tenant lock timeout".
- The real risk is a build longer than about 3 s, which fails live customerorder writers (release, picking, packing). It does not leave the tenant at V2.2.50.
- **Fix:** rewrite §6.1, §8 and the measurement gate as "customerorder build plus everything after it in the tx must be < 3 s".

### [Medium] M1. One transaction holds SHARE on customerorder for its whole length
V2.2.51 builds customerorder first, then waits up to 2 s for customerorder_batch, builds it, then waits up to 2 s for goodsreceipt and builds it. All that time customerorder writers are blocked: worst case `build_co + 2 s + build_b + 2 s + build_gr`, which is already over 3 s.
- **Fix:** build the customerorder index LAST, or split into three migrations, each its own transaction.

### [Medium] M2. The advice lock serializes whole receives
§8 says "operators … wait (ms)", which was not measured.
- **Measured** on WineCo PRD over the last 90 days: 711 pairs of GRPs on DIFFERENT positions of one receipt were created within 2 s of each other, so concurrent receives on one advice are real.
- A receive can be up to 35 cases, each with unitload creation, a location lock and a label. Any wait over 3 s ends in 55P03, which falls into `ReceivingController`'s `catch (RuntimeException e)` → LOG.error "Unexpected error during receive".
- Non-carrier receives already serialize on the shared put-away location lock (`UnitloadBusinessService` `LockReads.forUpdate(... Location ...)`), so the new cost lands mainly on the carrier path.
- **Fix:** catch `PessimisticLockingFailureException` in `ReceivingController` with a "another receive on this BOL is in progress, retry" message, and add a §8 row backed by the measurement.

### [Medium] M3. Fix C's native max+1 depends on auto-flush
Ids are SEQUENCE-generated (`AbstractBaseEntity` `GenerationType.SEQUENCE`), so position inserts stay pending until flush. `createAdviceWithPositions` numbers several positions in ONE transaction. Today's `findByAdviceId` is JPQL, which auto-flushes on its query space. A native query has no declared spaces; if it does not trigger a flush, every line gets `-000000`.
- **Fix:** add an IT for `createAdviceWithPositions` with 2 or more lines, OR keep JPQL `findByAdviceId` / `findByGoodsreceiptId` and take the max suffix in Java. That also keeps the existing H2 contexts working.

## Part 2

### [Medium] M4. The §7 test inventory is incomplete, and one gap is a compile break
A§G says numbering has "none (grep generateNumberWith* over src/test = 0)". That is false.
- `BasicServiceUnitTest` tests the `generateNumberWithGoodsReceipt` that Fix C deletes (compile error), and stubs `findByAdviceId` for `generateNumberWithAdvice`.
- `ReceivingServiceUnitTest` stubs `advicepositionRepository.findByIdForUpdate` (7×), `goodsreceiptRepository.findByAdviceId` (2×) and `countByGoodsreceiptId` (1×). Under the new code the unstubbed `adviceRepository.findByIdForUpdate` mock returns `Optional.empty()` and every receive case throws.
- `LockReads` falls back to the finder when the EntityManager is null, so finisher unit tests break the same way.
- **Fix:** list these in §7 and update them in step 1.

### [Medium] M5. Fix D misses code javadoc that Fix B makes false
`ReceivingService`'s finisher javadoc says "Concurrency — sibling-position locks after 'complete'; no advice-row lock". It also documents a "Deadlock on a shared put-away location" between two receives of one advice, and a "Lost finish" where two receives each miss the other's receipt. With the advice taken first, both are CLOSED, because receives of one advice now serialize.
- **Fix:** rewrite those bullets, and add a cheap IT that two last-position receives finish the advice. That is a free win the plan doesn't claim.

### Verification of 3a–3g
- **a. Confirmed.** `saveAndFlush` = merge + flush through the repository proxy, so the 23505 arrives inside the method as `DataIntegrityViolationException` (`DuplicateKeyException` is a subclass).
  - `@Version`: merge checks the detached version before the flush. For T1/T2/S1 the race is between DIFFERENT rows, so the loser sees DIVE, not OOLFE. Two requests on the SAME order still get OOLFE → 409, as today.
  - In the transfer race the loser waits on the location lock and then gets 23505 at once. Only S1 waits on the index entry. If the holder runs over 3 s, the loser gets 55P03 → 409, not the refusal (Low; one line in §8).
- **b. Confirmed** (PostgreSQL semantics, not measured). Predicate columns count as indexed for HOT, so an UPDATE that only moves `state` into the predicate is non-HOT, inserts an index tuple and runs the unique check: it waits on an uncommitted holder, then 23505 after commit, or proceeds if the holder aborts. The index is non-deferrable, so the check fires at the flush.
- **c. Safe.** The PG transaction is aborted, so nothing may touch the DB between catch and throw. The plan's LOG.warn reads only detached fields (`customerOrder.getNumber`, `transferLane.getId`). The entities have no lazy associations. `rollbackFor` includes `BusinessException`. The only callers (`TransfersController` ×3, `ClubLineController` ×2) are non-transactional, so there is no outer-tx rollback-only trap.
- **d. No cycle found.** Paths that lock or write positions/advice:
  - `AdviceService.close` / `acceptTransferAdvice` (advice → positions);
  - `markFinished` (`ReturnAdviceAutoReceiveService`, advice → positions);
  - `stampDamageApplied` (one position, no further lock);
  - GRP adjust/delete (SU → [finisher] advice → positions).
  - Receive never locks an existing SU, and sendToNirvana passes `ignoreLock=true` (no location lock), so SU→advice cannot meet advice→location. `acceptHubAndSpokeAdvice` locks nothing (`transferUnitLoadToCarrier` takes no lock).
- **e. Yes.** GRP inserts: only `receiveGoods`. AP inserts into an EXISTING advice: only `updateAdviceWithPositions`. `AdviceRestController` create/createTransfer/createHubAndSpoke, `FileImportController` and `createAdviceWithPositions` all insert into an advice created in the same request.
- **f. Predicates match:** `co.state < :state` with FINISHED = 700, `ob.state < :state` with 530; both columns Integer; NULL excluded on both sides.
  - One gap (Low L1): A§0.1 enumerated lane writers and bulk `@Modifying` only, not entity `setState` rewinds from ≥700 to <700 while the row keeps its lane. A spot check (`BillofladingService` → PACKED, `CustomerorderService` RAW/FUTURE sites, `UtilRestController`) found no live re-entry, but the census was not done.
  - IT 8 should build its expected predicate from `WmsConstants`, so a constant change turns it red.
- **g. Compatible.** The SET line matches the test's regex `^\s*SET LOCAL lock_timeout = '(\d+)s';`, the DO block has no index DDL, and SET comes before the first DROP/CREATE. A failed DO block rolls back with no history row, the same as 55P03 (README). IT seeds checked: `ClubRunJobItSupport.seedClub` uses a fresh lane per batch, and the 5 seed .sql files have 0 open-lane duplicates (parsed). Cross-test committed leftovers can only be caught by the full suite against the baseline (step 7).

### Low
- **L2.** Fix B's snippet `.orElseGet(() -> goodsreceiptRepository.save(newReceipt(...)))` won't compile: `basicService.generateNumber(...)` throws checked `BusinessException`. Use if/else.
- **L3.** §0 N1 and IT 6 name `GoodsReceiptPositionService.deletePosition`. It is private; the test must go through public `delete(position, principal)` or `adjust(..., 0)`.
- **L4.** The DO pre-check runs before the SHARE lock, so a duplicate created in that gap reaches CREATE UNIQUE INDEX as a raw 23505. That is acceptable, but say so in §8.

**VERDICT: SOUND-WITH-CHANGES** (H1, M1–M5 before the gate).

---

# ROUND 2 (draft 2), arch-4107, graded on origin/develop @ df30fa62

**(1) Round-1 findings:** all resolved in the text (H1 via 6.1/§8 and the 3 s gate; M1 customerorder built last; M2 controller arm plus the PRD measurement; M3 JPQL + Java max with IT 6b; M4 §7 unit list; M5 Fix B javadoc + IT 9; L2 if/else; L3 public delete; L4 §8 row).

**(2) The new parts are sound.**
- **A1 T1/T2 re-check is correct.** `getAvailableTransferLanes` is a separate JPQL statement, so under READ COMMITTED it takes a new snapshot, and its NOT EXISTS sees a holder that committed while we waited. The Location rows come back as instances the locking query already manages, and there is nothing pending to auto-flush.
- **A1 S1 `lockById` exists** (`@Lock(PESSIMISTIC_WRITE) SELECT l.id … exported = false`; precedent FixLocationAssignmentService).
- **Lock order lane L → own batch row: no cycle.**
  - The club run takes the batch row first (`findByIdForUpdate`). `validateStockOnStagingLane` only READS lane L and never locks it, and its moves lock DESTINATION locations, not the source lane. A club run in flight on the same batch makes S1 wait on the batch row and then fail with OOLFE 409, which is not a cycle.
  - `BillofladingService.transferOrder` writes its batch (`setStaginglaneId(null); save`) at flush, after its location locks, so it never waits on a location while holding a batch row.
  - Method: grep for the files that both lock locations and write customerorder_batch over src/main → BillofladingService only.
  - **New WAIT, not a cycle:** a move INTO lane L holds L until commit, so an assign of L waits behind it. Past 3 s → 55P03 → 409 (ClubLineController catches only BusinessException). One §8 row, Low.
- **Migration SQL is valid.** `string_agg` over an empty set returns NULL, so the IF is correct; two `%` placeholders and two args. SET LOCAL is the single matching line and comes before the first DDL, so IndexMigrationLockTimeoutUnitTest passes.
- **The ReceivingController arm compiles.** `PessimisticLockingFailureException` is not an OOLFE and sits before `catch (RuntimeException e)`. The advice lock is a query, so 55P03 is raised inside the method, not at commit.
- **JPQL numbers confirmed.** `createAdviceWithPositions` always creates its advice in the same transaction. Every inserter into an EXISTING advice or receipt is under the advice lock, and a receipt belongs to one advice.

**New findings**
- **[Medium] R2-M1. The S1 lane-row lock has no attributable kill.** In IT 3 the holder never locks L, so the refusal comes from the index. Delete `lockById` and IT 3 stays green, `blocked == true` included (the subject blocks on the index entry). **Fix:** add IT 3b, where the holder runs `lockById(L)` + the UPDATE and the WARN must be ABSENT (log capture).
- **[Medium] R2-M2. A1's re-check has the same problem in IT 1/2.** "Remove BOTH" is the only kill; remove just the re-check and the index still refuses. The unit test only proves the query is called, never the PostgreSQL new-snapshot behaviour. **Fix:** assert no WARN in IT 1/2, so removing the re-check alone goes red.
- **[Medium] R2-M3. IT 9 is free-running,** the shape §7's Traps ban; it is red on develop only if the timing lines up. **Fix:** force it with HeldRowLockRace. The holder runs `SELECT … FROM advice … FOR NO KEY UPDATE` and INSERTs the GRP completing position 1, uncommitted; the subject receives the last unit of position 2 (`allowUnblockedSubject`). Develop: no block, the advice ends OPEN (deterministic red). After the fix: blocked, then FINISHED.
- **[Low] R2-L1.** "Built last, so it is the only hold" is true only for customerorder. The SHARE locks on goodsreceipt and customerorder_batch stay held through customerorder's acquire wait (≤ 2 s) plus its build (< 1 s gate), so up to 3 s, right at the app timeout. Accept it in §8, or split the batch index into its own migration.
- **[Low] R2-L2.** The 55P03 arm also catches a put-away-location lock timeout and 40P01 (`CannotAcquireLockException`). Word the message without naming the advice as the cause: "Another operation is holding this receipt's data — retry."

**VERDICT: SOUND-WITH-CHANGES** (R2-M1..M3 are test changes only; the design is sound).
