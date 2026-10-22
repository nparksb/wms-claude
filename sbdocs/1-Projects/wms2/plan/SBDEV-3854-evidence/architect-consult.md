---
ticket: SBDEV-3854
lane: architect consult (read-only)
base: origin/develop fb087689 (worktree .claude/worktrees/wms2-api/SBDEV-3854)
date: 2026-10-21
---
# SBDEV-3854 — architect consult: is the (a)+(b) tx boundary safe and complete?

## Verdict
(a) is the right choke point and fixes every broken chain found. It is **safe on every caller but one**:
the replenish job's FLA cleanup catches a FacadeException inside its own tx and continues (Q1, finding P1).
(b) is correct for `/deleteContainer` and `/bulkDeleteContainer` but is **inert on the recursive path**
(self-invocation), so `deleteUnitLoadRecursive` needs its own annotation for the atomicity (b) is for.

## 1. Rollback-only poisoning
Mechanism: with (a), `sendStockUnitToNirvana` becomes a REQUIRED participant. A Business/FacadeException
crossing its proxy inside an outer tx calls setRollbackOnly on the shared tx. A caller that catches and
returns normally then hits UnexpectedRollbackException at the outer commit.

| Caller | Outer tx at runtime? | Crosses proxy? | Catches & continues? | Verdict |
|---|---|---|---|---|
| `StockunitBusinessService.transferStockToUnitLoad` :518 | yes (:249 `@Transactional`) | **no** (`sendStockUnitToNirvana(...)` is a `this` call) | n/a | (a) is inert here. Behaviour unchanged |
| `UnitloadService.deleteUnitLoad` :761 | none today; (b) adds one | yes | no. The exception leaves `deleteUnitLoad` and the controller catches it **outside** the proxy (`UnitLoadController` :113-117) | safe |
| `UnitloadService.deleteUnitLoadRecursive` :613/:618 | **none** (no annotation; `deleteUnitLoad` is self-invoked, so (b) does not apply) | yes, one tx per SU | no | safe, but not atomic (see Q2) |
| `UnitLoadController.bulkDeleteContainer` :174 | none (controller) | yes, (b) per container | the try wraps the whole loop, outside the proxy | safe. The partial-batch semantics are unchanged and already documented at :148-150 |
| `GoodsReceiptPositionService.deletePosition` :227 | yes. Private, reached only from `adjust` :93 and `delete` :136, both `@Transactional(rollbackFor=Business,Facade)` | yes | no try/catch in :93-142 | safe. The outer tx rolls back anyway |
| `MobileCycleCountService.recountSingleUnitLoad` :228 / `countBySKURecount` :443 | none (class has no tx; `CycleCountLosController` has none) | yes | the controller catches outside | safe |
| `FixLocationAssignmentService.delete` :270 via `FixLocationAssignmentController` :129 | none | yes | the controller catches outside | safe |
| **`FixLocationAssignmentService.delete` :270 via `ReplenishOrderJobService.deleteEmptyFixAssignmentWithoutStockToReplenish` :80-92** | **yes, REQUIRES_NEW** | yes | **YES**: `catch (BusinessException \| FacadeException e) { ... return; }` | **P1 POISON** |

P1 detail. `sendStockUnitToNirvana` :565-567 throws before it mutates anything:
`if (BigDecimal.ZERO.compareTo(staleStockUnit.getReservedamount()) < 0) { ... throw new FacadeException("STOCKUNIT_HAS_RESERVATION", ...)`.
The job query (`ReplenishorderRepository` ~:254-269) filters on `stockUnit.amount = 0` but not on
`reservedamount`. So an FLA whose SU has amount 0 and reserved > 0 (an invariant violation, which needs dirty
data) triggers the following sequence:
1. Today the exception is caught, the REQUIRES_NEW tx commits nothing, and the job moves on.
2. With (a), the commit throws UnexpectedRollbackException.
3. The lambda in `ReplenishOrderJob` :743-750 catches only `OptimisticLockException | OptimisticLockingFailureException`, so the exception escapes `drainPageZero`.
4. It then escapes the `deleteEmptyFixAssignmentWithoutStockToReplenish()` call at `ReplenishOrderJob` :466. This **skips every later sub-op of the run (cancelUnreachable, flowbin-full, ...) on every tick** while the row exists.

