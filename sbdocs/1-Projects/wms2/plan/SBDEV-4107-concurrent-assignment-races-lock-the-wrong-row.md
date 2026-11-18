---
title: "SBDEV-4107 — Concurrent assignment races lock the wrong row (transfer lane, staging lane, goods receipt, position numbers)"
ticket: "SBDEV-4107"
ticket_url: "https://app.clickup.com/t/868mv915q"
type: "bugfix"
priority: "normal"
status: "on dev — #665 fd712d7a"
project: [wms2]
version: "v2"
tier: T3
db_verified: true
requester: "Nam Park"
created: "2026-11-11"
updated: "2026-11-11"
branch: "feature/SBDEV-4107-concurrent-assignment-races"
related:
  - "[[261111-wms2-transaction-audit]]"
  - "[[wms2-transfer-order-workflow]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
  - "[[260424-CONCURRENCY_FIX_PLAN]]"
  - "[[SBDEV-4038]]"
tags: [plan, concurrency, flyway, receiving, transfer, club]
---
# SBDEV-4107 — Concurrent assignment races lock the wrong row

**Ticket:** [SBDEV-4107](https://app.clickup.com/t/868mv915q) · **Tier:** T3 (Flyway migration on every tenant) · **Base:** `origin/develop` @ `df30fa62`

**Evidence (cited as A§x):** `SBDEV-4107-evidence/analysis.md` (§0, §B–§D) and `analysis-part2.md` (§E–§I).
**Round-1 reviews:** `review-r1-architect.md` (SOUND-WITH-CHANGES) and `review-r1-critic.md` (ITERATE); §12 maps every finding to its fix.

## 0. Affected sites (enumeration; method per row in A§0)

| # | Site (`file` · quoted snippet) | Same root cause? | In scope |
|---|---|---|---|
| T1 | `TransferOrderService.assignTransferLaneToTransferOrder` · `customerorderRepository.save(customerOrder);` | yes: it locks `location` but writes `customerorder` | **yes** |
| T2 | `TransferOrderService.activateAndAssignTransferLane` · same `save` | yes | **yes** |
| T3–T5 | unlink, cancel, force-cancel, `finalizeBatchIfComplete` (all set the lane to null) | no: clearing a lane cannot violate the index | no |
| T6 | SDR PATCH `/v3/customerorder/{id}` | — | no: closed by `SDR_WRITE_WITHDRAWN` |
| T7 | rewinds from ≥700 to <700 on a row that keeps its lane | would re-enter the index predicate | **pin only** (IT 5) |
| S1 | `CustomerorderBatchService.assignStagingLaneToOrderBatch` · `customerorderBatchRepository.save(orderBatch);` (takes no lock at all) | yes | **yes** |
| S2/S3 | lane-clearing writers; `failJob` / `rollbackClubLineState` rewinds (state stays < 530) | no | no |
| G1 | `ReceivingService.receiveGoods` · `goodsreceipts.get(0)` and `// TODO: WMS support team / select the correct one` | yes: it locks the position, not the advice | **yes** |
| G2 | `ReceivingService.finishReturnAdviceIfComplete`: locks the sibling positions, then writes the advice | lock-order partner of G1 | **yes** |
| N1 | `BasicService.generateNumberWithGoodsReceiptByCount`, fed by `grpCount = (int) goodsreceiptpositionRepository.countByGoodsreceiptId(...)` | the count is reused after a position delete | **yes** |
| N2 | `BasicService.generateNumberWithAdvice` · `advPositions.size()`; its racing caller `updateAdviceWithPositions` reads with `adviceRepository.findById(advId)` (no lock) | count with no lock | **yes** |
| N3 | `BasicService.generateNumberWithGoodsReceipt` | — | **delete** (0 production callers; it is only tested in `BasicServiceUnitTest`) |
| — | siblings: order-number count, shipperid, unit load by label, mobile over-staging, the 3-commit club activate, `findEmpty*` | similar shape | no: each already has an owner (A§0.5) |

**How T7 was closed (two instruments).**
1. *Bulk `@Modifying`:* `updateStateByIds` (`WHERE c.id IN :ids AND c.state != 800`) has exactly one caller, the club-run finish (`updateStateByIds(orderIds, WmsConstants.State.PACKED)`). On WineCo PRD, 0 CLUB orders hold a transfer lane: the 668 orders holding one are 320 `TRANSFER_INTRACOMPANY` and 348 `TRANSFER_OFFSITE`.
2. *Entity `setState`:* I grepped `setState(` on customerorder for every sub-700 constant: RAW, FUTURE, RELEASED, ASSIGNED, CUSTOMER_ORDER_ACTIVATED, CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED (510), PICKED, PALLETIZED, PACKED and LOADED_TO_TRUCK. The second set (ASSIGNED, 510, PALLETIZED, LOADED_TO_TRUCK) was added after Critic round 2 (L-a). Every hit is guarded below 700:
   - `UtilRestController.resetOrdersInReleasedStatus`: `findByState(ASSIGNED)`, then `cancelOrder`, which clears the lane.
   - `CustomerorderService` picking-date change: `getState() < WmsConstants.State.RESERVED`.
   - `packageOrder`: `!= PICKED` throws.
   - `BillofladingService.transferOrder`: refuses `>= PACKED`.
   - `TransferOrderService` assign and activate (510): guarded by SBDEV-4038. The `assignTransferLane` overload has 0 callers.
   - `ReleaseOrderJobService` (ASSIGNED): runs at release, before any lane is held.
   - `setState(<variable>)` on customerorder: 0 hits.
   - *Blind spot:* a state written through a helper with a computed constant. The full suite plus IT 5 cover it.

## 1. Problem statement

Three "find a free one, then assign it" paths check availability and then write. Any lock they take is on a row the write never changes. Under PostgreSQL READ COMMITTED, a request that waited on that lock wakes up with its stale "free" answer and assigns the same resource:

1. two open transfer orders end up on one transfer lane;
2. two open club batches end up on one staging lane;
3. one advice gets two goods receipts, and later receives attach to an arbitrary one.

A fourth defect in the same family is **live**: goods-receipt-position numbers are issued by *count*, so a receive after a delete reuses a number that is still taken.

**DB verification (2026-11-11, read-only):**

| Query | Result | Reading |
|---|---|---|
| open-lane duplicates (`GROUP BY … HAVING count(*)>1`) on 4 PRD, 4 UAT and dev | **0 everywhere**. Controls: WineCo PRD 7 open transfer / 1 open staging, dev 6 / 9, UAT WineCo 2 / 0 | the bug is latent; the migration is safe on today's data |
| advices with more than one `goodsreceipt` | 1,623 WineCo, 413 c1wh-shipitez; newest 2025-02-26; each group created < 1 min apart | historical bulk import, not this race; it rules out a unique index |
| `(goodsreceipt_id, number)` duplicate groups | **160 on WineCo, 17 since 2026-09-01**, spaced 341 s to 5 days apart, 0 within 1 s | **live**; caused by delete-then-receive, not a race |
| `(advice_id, number)` duplicate groups | 0 | the AP race is latent |
| customerorder rows with a lane, by state (WineCo PRD) | 510: 7 · 700: 655 on 20 lanes · 800: 6 | finished transfers **keep** their lane, so the predicate must stop at 700 |
| GRP pairs on different positions of one receipt within 2 s (90 days) | 711 pairs on 79 receipts, **all from the same operator** (0 cross-operator), gaps ≥ 0.165 s | fast single-operator scanning, not two people on one advice. The two review lanes disagreed until this split resolved it. |

## 2. Root cause

### Bug 1: the transfer lane lock is on the wrong table
`LocationRepository.getAvailableTransferLanesForUpdate` is `@Lock(PESSIMISTIC_WRITE)` over `SELECT l FROM Location l WHERE l.transferlane = true AND NOT EXISTS (… co.transferlaneId = l.id …)`. The assignment then writes `customerorder.transferlane_id`; the `location` row never changes.

T2 waits on lane L's lock. When T1 commits, T2's statement continues on its original snapshot. EvalPlanQual only re-checks the locked row, and nothing on that row changed, so the `NOT EXISTS` result stands: L still looks free.

Two documents claim the opposite: the repository comment *"PESSIMISTIC_WRITE serializes concurrent lane assignment (SBDEV phase-3 lane-race fix, commit a6b8d6b)"* and `260424-CONCURRENCY_FIX_PLAN`. The audit's "touch the lane row" alternative is rejected on PostgreSQL semantics, not by a test (§10.10).

### Bug 2: the staging lane takes no lock at all
`assignStagingLaneToOrderBatch` runs `getAvailableStagingLanes(orderBatch.getId())`, which is unlocked, and then `setStaginglaneId`.

### Bug 3: goods receipt find-or-create runs under the position lock
`receiveGoods` locks the position with `advicepositionRepository.findByIdForUpdate(advicePositionId)` and then calls `findByAdviceId(advice.getId())`. Two receives on **different** positions of one new advice hold different locks, so both see no receipt and both create one. PESSIMISTIC_WRITE is `FOR NO KEY UPDATE`, which does not conflict with the foreign key's `FOR KEY SHARE` on the advice row (A§D). And `findByAdviceId` has no ORDER BY, so `get(0)` returns an arbitrary receipt.

### Bug 4: position numbers come from a count
GRP numbers come from `countByGoodsreceiptId`. After `GoodsReceiptPositionService.delete(position, principal)`, the count drops and the next receive reissues a live number (the 160 duplicates). AP numbers come from `advPositions.size()`, and `updateAdviceWithPositions` takes no lock, so two concurrent adds can collide. The format is `<parent#>-%06d`, zero-based, and no Java code parses it (A§E).

## 3. Lock order after the fix

- **Receiving:** advice → position → put-away location → (RETURN advices only) sibling positions. This matches `AdviceService.close`, `acceptTransferAdvice` and `markFinished`, which all go advice → positions.
- **GRP adjust/delete:** SU → advice → positions, through the finisher.
- **Architect check (review §3d):** found no path on develop that locks a position, receipt, GRP or stock unit before the advice in a way that could form a cycle with these.

## 4. Fix design

### Fix A: lanes, lock-then-recheck plus a partial unique index as the backstop

**A1, the code path (Architect synthesis).** Under READ COMMITTED, each new statement takes a fresh snapshot. So the availability check is re-run as a **second statement after the lock is held**:

```java
// T1 and T2, after the existing getAvailableTransferLanesForUpdate(...) call (kept: it serializes and gives the fast refusal)
if (locationRepository.getAvailableTransferLanes(customerOrder.getId(), WmsConstants.State.FINISHED)
        .stream().noneMatch(lane -> lane.getId().equals(transferLane.getId()))) {
    throw new BusinessException("transfer lane is not available anymore. refresh and try again.");
}

// S1: lock the target lane row first, then run the existing (unlocked) availability query
locationRepository.lockById(stagingLane.getId());   // exists on develop: @Lock(PESSIMISTIC_WRITE) "SELECT l.id FROM Location l WHERE l.id = :id", exported = false
List<Location> availableStagingLanes = getAvailableStagingLanes(orderBatch.getId());
```

With A1, the race loser is refused on the normal path, and a tenant left at V2.2.50 by a failed migration still refuses correctly.

**A2, the guarantee: V2.2.51 adds partial unique indexes**, so the rule also holds against any future writer, support SQL, or an SDR route that gets reopened. In `TransferOrderService` (T1, T2) and `CustomerorderBatchService` (S1), `save` becomes `saveAndFlush`, and a unique violation on the named index is mapped to the **same** refusal message:

```java
try {
    customerorderRepository.saveAndFlush(customerOrder);
} catch (DataIntegrityViolationException e) {
    if (!UniqueViolations.isConstraint(e, OPEN_TRANSFERLANE_INDEX)) throw e;   // any other violation is rethrown unchanged
    LOG.warn("SBDEV-4107: transfer lane {} taken concurrently for order {}", transferLane.getId(), customerOrder.getNumber());
    throw new BusinessException("transfer lane is not available anymore. refresh and try again.");
}
```

- **Placement:** both changes go after SBDEV-4038's state guards, whose messages stay unchanged.
- **Why `saveAndFlush`:** without it, the violation fires in `doCommit`, after the method has returned. It then escapes the controllers' `catch (BusinessException)` and becomes a 500, because `RestExceptionHandler` has no handler for `DataIntegrityViolationException` (A§B).
- **Precedent:** `FixLocationAssignmentService.detach` (SBDEV-4044).
- **Safe to catch:** the Architect checked (review §3c) that the catch block reads only detached fields, that the callers are non-transactional controllers, and that `rollbackFor = BusinessException` applies.
- **Constraint matching:** `UniqueViolations.isConstraint` follows the cause chain to `ConstraintViolationException.getConstraintName()`. Reuse `ReplenishGeneratorService.isActiveDupViolation` if it can be lifted out; otherwise add one small helper.
- **The same-order race is unchanged:** two requests for the same order still get `ObjectOptimisticLockingFailureException`, which returns 409.
- **Holder longer than 3 s:** if the transaction already holding the lane runs longer than 3 s, the waiting request gets `55P03`, which returns 409 instead of the refusal. That is acceptable (§8).

**Migration `V2.2.51__open_lane_unique_and_goodsreceipt_advice_index.sql`.** One transaction, with the `customerorder` index built **last** so the SHARE lock on that hot table is held only for its own build:

```sql
SET LOCAL lock_timeout = '2s';
DO $$
DECLARE tl text; sl text;
BEGIN
  SELECT string_agg(DISTINCT transferlane_id::text, ',') INTO tl FROM (
    SELECT transferlane_id FROM customerorder WHERE transferlane_id IS NOT NULL AND state < 700
    GROUP BY transferlane_id HAVING count(*) > 1) d;
  SELECT string_agg(DISTINCT staginglane_id::text, ',') INTO sl FROM (
    SELECT staginglane_id FROM customerorder_batch WHERE staginglane_id IS NOT NULL AND state < 530 AND type = 'CLUB'
    GROUP BY staginglane_id HAVING count(*) > 1) d;
  IF tl IS NOT NULL OR sl IS NOT NULL THEN
    RAISE EXCEPTION 'SBDEV-4107: open lanes held twice — transfer lane ids [%], staging lane ids [%]; resolve before migrating',
      coalesce(tl, ''), coalesce(sl, '');
  END IF;
END $$;
DROP INDEX IF EXISTS public.idx_goodsreceipt_advice_id;
CREATE INDEX idx_goodsreceipt_advice_id ON public.goodsreceipt (advice_id);
DROP INDEX IF EXISTS public.uq_customerorder_batch_open_staginglane;
CREATE UNIQUE INDEX uq_customerorder_batch_open_staginglane ON public.customerorder_batch (staginglane_id)
  WHERE staginglane_id IS NOT NULL AND state < 530 AND type = 'CLUB';   -- narrowed by decision 14
DROP INDEX IF EXISTS public.uq_customerorder_open_transferlane;
CREATE UNIQUE INDEX uq_customerorder_open_transferlane ON public.customerorder (transferlane_id)
  WHERE transferlane_id IS NOT NULL AND state < 700;
```

- **Predicates mirror the availability queries.** Transfer: `co.state < :state` with `FINISHED` = 700. Staging: `ob.state < :state` with `ORDER_BATCH_CLUB_RUN_FINISHED` = 530. A row with a NULL state drops out of both the query and the index.
- **Build style:** plain transactional, the same shape as V2.2.49. **Not** `CONCURRENTLY`, because `db/migration/README.md` ("Do not use CONCURRENTLY here (SBDEV-4092)") records it hanging under `StartupFlywayMigrator`.
- **What `lock_timeout` covers:** `SET LOCAL lock_timeout = '2s'` bounds only the wait to **acquire** each lock. That is what `IndexMigrationLockTimeoutUnitTest` enforces: below the app's 3 s. **It does not bound the build** (§6.1).
- **Gap in the pre-check:** it runs before any SHARE lock is taken, so a duplicate created in between reaches `CREATE UNIQUE INDEX` as a raw 23505. The transaction rolls back and the tenant retries on its next boot, which is acceptable.

### Fix B: goods receipt, lock the advice first and reuse the oldest receipt

```java
// receiveGoods, before the existing position lock
Long adviceId = advicepositionRepository.findAdviceIdById(advicePositionId)      // scalar JPQL, loads no entity
        .orElseThrow(() -> new BusinessException("entityNotFoundForId", Adviceposition.class.getSimpleName(), advicePositionId));
adviceRepository.findByIdForUpdate(adviceId)
        .orElseThrow(() -> new BusinessException("entityNotFoundForId", Advice.class.getSimpleName(), adviceId));
Adviceposition adviceposition = advicepositionRepository.findByIdForUpdate(advicePositionId)…;   // unchanged
…
Optional<Goodsreceipt> existing = goodsreceiptRepository.findFirstByAdviceIdOrderByIdAsc(advice.getId());
Goodsreceipt goodsreceipt;
if (existing.isPresent()) {
    goodsreceipt = existing.get();
} else {                                   // if/else, not orElseGet: generateNumber throws a checked BusinessException
    … unchanged creation block …
}
```

- **`AdviceRepository.findByIdForUpdate`:** `@Lock(PESSIMISTIC_WRITE)` with an **explicit `@Query("SELECT a FROM Advice a WHERE a.id = :id")`** (the `AdvicepositionRepository` precedent) and **`@RestResource(exported = false)`**, because the repository is SDR-exported (SBDEV-3169).
- **`finishReturnAdviceIfComplete`:** before its sibling-position loop, lock the advice with `LockReads.forUpdate(entityManager, Advice.class, advice.getId(), adviceRepository::findByIdForUpdate)`. When called from a receive this is a no-op, because the lock is already held. It also avoids the SBDEV-3286 stale-read trap.
- **`updateAdviceWithPositions`:** `findById(advId)` becomes `findByIdForUpdate(advId)`.
- **`ReceivingController /receive`:** add a `catch (PessimisticLockingFailureException e)` arm before the existing `catch (RuntimeException e)`. It returns "Another operation is holding this receipt's data — retry." in place of the generic error. The message does not name the advice as the cause, because the arm also catches a put-away-location lock timeout and 40P01 (Architect round 2, L2). Receives on one advice now serialize, so a receive longer than 3 s will make a second one hit 55P03.
- **Javadoc:** rewrite the finisher's "Concurrency" bullets (*"no advice-row lock"*, *"Deadlock on a shared put-away location"*, *"Lost finish"*). With the advice locked first, receives on one advice serialize, which **closes** the lost-finish and shared-location deadlock cases. IT 9 claims and proves this.

### Fix C: number positions by max + 1 over the live suffix, under the advice lock

```java
// BasicService — signatures kept (FileImportControllerUnitTest mocks generateNumberWithAdvice)
public String generateNumberWithAdvice(Advice advice) {
    return format(advice.getNumber(), nextSuffix(advicepositionRepository.findNumbersByAdviceId(advice.getId())));
}
// receiveGoods: draw the first suffix once, then ++ inside the loop as today
int next = nextSuffix(goodsreceiptpositionRepository.findNumbersByGoodsreceiptId(goodsreceipt.getId()));
static int nextSuffix(List<String> numbers) { /* max of the trailing [0-9]+ suffix, or -1 when there are none, plus 1 */ }
```

- **JPQL, not native SQL (Architect M3):** a JPQL `select p.number …` auto-flushes pending inserts in its query space, so `createAdviceWithPositions` still numbers lines `-000000, -000001, …` inside one transaction. A native query might not flush, and it would also break the H2 test contexts.
- **Unchanged output:** max + 1 equals today's count whenever nothing was deleted.
- **Accepted (Nam):** after the top-numbered position is deleted, its number is issued again. Live rows never share a number.
- **No backfill:** existing duplicates are not renumbered, and no unique index is added on numbers.
- **Concurrency:** Fix B's advice lock serializes every position insert for an **existing** advice. A§E and review §3e confirm the only such inserters are `receiveGoods` and `updateAdviceWithPositions`.
- **Removed:** `generateNumberWithGoodsReceiptByCount` (replaced) and the dead `generateNumberWithGoodsReceipt`, along with its test.

### Fix D: docs

- **`LocationRepository` comment:** "serializes acquisition only; the refusal is the post-lock re-check, and the guarantee is `uq_customerorder_open_transferlane` (SBDEV-4107)".
- **`wms2-transfer-order-workflow.md`:** update the §4 `activateAndAssignTransferLane` row, and rewrite landmine 13 as fixed.
- **`wms2-transaction-osiv-boundary-map.md`:** add a receiving lock-order entry (§3 of this plan).
- **`db/migration/README.md`:** add the V2.2.51 row.

## 5. File change summary

| File | Change |
|---|---|
| `db/migration/V2.2.51__open_lane_unique_and_goodsreceipt_advice_index.sql` | new migration (Fix A) |
| `service/TransferOrderService.java` | T1/T2: post-lock re-check; `saveAndFlush` + named-constraint catch |
| `service/CustomerorderBatchService.java` | S1: lane-row lock, then the availability query; `saveAndFlush` + catch |
| `service/ReceivingService.java` | lock the advice first (`receiveGoods`, `updateAdviceWithPositions`, finisher); reuse the oldest receipt; max + 1 draw; javadoc |
| `controller/ReceivingController.java` | `PessimisticLockingFailureException` arm |
| `service/BasicService.java` | `nextSuffix`; remove the two count-based GRP methods |
| `repo/jpa/CustomerorderRepository.java`, `repo/jpa/CustomerorderBatchRepository.java` | declare `<S extends …> S saveAndFlush(S entity);`. Neither repository is a `JpaRepository` (both extend only `PagingAndSortingRepository` + `CrudRepository`). Precedent: `ItemdataRepository` (SBDEV-2624). Found by the TDD gate, 2026-11-11 |
| `repo/jpa/AdviceRepository.java` | `findByIdForUpdate` (`@Lock`, `@Query`, `exported = false`) |
| `repo/jpa/AdvicepositionRepository.java` | `findAdviceIdById`, `findNumbersByAdviceId` (both `exported = false`) |
| `repo/jpa/GoodsreceiptRepository.java` | `findFirstByAdviceIdOrderByIdAsc` |
| `repo/jpa/GoodsreceiptpositionRepository.java` | `findNumbersByGoodsreceiptId` (`exported = false`) |
| `repo/jpa/LocationRepository.java` | comment only (`lockById` already exists) |
| `util/UniqueViolations.java` (only if it can't be lifted from `ReplenishGeneratorService`) | constraint-name match |
| `src/test/.../common/fixtures/HeldRowLockRace.java` | `allowUnblockedSubject()` mode (§7) |
| tests, docs | §7, Fix D |

## 6. Implementation steps

### 6.1 Prerequisites

| Item | State |
|---|---|
| DB state | Duplicate census = 0 on 4 PRD, 4 UAT and dev (2026-11-11). The migration's DO block re-checks when it is applied. |
| **Build-time gate** | **Before deploy**, time `CREATE UNIQUE INDEX … customerorder … WHERE …` on a PRD-sized copy (the SBDEV-4092 method). Once the build holds its SHARE lock, every `customerorder` writer (release, picking, packing, transfer) waits. Any writer waiting over **3 s** (`wms.tenant.lock-timeout-ms=3000`) fails with 55P03 / 409. `lock_timeout` does **not** stop a long build. **Pass: under 1 s** (estimated from V2.2.49's 2.5 s for 1.54M rows / 1.5 GB; WineCo `customerorder` is 498,709 rows / 196 MB). If it comes in at 1–3 s, deploy at a quiet hour. Over 3 s needs a redesign. The customerorder index is built last, so this build is the only time the lock is held. |
| Lock-acquire failure | If a writer holds `customerorder` for more than 2 s at boot, the migration gives up and rolls back (no history row is written). That tenant stays at V2.2.50, retries on its next boot, and shows on `wms2.flyway.tenant.stale`. With A1 it still refuses correctly in the meantime. |
| Flyway collision | V2.2.51 is free today (0 open PRs, 80 refs checked, no worktree claims it). Re-check at the `wms-merge` preflight. |
| Deploy order | Either order is safe: A1 is correct without the index, and the index is correct without the code. |
| Flags, sysprops, OMS, UI | N/A. The messages are unchanged and there are no new toggles. |
| Lease | `ticket-lease.sh claim SBDEV-4107` is held. |

### 6.2 Steps (one commit each)

1. **`wms-tdd-gate`:** add the harness mode, the §7 ITs, and the unit-test updates. Confirm each new test is red for the reason stated.
2. V2.2.51 plus ITs 8 and 8b → green.
3. Fix A (A1 + A2) → ITs 1, 1b, 2, 3 and 3b green; unit tests green.
4. Fix B → ITs 4 and 9 green.
5. Fix C → ITs 6, 6b and 7 green.
6. Fix D docs.
7. Per-IT mutation (§7 *Kill* column), PIT on the touched services, then the full suite against the baseline.

## 7. Testing plan

**Harness change.** `HeldRowLockRace.run` hard-asserts that the subject is *"observably BLOCKED BY THE HOLDER"*, so a subject that never blocks fails on the harness before any state assertion runs (Critic H1).
- **New mode `allowUnblockedSubject()`:** if `subjectFinished` fires while the holder still holds its transaction (seen from the latch, not from a timer), record `blocked = false`. The holder then commits, and the test asserts the final state. If the subject has **neither** blocked on the holder **nor** finished within the harness's existing await bound, the run **fails**; it does not record `blocked = false` (Critic round 2, L-b).
- **Refusal-source capture:** the race ITs attach a Logback `ListAppender` to `TransferOrderService` / `CustomerorderBatchService` and assert whether the `"SBDEV-4107: … taken concurrently"` WARN was logged. That WARN is logged only on the index-catch path. If it is absent, the re-check refused (A1). If it is present, the index refused (A2). This is what makes each mechanism's kill attributable (both reviewers, round 2).
- **After the fix,** each such test asserts `blocked == true` as a **separate** assertion.
- **Existing callers are unaffected:** the default mode keeps the hard assert.

**ITs** (Testcontainers; `HeldRowLockRace`, the subject running on its own thread with `TenantContext` set inside that thread):

| # | Test · holder (uncommitted) → subject | Red on develop because | Green after | Kill (mutation → red, with the named message) |
|---|---|---|---|---|
| 1 | `TransferLaneRaceIT.assignWaitingOnTheSameLaneIsRefusedByTheRecheck` · `SELECT … FROM location WHERE id=:A FOR NO KEY UPDATE`; `UPDATE customerorder SET transferlane_id=:A, state=510 WHERE id=:X` → `assignTransferLaneToTransferOrder(A, Y)` | 2 open orders on A | `blocked == true`; refusal message; 1 open order on A; **no** "taken concurrently" WARN (A1 refused) | remove the re-check **alone** → the WARN appears ("expected the re-check, not the index, to refuse") |
| 1b | `…indexBacksUpAWriterThatSkipsTheLaneLock` · the `UPDATE` only, **no** location lock → same subject (`allowUnblockedSubject`) | 2 open orders on A | subject blocks on the index entry, then the refusal; the WARN **is** present (A2 refused) | drop the index → "2 open orders on lane A"; remove the catch → `DataIntegrityViolationException` escapes |
| 2 | 1 + 1b for `activateAndAssignTransferLane` | same | same | same |
| 3 | `StagingLaneRaceIT.indexBacksUpAWriterThatSkipsTheLaneLock` · `UPDATE customerorder_batch SET staginglane_id=:L, state=525 WHERE id=:B1` → assign L to B2 (`allowUnblockedSubject`) | the subject never blocks; 2 batches on L | `blocked == true` (on the index entry); refusal; 1 batch on L; the WARN **is** present | drop the index → "2 batches on L" |
| 3b | `StagingLaneRaceIT.assignWaitingOnTheSameLaneIsRefusedByTheRecheck` · `SELECT … FROM location WHERE id=:L FOR NO KEY UPDATE` + the same batch `UPDATE` → assign L to B2 (default mode) | the harness fails: on develop the subject never blocks on L | `blocked == true` (on L); refusal; **no** WARN | remove `lockById` → the subject does not block on L → the harness fails "not BLOCKED BY THE HOLDER"; remove the re-check → the WARN appears |
| 4 | `GoodsReceiptAdviceLockRaceIT` · `SELECT … FROM advice WHERE id=:A FOR NO KEY UPDATE`; `INSERT INTO goodsreceipt(advice_id=:A …)` → `receiveGoods` on a **different** position of A (`allowUnblockedSubject`) | the subject never blocks; 2 receipts | `blocked == true`; 1 receipt | remove the advice lock → "2 receipts for advice A" |
| 5 | `TransferLanePredicateReentryIT` · order X at 510 and order Z at 700, both on lane A → `CustomerorderBatchService.finalizeClubLine(batchOf(Z), [Z])`, which calls `updateStateByIds([Z], PACKED)` | — (pins today's behaviour) | a `DataIntegrityViolationException` naming `uq_customerorder_open_transferlane` propagates out of `finalizeClubLine`; it is **not swallowed**. In production `ClubRunJobWorker` then calls `failJob`: the whole run rolls back, the job is marked FAILED with `last_error`, and `wms2.clubrun.job.failed` is incremented | change the predicate to `state < 600` → no exception → red. **Fail-closed is intended** (§10.11). |
| 6 | `GoodsReceiptPositionNumberingIT.numberAfterDeleteIsNotReused` · receive 2 → `GoodsReceiptPositionService.delete(firstPosition, principal)` (public) → receive 1 | duplicate `…-000001` | distinct numbers | revert to the count → "duplicate GRP number …-000001" |
| 6b | `AdviceNumberingIT.createNumbersThreeLinesInOrder` · `createAdviceWithPositions` with 3 lines | — (guards the auto-flush) | `-000000..-000002` | add a `FlushModeType.COMMIT` hint to `findNumbersByAdviceId` → "-000000 ×3" (Critic round 2, L-c: a native query would still flush in AUTO mode, so it is not the mutation) |
| 7 | `AdvicePositionNumberingRaceIT` · the holder calls `updateAdviceWithPositions(A, …)` inside its own transaction (uncommitted) → the subject calls the same (`allowUnblockedSubject`) | duplicate AP number | `blocked == true`; distinct numbers | remove the lock in `updateAdviceWithPositions` → "duplicate AP number" |
| 8 | `OpenLaneUniqueIndexMigrationIT.indexesHaveTheQueryPredicates` · `pg_indexes.indexdef` | indexes missing | the expected predicates, **built from `WmsConstants.State.FINISHED` / `ORDER_BATCH_CLUB_RUN_FINISHED`** | change a constant or the predicate → "predicate mismatch" |
| 8b | `…duplicateGuardNamesTheLanes` · in one rolled-back transaction: `DROP INDEX` both unique indexes (PostgreSQL DDL is transactional; the IT database already has V2.2.51, so seeding first would hit 23505), seed two open orders on lane A, then run the V2.2.51 DO block read from the file. Repeat for staging | n/a | raises with `transfer lane ids [A]` / `staging lane ids [L]` | break the guard → "no exception" |
| 9 | `ReturnAdviceFinishRaceIT.lastTwoReceivesFinishTheAdvice` · RETURN advice A with 2 positions. Holder: `SELECT … FROM advice WHERE id=:A FOR NO KEY UPDATE`, then INSERT the GRP that completes position 1 (uncommitted). Subject: `receiveGoods` for the last unit of position 2 (`allowUnblockedSubject`) | the subject does not block; its finisher misses the uncommitted GRP; the advice ends OPEN (deterministic) | `blocked == true`; after the holder commits, the advice is FINISHED | remove the advice lock → "advice A still OPEN" |

**Unit-test updates in step 1** (Architect M4, Critic L4):
- **`TransferOrderServiceUnitTest`, `CustomerorderBatchServiceUnitTest`:** `save` becomes `saveAndFlush`. Stub the re-check query and `lockById`. New cases: a named violation becomes `BusinessException`; an unnamed one is rethrown; a stale re-check refuses **without** calling `saveAndFlush`. That last case is the attributable kill for A1.
- **`ReceivingServiceUnitTest`:** stub `adviceRepository.findByIdForUpdate` and `findAdviceIdById`, which otherwise return an empty Optional and make every receive case throw. `findByAdviceId` becomes `findFirstByAdviceIdOrderByIdAsc`, and the `countByGoodsreceiptId` stub becomes `findNumbersByGoodsreceiptId`. Finisher cases also stub the advice lock (`LockReads` falls back to the finder when the EntityManager is null).
- **`BasicServiceUnitTest`:** delete the `generateNumberWithGoodsReceipt` test, re-point the `generateNumberWithAdvice` stubs, and add `nextSuffix` cases (empty list → 0, a gap, non-numeric).
- **`FileImportControllerUnitTest`:** unchanged, because the signature is kept.
- **`IndexMigrationLockTimeoutUnitTest`:** picks up V2.2.51 automatically.

**Traps:** set `TenantContext` inside the worker thread (SBDEV-3491). NOT_SUPPORTED fixtures commit, so delete them in `@AfterEach`, children first. Assert both the exception class **and** its message. Do not copy the free-running shape of `ReplenishDupConcurrencySliceIT`.

**Manual test plan** (DEV `dev_wh01_om1` via `wms-dev-probe`: take a `snapshot.sh` before and prove the restore after). Every race uses a **psql holder** (the dev lock-race harness):
1. `BEGIN;` and the holder write, left uncommitted.
2. Fire the API call in the background.
3. Confirm `pg_blocking_pids(<api pid>)` contains the holder's pid.
4. `COMMIT` within 3 s.

A plain `&` pair cannot tell fixed from unfixed code (Critic M3).

| Scenario | Precondition query → dev count | Steps | Expected | P/F |
|---|---|---|---|---|
| Transfer-lane race | unassigned transfer orders (`state < 505`, no lane) → **3**; free transfer lanes → **0** | Free a lane: `UPDATE location SET transferlane = true WHERE id = :L` on an empty location with no stock and no FLA (record `:L`; restore with `= false`). Holder: `UPDATE customerorder SET transferlane_id=:L, state=510 WHERE id=:X` → `GET /v3/transfers/assignTransferLane/{Y}/{L}` | blocked, then the refusal ("transfer lane is not available anymore…"); 1 open order on L | |
| Staging-lane race | CLUB batches `< 525` with no lane → **14**; free staging lanes → **12** | Holder: `UPDATE customerorder_batch SET staginglane_id=:L, state=525 WHERE id=:B1` → `GET /v3/clubLine/assignStagingLane/{B2}/{L}` | blocked, then the refusal | |
| Two-position receive | OPEN advices with ≥ 2 OPEN positions and no receipt → **3** | Holder: `SELECT … FROM advice WHERE id=:A FOR NO KEY UPDATE`, then `INSERT INTO goodsreceipt (…, advice_id) VALUES (…, :A)` (uncommitted; mirrors IT 4) → `POST /v3/receiving/receive` (position 2 of A) | fixed: blocked until COMMIT, then exactly **1** `goodsreceipt` for A. Develop: not blocked, **2** receipts. That difference is what tells fixed from unfixed (Critic round 2, M-b) | |
| Delete then receive | a receipt with ≥ 2 positions | receive → delete the first position → receive | distinct numbers | |

## 8. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| The customerorder build runs for seconds on a large tenant | writers to `customerorder` fail with 55P03 / 409 while it runs | measured gate in 6.1 (< 1 s); built last, so it is the only hold; deploy off-peak |
| A writer holds `customerorder` for > 2 s at boot | the migration gives up; the tenant stays at V2.2.50 and retries | the stale gauge flags it; A1 keeps refusing correctly |
| A rewind from ≥700 to <700 on a row that keeps its lane | 23505 fails the club-run job | not live (two instruments in §0); IT 5 pins fail-closed (§10.11) |
| Receives on one advice now serialize | a second receive on the same advice waits; past 3 s it gets 55P03 | measured on WineCo PRD: 0 cross-operator pairs within 2 s over 90 days (711 pairs, all one operator), and 0 two-operator receipts within 5 s over 30 days (Critic); the controller arm gives a clear retry message |
| The advice lock adds a deadlock edge | 40P01 | advice first everywhere (§3); the Architect found no cycle |
| The holder runs > 3 s in a lane race | the loser gets 55P03 / 409 instead of the refusal | acceptable: the result is still correct, only the message differs |
| A duplicate appears between the DO check and CREATE | a raw 23505; the tenant stays at V2.2.50 | the rollback is clean and the next boot retries |
| SHARE locks on `goodsreceipt` and `customerorder_batch` stay held while the customerorder lock is acquired (≤ 2 s) and built (< 1 s gate) | club-run and receive writers wait up to about 3 s during the migration | accepted: one-off at boot, off-peak; past 3 s they get 409 and retry (Architect round 2, L1) |
| A stock move INTO staging lane L holds L until commit | an assign of L waits behind it; past 3 s, 55P03 → 409 (ClubLineController catches only `BusinessException`) | accepted: a wait, not a cycle. The Architect found no location↔batch cycle (round 2): the club run locks the batch first and only reads L, and BOL writes its batch after its location locks |

## 9. Checklists

**Horizontal scalability:** in-JVM state No · pool math No · scheduled jobs No · long transactions No (row locks only for the existing transaction) · request affinity No · **retry/idempotency Yes** (a replay is refused by the DB index on every replica) · tenant context No · **distributed lock correctness Yes** (index plus row locks inside the tenant transaction manager; app `lock_timeout` 3 s) · cache No · notifications No.

**v2 constraints:**
- **OSIV off: Yes.** The controllers pass detached entities, and `saveAndFlush` merges them inside the transaction.
- **Tenant transaction manager: Yes.** All three methods already use it.
- **Jakarta: Yes.**
- **H2: Yes.** The new queries are JPQL; the race and migration ITs run on Testcontainers.
- readOnly, Caffeine, `BaseControllerTest`, metrics: N/A. There is one controller `catch` arm, covered by the receive unit test.

**Completeness:** 0 DB ✓ §1 · 1 callsites ✓ §0 · 2 adjacent ✓ A§0.5 · 3 back-compat ✓ (messages unchanged; numbering identical without deletes; `generateNumberWithAdvice` signature kept) · 4 concurrency ✓ §3, §8 · 5 multi-tenant ✓ 9-database census · 6 errors ✓ named violation → `BusinessException`, others rethrown, plus the receive 55P03 arm · 7 observability ✓ WARN and stale gauge · 8 migration ✓ 6.1 · 9 tests ✓ §7 · 10 v1: no (v1 is reference-only; it has no client).

## 10. Resolved decisions

Decisions 1–10 are Nam's (2026-11-11); do not reopen them.

1. One plan covers all four defects.
2. The loser gets the existing refusal messages, with no auto-retry.
3. Plain transactional build: `lock_timeout` 2 s, drop-first; no `CONCURRENTLY`.
4. The partial unique predicates as in Fix A.
5. Add a non-unique `goodsreceipt(advice_id)` index.
6. No unique index on receipts. Lock the advice first, in `receiveGoods`, the finisher and `updateAdviceWithPositions`.
7. Reuse the oldest receipt.
8. Number by max + 1; reissuing a deleted top number is OK; no renumbering; no unique index on numbers.
9. The doc fixes in Fix D. *(The planned `wms2-api/CLAUDE.md` harness-line fix was dropped: develop already has it, per Critic L1.)*
10. The audit's "touch the lane row" alternative is rejected on PostgreSQL semantics.

**Planner decisions from round 1, signed off by Nam at plan approval (2026-11-11):**

11. **Fail closed on predicate re-entry.** If some path ever moves a lane-holding order back below 700, the club run fails rather than double-booking a lane.
12. **Adopt the Architect's lock-then-recheck as the primary refusal path**, with the index as the guarantee. This adds no migration, and it keeps a tenant stuck at V2.2.50 correct.
14. **Nam, 2026-11-11 (mid-implementation, escalation trigger 1): narrow the staging-lane index to CLUB batches.**
    - **New predicate:** `WHERE staginglane_id IS NOT NULL AND state < 530 AND type = 'CLUB'`, used for both the index and the DO guard.
    - **Why:** the full integration lane failed demo-reset. `demo-datasets/meridian/fixtures.sql` (variant `west`) seeds PICK_PACK, CLUB and TRANSFER_INTRACOMPANY batches, all open, on staging lane 23. It is deployed as tenant `meridiandemo` (warehouses `mdle` and `mdlw`) on **UAT and dev**. The §1 census never covered demo tenants.
    - **Effect:** the narrowed index needs no data change anywhere, and still guards the race path, the club-line assign.
    - **Accepted trade-off:** the index is now narrower than the availability query, which has no type filter.
    - **Fixture fix:** the fixture also stops putting a lane on non-CLUB batches.
    - **Follow-up (Nam, same day):** the implementer found that the premise "only CLUB batches get a staging lane" was **not** enforced in code. `assignStagingLaneToOrderBatch` had no type check; only the UI list kept other types out. PRD shows 0 non-CLUB batches have ever held a lane. So the method now refuses a non-CLUB batch with a BusinessException. That makes the CLUB-only index a complete backstop.
13. **Use JPQL to read the numbers and take the max in Java**, not native SQL. This avoids the auto-flush risk and keeps the H2 test contexts working.

## ADR: SBDEV-4107 concurrent assignment

- **Decision:** lanes are refused by a lock followed by a re-check in a second statement (A1). The guarantee behind that is partial unique indexes on open lanes (A2), whose violation is mapped to the same refusal message. Receipts lock the advice first and reuse the oldest receipt. Position numbers are max + 1 over the live suffix, read through JPQL and taken under the advice lock.
- **Drivers:** (1) correctness across replicas and against any future writer; (2) a migration that cannot wedge a tenant or stall writers for more than 3 s; (3) no UI or message change.
- **Alternatives considered:**
  - Touch the lane row under the lock: rejected. EvalPlanQual re-checks only the locked row.
  - SERIALIZABLE isolation: rejected. Every caller would need retry handling.
  - The index alone: rejected. The loser would surface only through the catch, and a tenant left at V2.2.50 would stay racy.
  - The re-check alone: rejected. It is a convention, not a guarantee.
  - A unique index on `goodsreceipt(advice_id)`: impossible. 2,036 historical duplicates.
  - A per-receipt counter column: rejected (Nam).
  - Native max + 1: rejected. It depends on auto-flush, and it breaks the H2 contexts.
  - `CREATE INDEX CONCURRENTLY`: rejected. It hangs under the boot migrator (SBDEV-4092).
- **Why chosen:** each mechanism is proven separately and attributably (§7 *Kill* column). The DB index holds across every writer, and A1 keeps refusals on the normal path with no 500.
- **Consequences:**
  - The migration takes a SHARE lock on `customerorder` for the length of its build. That build is gated at < 1 s.
  - Receives on one advice serialize.
  - Fail-closed on predicate re-entry: if any path moves a lane-holding order back below 700, the club run fails instead of double-booking.
  - A deleted top position number can be issued again.
- **Follow-ups:**
  - Measure the build time before deploy (6.1).
  - Order-number count (`generateOrderNumber`) stays a residual (A§0.5).
  - The broken, unused `generatePositionCountStringBy*` SDR queries (A§E): flagged only.

## 11. Implementation status

**TDD gate, 2026-11-11.**
- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-4107`, branch `feature/SBDEV-4107-concurrent-assignment-races` at `df30fa62`, uncommitted; test files only, `src/main` untouched.
- **Baseline:** 21 new or changed tests red, each on an attributable assertion. IT 6b is green by design. The harness's default mode is unchanged (GoodsReceiptPositionAdjustIT 4/4 and BusinessServiceLockRefreshStaleVersionIT 12/12 green). Full report: `SBDEV-4107-evidence/tdd-gate-baseline.md`.
- **Bug 1 proven:** ITs 1 and 2 run in the harness's strict mode. The harness confirmed the subject was blocked by the holder's location lock, and the subject still assigned the lane.
- **Unit-suite baseline on develop `df30fa62`:** 10,210 tests, 0 failures, 0 errors, 1 skipped (`mvn -o test`, detached worktree, 2026-11-11).
- **Gate tests committed:** `84d7653a`.
**Implementation, 2026-11-11/12.** PR [#665](https://github.com/SiteBossInc/wms2-api/pull/665), branch `feature/SBDEV-4107-concurrent-assignment-races`, head `b22387f3`, 30 commits on develop `494d2216`. Develop (SBDEV-4108 #661, SBDEV-4114 #662) is merged in at `c7808d28`.

- **Commits, by fix:**
  - Gate tests: `84d7653a`.
  - V2.2.51: `71417e37`, later narrowed by `70bcedc2`.
  - Fix A: `6846d4f8`; the CLUB guard is `4b920f8a`, reordered in `98fc202a`.
  - Fix B: `69e8aa11`, `513ca9cb`, `66e1638f`.
  - Fix C: `66a3e158`, `39aaec4c`, `0ad11c17`, `a6d59da2`.
  - Fix D comment: `872b0994`.
  - Demo fixture: `4a3223d4`.
  - The rest are review, test-hygiene and arch-test fixes; see `git log`.
- **Tests added:**
  - ITs: TransferLaneRaceIT (4), StagingLaneRaceIT (2), TransferLanePredicateReentryIT, OpenLaneUniqueIndexMigrationIT (8, 8b, 8c), GoodsReceiptAdviceLockRaceIT, GoodsReceiptPositionNumberingIT, AdviceNumberingIT, AdvicePositionNumberingRaceIT, ReturnAdviceFinishRaceIT, ReturnAdviceCorrectionFinishRaceIT, ReturnAdviceStaleCorrectionRaceIT.
  - Unit: UniqueViolationsUnitTest, plus new cases in TransferOrderService, CustomerorderBatchService, Receiving, BasicService, ReceivingController and FileImportController unit tests.
  - Harness: `HeldRowLockRace.allowUnblockedSubject()`, ConcurrentTakeWarnCapture, and the Nirwana guard in Sbdev4107ReceivingItSupport.
- **Runs:**
  - Unit lane at `c7808d28`: 10,274 tests, 0 failures, 0 errors, 1 skipped. The baseline was 10,210 / 0.
  - Integration lane at `b22387f3`: 1,285 tests, 0 failures, 0 errors, 22 skipped.
  - `mvn -o clean verify -Pci` would not complete in one local run: memory pressure killed it twice, so the two lanes were run separately. PR CI runs the combined verify.
- **Mutation:** 14 hand-planted mutants killed (M7 after the review fix). PIT shows 0 survivors on changed lines. Reports: `SBDEV-4107-evidence/mutation-check.md`, `tdd-gate-baseline.md`.
- **Reviews:** conformance PASS (`review-impl-conformance.md`). Code review ran 7 rounds (`review-impl-code.md`); the reviewed SHA is the tip, `b22387f3`.
  - **Medium, round 1:** the finisher's first read came before the lock.
  - **Medium, round 2:** a regression from that fix. A correction could commit against a FINISHED advice.
  - **Lows:** all fixed except L8, which was dispatched to the ticket, and the accepted informational Lows.
- **Landmines found during implementation:**
  - (a) The shared Testcontainers DB lost its seeded 'Nirwana' unit load to our own fixture cleanup. It is guarded now; see memory `it-cleanup-via-stockunit-deletes-nirwana-seed`.
  - (b) The demo tenant `meridiandemo` was outside the §1 census (decision 14; memory `census-must-include-demo-tenants-and-datasets`).
  - (c) `saveAndFlush` had to be declared on two repositories that are not JpaRepository.
**Merged and on dev, 2026-11-12.**
- **Merge:** PR #665 merged into develop as **`fd712d7a`** at 2026-11-11T16:20:34Z, through `merge-one.sh` pinned to the graded head `b22387f3`, on base `494d2216`. Preflight was clean and there were no conflicts.
- **CI:** the PR check `test` (`mvn clean verify -Pci`) passed in 27m24s, run 43052605903. The develop push run 43057376895 passed `test` and `build`.
- **`post-merge-verify.sh`:** ALL PROVEN. Dev serves `develop-fd712d7a`, drift false.
- **Database:** on dev `dev_wh01_om1`, `flyway_schema_history` shows 2.2.51 success, and all three indexes exist. The demo tenant `meridiandemo` is not reachable from the session's MCPs, so its migration is unverified.
- **Bookkeeping:**
  - ClickUp is at `on dev`, with all 6 ACs ticked in the same edit.
  - 11 `⏳ pending-merge(SBDEV-4107)` markers are flipped in 5 docs.
- **Manual DEV test (§7), done 2026-11-12 against `develop-fd712d7a`. All four scenarios ✅, plus the non-CLUB refusal ✅.**
  - **Method:** every race used a psql holder, and a concurrent `pg_stat_activity` probe captured the API backend blocked *by the holder's pid*.
  - **Results:**
    - Transfer lane: refused after the wait, and the control without a holder assigns.
    - Staging lane: blocked on the new `lockById`, then refused.
    - Two-position receive: reused the holder's receipt, so 1 receipt.
    - Delete then receive: `-000002`, not a reissued `-000001`.
    - Index: confirmed live with a 23505.
  - **Restore:** all 6 snapshots `restored`.
  - **Side effects left on dev:**
    - 3 zero-amount stock units on Nirwana;
    - 6 `STOCK_UPDATE` messages to OMS dev, net 0;
    - stockrecord history;
    - burned sequence numbers.
  - Full table on the ticket.
- **Next:**
  1. Measure the `customerorder` index build time before PRD (§6.1).
  2. `archive-plan`.
- **Escalation trigger 2 fired (minor):** `saveAndFlush` has to be declared on two repositories (§5 row). The tier is unchanged (already T3), and the design is unchanged.

## 12. Round-1 findings → disposition

| Finding | Disposition |
|---|---|
| Critic H1 / harness cannot express "did not block" | new `allowUnblockedSubject()` mode; ITs 1b, 3, 4 and 7 use it; `blocked == true` asserted separately after the fix |
| Architect H1 + Critic M2 / `lock_timeout` misread | 6.1 and §8 rewritten: the 3 s write-hold gate is measured |
| Architect M1 / the SHARE lock spans the whole transaction | customerorder index built last |
| Architect synthesis / two-statement re-check | Fix A1 (§10.12) |
| Architect M2, Critic L6 / receives on one advice serialize | measured (711 pairs, all same-operator); controller 55P03 arm |
| Architect M3, Critic L5 / native max + 1 needs an auto-flush | JPQL plus Java max; IT 6b |
| Architect M4, Critic L4 / unit-test inventory | §7 unit-test list |
| Architect M5 / finisher javadoc | Fix B javadoc + IT 9 |
| Critic M1 / IT 5 vacuous | setup is now 510 + 700; fail-closed recorded (§10.11) |
| Critic M3 / manual tests | psql-holder protocol, the endpoints, and seeding + restore SQL |
| Critic M4 / DO block | full SQL with `string_agg` lane ids; IT 8b |
| Critic L1 | `CLAUDE.md` item dropped |
| Critic L2 | §2 reworded: rejected on semantics, not by a test |
| Critic L3, Architect L3 | IT 6 goes through the public `delete(position, principal)` |
| Critic L7, Architect f | §0 T7: two-instrument census with its blind spot |
| Critic L8 | explicit `@Query` on `findByIdForUpdate` |
| Critic L9 | a Kill column per IT |
| Critic L10 | §3 diagram cut; §9 compressed |
| Architect L2 | if/else instead of `orElseGet` |
| Architect L4 | DO-check gap row in §8 |
| Architect 3a (55P03 for the loser) | §8 row |
| **Round 2:** Critic H-a + Architect R2-M1/M2 (found independently) / A1 has no DB-level kill | WARN capture marks which mechanism refused; IT 1 and 2 assert it absent, IT 1b and 3 present; new IT 3b with the holder on lane L |
| Critic M-a / IT 8b seed hits the existing index | drop the indexes inside the rolled-back transaction first |
| Critic M-b / the manual receive scenario passed on develop too | holder uses `FOR NO KEY UPDATE` and INSERTs a receipt; develop shows 2 |
| Critic M-c + Architect R2-M3 / IT 9 free-running | forced with HeldRowLockRace: holder INSERTs the completing GRP; deterministic OPEN on develop |
| Critic L-a / T7 constant set incomplete | §0 census widened to every sub-700 constant |
| Critic L-b / harness neither-blocked-nor-finished | that case fails the run |
| Critic L-c / IT 6b mutation | `FlushModeType.COMMIT` hint |
| Critic L-d / IT 5 entry point | `finalizeClubLine`; production `failJob` behaviour stated |
| Critic L-e / possible location↔batch cycle | Architect round 2: no cycle, a new wait only (§8 row) |
| Architect R2-L1 / 3 s of SHARE holds | §8 row, accepted |
| Architect R2-L2 / arm message | reworded so it does not name the advice as the cause |