The probability is low because it needs reserved > amount. The blast radius is the whole replenish job.
I could not census it because every DB MCP was CONNECTION_CLOSED this session. Query to run:
`select su.id from fix_location_assignment f join stockunit su on su.unitload_id=f.assignedunitload_id where su.amount=0 and su.reservedamount>0;`

Fix, in my preferred order:
- (i) In `FixLocationAssignmentService.delete`, before :270, add the same reservation refusal as a
  `BusinessException` thrown **before** the proxy call. That keeps the job's catch harmless. It is also the
  existing pattern: the method already refuses `amount > 0` at :265-267.
- (ii) Alternatively, add `UnexpectedRollbackException` to the job lambda's catch. This treats the symptom, so it is the weaker option.

The other throwables inside `sendStockUnitToNirvana` are `orElseThrow` "StockUnit not found" and the
`IllegalStateException` from a missing Nirwana row (:111-115). A RuntimeException rolls back regardless of
`rollbackFor`. The job does not catch either one, so neither adds a new poison.

## 2. OMS STOCK_UPDATE notification
- **`/deleteContainer` with (b).** The controller has no tx and calls the proxied `deleteUnitLoad` (tx). Inside it,
  `messageService.sendStockChangeMessage` (:767) leads to `StockChangeNotificationService.sendAfterCommit` :34, then to
  `OmsNotificationService.sendAfterCommit` :68-96. `isSynchronizationActive && isActualTransactionActive` is true there, so the
  service registers `afterCommit` and the message fires **once, after commit**, and is suppressed on rollback (:90-94).
  Today it is sent synchronously from the `else` branch (:97-112). The change is an improvement: OMS is no longer told about a delete that later fails.
- **Nesting (SBDEV-3267).** It is merged (`079e829e`, PR #327) as **documentation plus a rail**, not a fix. The comment at :72-83 says the guard
  "CANNOT be repaired. Nesting must simply not happen", and `NestedCallSiteRailTest` / `NestedSendAfterCommitIT` enforce it.
  This path is **not nested**: its entry is a controller request thread, not an `afterCommit` callback. No caller of
  `deleteUnitLoad` runs inside a TransactionSynchronization. The message-row write is safe in afterCommit
  because `MessageService` :110 is `REQUIRES_NEW` on a separate bean.
- **Bulk.** Each container gets its own tx, its own `afterCommit` and its own message, once each. Same as today.
- **Recursive.** No change from (a)/(b). Children run `deleteUnitLoad(notifyCRM=false)` as self-calls (:613/:618), and
  `deleteUnitLoadRecursive` itself has no tx, so the single send at :621-624 goes synchronously, once, at the end.
  ⚠ Pre-existing loss: if a later child throws, the earlier children are already committed (one tx per SU via (a)),
  and the exception skips :621-624. **Those committed removals are never reported to OMS.** Before (a) every
  stock-bearing child 500'd first, so (a) makes this partial-commit window newly reachable.
  The cure is `@Transactional(tenantTransactionManager, rollbackFor=Business,Facade)` on `deleteUnitLoadRecursive`.
  Its controller entry `UnitLoadController` :207 goes through the proxy and catches outside it, so this is poison-safe.
  The tree then commits or rolls back as one unit, and the send at :623 becomes afterCommit-once.

## 3. Sibling census (amount>0 reaching the self-invoked `changeAmount` :571 with no tenant tx)
`changeAmount` has exactly **one** self-invocation in `src/main` (`git grep "[^.]changeAmount("` → :571). So
`sendStockUnitToNirvana` is the only choke point of this defect class in `StockunitBusinessService`.

| Chain | Reaches :571 with amount>0? | Tx at runtime today | Broken today? | Fixed by (a)? |
|---|---|---|---|---|
| `POST /v3/unitLoad/deleteContainer` → `deleteUnitLoad` | yes | no | **yes (the ticket)** | yes |
| `POST /bulkDeleteContainer` → `deleteUnitLoad` | yes | no | **yes** | yes |
| `GET /deleteContainerRecursive/{id}` → `deleteUnitLoadRecursive` → `deleteUnitLoad` | yes | no | **yes** | yes (per-SU tx only) |
| `/fixedAssignment/delete/{id}` and the job → `FLA.delete` :270 | **no**. `amount > 0` is refused at :265-267 | no / REQUIRES_NEW | no | n/a (P1 applies) |
| `GoodsReceiptPositionController` :89/:133 → `adjust`/`delete` → `deletePosition` :227 | yes | **yes** (`@Transactional` :93/:136, entered via the proxy) | no | n/a |
| `CycleCountLosController` :162 → `recountSingleUnitLoad` :228 (count==0, no FLA) | yes (the SU's original amount) | **no** | **yes** | yes |
| `CycleCountLosController` :286 → `countBySKURecount` :443 (count==0, diff≠0, no FLA) | yes | **no** | **yes** | yes |
| `transferStockToUnitLoad` :518 | no (it fires only when the source amount is 0) | yes | no | n/a |

Cycle-count residue. Both cycle-count methods `cyclecountPositionRepository.save(...)` the position as **FINISHED**
(:222, :430) **before** the 500. On those paths, every zero-recount so far has probably left a FINISHED
position with the stock not zeroed, and no OMS message. Worth a DB census once the MCPs return. After (a) these
paths still are not atomic: the position save, the stock retire, `unitloadBusinessService.sendToNirvana`
and the synchronous message are separate units. Annotating both methods (their controllers catch outside the
proxy) closes that gap. That is a T1-sized add-on to this ticket.

Other structural siblings I checked:
- `UnitloadBusinessService.sendToNirvana` :562 has no tx and self-invokes `transferUnitLoadToLocation(...,
  ignoreLock=true, ...)`. That skips the location lock (:243). `CODE_MANUAL_REMOVAL`, `CODE_CYCLE_COUNT` and
  `CODE_DELETE_FIX_ASSIGNMENT` are not `BLOCK_REALIGN` (`PickLineActivityCodeClassifier` :33-38), so no
  `findByIdForUpdate` runs. Safe.
- `sendToClearing` :695 self-invokes the same method with `CODE_TRANSFER`. That code is BLOCK_REALIGN, so
  `lockOwningPickingorders` → `findByIdForUpdate` runs. All five callers sit under `@Transactional` public entries
  (`CustomerorderService.setPickingDate`/`cancelOrder`, `PickingorderBusinessService.cleanUpCancelledOrder`,
  `MobileMoveUnitloadService.scanDestination`). Not broken, as far as this method can tell.
- `createStockUnit` :118/:145 has no lock read.

Blind spots of this method:
- I walked `git grep` call sites and checked the enclosing method for an `@Transactional` within 2 lines. That
  shows the annotation exists, **not** that the entry crosses a proxy. I confirmed that only for the controller-entered chains above.
- It cannot see SDR/reflection/proxy-mediated callers or `@Lazy` self-injection.
- It cannot see the `@Lock` derived queries reached through other repositories.
- I did not walk callers of StockunitBusinessService/UnitloadBusinessService methods outside the two classes'
  self-invocation sites, beyond what is listed.
- I made no DB queries (MCPs down), so P1 reachability and the cycle-count residue are unmeasured.

## 4. Better single boundary?
**Keep (a) as the invariant fix**, because it covers every caller, including the cycle-count paths and the recursive path.
- **Fixing the self-invocation instead** (calling `changeAmount` through a self-proxy) is worse: `changeAmount` would commit the
  zeroing in its own tx and leave the Nirwana move outside it. That is a stock unit at 0 that never reaches Nirwana.
- **A transactional controller** is wrong: every one of these controllers catches Business/FacadeException
  *inside* the method. Inner proxies would mark rollback-only, and the friendly error body would become a 500 UnexpectedRollbackException.

Recommended set, all service-level, each entered via a proxy whose caller catches outside it:
1. (a)
2. (b)
3. `@Transactional` on `deleteUnitLoadRecursive`
4. the pre-proxy reservation refusal in `FixLocationAssignmentService.delete` (P1)
5. optionally, `@Transactional` on the two `MobileCycleCountService` recount methods

Tests:
- An IT for P1: an FLA whose SU has amount 0 and reserved > 0, driven through the job method. It must not throw UnexpectedRollbackException.
- A recursive-delete IT where the 2nd child throws. It should assert that nothing committed and no message was sent.
