---
ticket: SBDEV-3442
kind: independent review — T2 lane 2 of 2 (concurrency and lock order)
reviewed: ee523d44 on bugfix/SBDEV-3442-scandestination-row-lock (base origin/develop 5fa9bef0), plus the
  uncommitted working-tree edit to MoveUnitloadLockOrderProbeIT (javadoc blind-spot note and a new outcome assertion)
date: 2026-09-24
reviewer: critic (read-only; no Maven runs; Hydra prd MCP read-only queries)
---
# SBDEV-3442 concurrency and lock-order review

## VERDICT: APPROVE, with 4 Low comment/doc corrections to make before merge

I found no failure mode beyond N1–N3 that is a different *kind* of failure. Every new cycle I could build is either a
PG-visible cycle (40P01 at `deadlock_timeout`, 1000 ms on Hydra prd) or a lock wait bounded by the tenant
`lock_timeout` (3000 ms, SBDEV-3250, present on origin/main). Both reach `RestExceptionHandler.handlePessimisticLock`
and return a 409. I found no REQUIRES_NEW or synchronous external call on any branch that can turn a wait into a hang.
The consult does understate N1 and N2 in three places, and the new code comment misnames N2's cycle partner.
Those are the findings below. None of them changes the design. All of them change what a future reader believes.

Severity key: CRITICAL blocks · MAJOR significant rework · MINOR/Low should fix, functional.
No CRITICAL or MAJOR findings. Mode: THOROUGH (escalation not triggered).

## Pre-commitment predictions vs outcome
| Predicted | Outcome |
|---|---|
| A REQUIRES_NEW reachable while holding UL(src) (sequence, message log, outbox) | One is reachable: the URL-not-configured branch of `OmsNotificationService.sendAfterCommit`, via `createServiceLog` → `SequenceTransactionService`. It touches only `message` and `los_sequencenumber` rows. No hang (Q2). |
| Damaged-path writes flushed early, putting a new table between L0 and the POs | **Confirmed.** This is finding L2. |
| The parent/child pallet case missed by the "same container" population | **Confirmed** for the docs (L3). Exposure measured as 0. |
| Probe IT is vacuous for Pickingorder-first | Confirmed. The working-tree edit now documents it as a blind spot (Q4). |
| lock_timeout changes what the operator sees | Small change, recorded under Q3. The mobile UI flattens every 409 into one generic toast anyway. |

---
## Findings

### L1 (Low, must fix): the code comment names the wrong partner for N2, and states the order backwards
`MobileMoveUnitloadService.java` (new comment above `:318`):
> `N2 UL(source) before Stockunit on the flow-bin branch inverts closeBOL's order;`

closeBOL's measured order is UL → SU, so the new order *matches* it. `MobilePalletizeWriteService.java:105`:
> `whose order was MEASURED off {@code pg_locks} — {@code unitload → stockunit → customerorder}`

and `:112-114` gives the table order `Billoflading → Unitload (...) → Stockunit`. The consult says the same
(`closeBOL's measured table order is UL→SU ... already contradicts transferStockToUnitLoad's SU→UL`). N2's real
partner is `StockunitBusinessService.transferStockToUnitLoad`, which locks SU → UL(src) (`:237`) and is reached by
Move Stock, pick-confirm, replenishment confirm and the fixed-assignment moves.
- Why it matters: someone chasing a 40P01 later will look at closeBOL, the one path N2 cannot deadlock with.
- Fix: `N2 UL(source) before Stockunit inverts transferStockToUnitLoad's SU→UL order (Move Stock / pick-confirm off
  the same unit load); it agrees with closeBOL's UL→SU.`

### L2 (Low): N2 is not limited to the flow-bin branch. The Damaged sub-path puts UL(src) → SU(src) on every branch
`scanDestination` calls `setStockDamaged` (destination is Damaged) or `removeStockDamaged` (source is Damaged)
**before** the branch fork (`MobileMoveUnitloadService` ~`:361-371`). Each of them calls `stockunit.setEntityLock(...)`
and then `stockunitRepository.save(stockUnit)` on every SU in the tree (`:733-736`, `:771-774`). Under Hibernate's AUTO
flush mode, the next JPQL query over `Stockunit` flushes those UPDATEs. That query is the recursive
`findByUnitloadId` inside the same method, or `stockunitRepository.findByUnitloadId` at the head of branch (a), or
the PO pre-walk's tree collection. Each UPDATE takes a row lock. The resulting order is:

`UL(src) NKU → SU(src tree) UPDATE → PO asc → Location(dest) → …`

It applies to branch (a), and to branch (c) when the source is on Damaged. Pre-fix the order was `SU → PO → Location → UL(flush)`.
The SU-before-PO inversion of SBDEV-2481 was already there. The UL-before-SU part is new on these branches.
Same partner as L1 (transferStockToUnitLoad off the same unit load). The consult lists this under "pending writes"
(`setStockDamaged/removeStockDamaged (:349/:354), which leave pending writes`) but never follows the flush, so it
records N2 as `branch (b) only`.
- Concrete interleaving: T1 = scanDestination(UL X → Damaged) takes UL(X) and flushes an UPDATE on SU(s1). T2 = Move
  Stock of s2 off X: `transferStockToUnitLoad` takes PO, then SU(s2), then waits on UL(X), which T1 holds. T1's
  recursion/pre-walk flushes an UPDATE on SU(s2) and waits on T2. That is a cycle: 40P01, bounded.
- Fix: amend the comment's N2 line to `flow-bin branch, and any branch whose source or destination is Damaged`.
  No code change: this is the same accepted residual, with a larger footprint than the note says.

### L3 (Low): N1's partner list leaves out the likeliest partner, a second Move-Unitload on the parent or child. floor.md's exposure query cannot see that pair
Two scanDestinations, A moving pallet P and B moving a parcel C off P:
- A: `UL(P)` (L0) → `lockOwningPickingorders(tree of P)`. That set includes C's POs, and `lockOwningPickingorders` has no
  state filter (consult (a)2), so finished outbound POs count. Then Location(dest), then `processTransfer` UPDATEs the child C.
- B: `UL(C)` (L0), then waits on `lockOwningPickingorders(tree of C)`, which A holds. A then waits on UL(C) for the child UPDATE. The result is a cycle and 40P01.

Pre-fix both transactions took the POs first, so they serialised without a cycle. The consult's partner list reads
`Move Stock / on-hold / fix-assignment on the same stock, or a pick-confirm`. It does not name Move-Unitload versus
Move-Unitload across a parent and child. floor.md's population query keys on **the same label**
(`TRANSFER + {…} records on the same label by DIFFERENT operators`), and P and C have different labels, so the
measurement does not cover this pair. I measured it separately on Hydra prd over 90 days, which is where the pair would show up:
- `unitload_record` TRANSFER rows never carry `fromunitload`/`tounitload` (0 of 98 in 90 days), so a parent/child join
  on those columns is blind by construction. I used a coarse upper bound instead: TRANSFER pairs with the same `fromlocation`
  within 60 s. Result: **0 pairs by different operators**. Positive control: **167 same-operator pairs with different labels**.
  So exposure is empty, and the finding is only about the docs.
- Fix: add `including a concurrent Move Unit Load of the unit load's parent pallet or of a child` to N1 in the comment,
  and add the coarse-bound query above to floor.md so the population claim covers the parent/child case.

### L4 (Low): the consult's lock-sequence map misses two sites. Both are benign, and both should be recorded
- **Flow-bin branch, new assignment**: `createFixedLocationAssignment` → `triggerReplenishmentMaintenance` →
  `recalculateForItem`. That call is REQUIRED and joins scanDestination's transaction (`FixLocationAssignmentService:107,
  304-349`). It takes Replenishorder locks, and possibly SU locks via reservation changes, **after L0 and before the PO locks** of
  `transferStock`. The item is the source SU's item, so SU(src) can be in its set. This is another N2/"Replenishorder after
  UL" site. Hydra prd has never had a replenishorder row, so exposure there is zero.
- **transferStock tail, default/PACKAGE types**: `sendToClearing` → `transferUnitLoadToLocation(…, ignoreLock=true)`
  (`UnitloadBusinessService:688-692`). It re-locks POs already held and takes no Location lock. The consult lists only
  EmptyPallets/EmptyTotes/`sendToNirvana`. No new order edge.
- Fix: one line each in the consult's "Unranked, noted only" section. No code change.

---
## Q1 — enumeration of other lockers on a Move-Unitload source and on the second tables

**Method.** `git grep` over `src/main` of the worktree:
(i) `unitloadRepository\.[A-Za-z]*ForUpdate\(`. Field-name census: 51 fields named `unitloadRepository`. The only other
`*UnitloadRepository` field, `pickingorderUnitloadRepository` (9), is a different entity. A second grep for any
`*nit[Ll]oad*.…ForUpdate(` receiver other than `unitloadRepository` returned nothing.
(ii) JPQL/native bulk writes on `Unitload`: 2 hits, both closeBOL (`BillofladingService:665,1591`).
(iii) `FOR UPDATE` natives: none on unitload.
**Blind spots:** implicit dirty-entity UPDATEs on a managed Unitload. Every `save()` of a loaded UL takes the row lock at
flush, and a grep cannot enumerate those. I covered them by partner family: any transaction that writes UL(src) after
holding a PO, SU, Location or Replenishorder lock. Also blind: SDR `PATCH /v3/unitload` (single-row, holds nothing else,
so it cannot close a cycle), unmerged branches, and v1.

| Locker (file:line) | Its order | Cycle with new order? |
|---|---|---|
| `MobileTruckLoadingWriteService:299,308` scanGate | UL(pallet) → UL(parcels asc) → Location(gate) | No. UL→Location now agrees (R2). |
| `MobilePalletizeWriteService:264/351, 445/482, 535/555` | UL(pallet) → UL(parcel) → CO | No. scanDestination takes one UL, and the carrier FK takes only KEY SHARE on the destination (no conflict with NKU). The parent is read, not locked. |
| `ParcelMonitorViewService:135-160, 218` | UL(pallet) → UL(parcels asc) → CO | No, for the same reason. |
| `ClubLineOrderProcessor:113` | UL(package) first → stock | No. Agrees with UL-first. |
| `StockunitBusinessService:237,249` transferStockToUnitLoad | PO → SU(src) → UL(src) → Location → UL(dest) → SU(dest) | **Yes: N1 (PO) and N2 (SU)**, including L2's Damaged path. 40P01. |
| `UnitloadBusinessService:904,950` recoverPalletFromNirvana | UL(id) → UL(original label) | No. scanDestination refuses a Nirvana source, and now does so after waiting on the lock. |
| closeBOL bulk UPDATE (`BillofladingService:665`) | BOL → UL set (no ORDER BY; can take a parcel before its pallet) → SU | Carried over, not new: scanDestination moving a pallet off a truck (UL(P) → … → child UPDATE) against closeBOL's parcel-first scan. Pre-fix the same order ran at flush. L0 only widens the window. |
| PO-first moves (on-hold, fix-assignment, Move Stock) and pick-confirm into/out of the source | PO → … → UL(src) write | **Yes: N1** (+ L3's parent/child scanDestination). |
| transferUnitLoadToLocation callers with `ignoreLock=false` that do not lock the UL first (16 sites per its javadoc) | PO → Location(dest) → UL(flush) | Only when the same UL, **or an ancestor of it** (processTransfer UPDATEs children), goes to the same Location. The consult's "same UL" should read "same UL or an ancestor". This is folded into L3's population, and exposure is empty. |
| Replenishment cron / replenish confirm | Replenishorder → SU (→ UL) | Only through L4 or consult (a)5. Zero rows on prd. |
| `SequenceTransactionService.getNextSequenceNumber` | los_sequencenumber row, REQUIRES_NEW, the only locker of that table (`git grep findByClassnameForUpdate`) | No. It waits on nothing else. |

## Q2 — REQUIRES_NEW or external calls while locks are held
REQUIRES_NEW census: `git grep REQUIRES_NEW -- 'src/main/*.java'`. Reachability is by call-graph reading of every
callee on all three branches plus the damaged path. The callees include UnitloadBusinessService.transferUnitLoadToLocation/processTransfer/
transferUnitLoadToCarrier/sendToNirvana/sendToClearing, StockunitBusinessService.transferStockToUnitLoad,
FixLocationAssignmentService.createFixedLocationAssignment, UnitloadService.createUnitload(name,…),
PickLineRealignmentService, ReplenishmentOrderSourceSyncService, UnitloadRecordService,
BillofladingPositionService and MessageService.
- `createUnitload(String name, …)`: both create sites in scanDestination pass a label, so there is no sequence call. The
  sequence-minting overloads (`UnitloadService:191,227`) are not reached.
- `sendStockChangeMessage` → `OmsNotificationService.sendAfterCommit`: the POST runs **afterCommit**, after the locks are
  released. The one synchronous branch is `urlPath == null`: `messageService.createMessage` → `createServiceLog`
  (REQUIRES_NEW) → `generateMessageNumber` → `SequenceTransactionService` (REQUIRES_NEW, nested). Both touch only
  `message` (insert) and `los_sequencenumber` rows, which no outer transaction holds and no other lock-holder waits on.
  The cost is two extra pool slots while UL(src) is held. That is pre-existing and not a cycle.
- Outbox `enqueue`, InventoryRecordService, PickingOrderMergeService and ReplenishGeneratorService: none is reachable from these callees.
- Backstop, verified: `LockTimeoutHibernateJpaDialect` applies `SET LOCAL lock_timeout` at every tenant transaction begin,
  REQUIRES_NEW included, 3000 ms (`application.properties:119`, also on origin/main). So even a JVM-mediated cycle I
  missed would end as 55P03 → `PessimisticLockingFailureException` → 409 within 3 s rather than hang. Hydra prd
  `deadlock_timeout=1000`, `lock_timeout=0` server-side. The app bound is what applies, and real PG cycles hit the detector first.
- Conclusion: the consult's "bounded, never a hang" holds. "Each a 40P01" is exact for PG-visible cycles. A
  JVM-mediated wait, if one exists, would be a 55P03 at 3 s, which returns the same 409.

## Q3 — operator-visible behaviour change (record in the PR, no fix)
Before: guards ran on an unlocked read. The contended wait happened at the Location/PO locks or at the flush UPDATE, and was
also bounded at 3 s. After the holder committed, the outcome was a versioned-flush `ObjectOptimisticLockingFailureException`
→ 409 "modified by another user", or a silent wrong write. After: the wait happens at the source lock (≤ 3 s). Then either the move
proceeds on fresh state, or it is refused with the business reason (for example "Can not move unit load from … Shipped", or the truck
guards), or after 3 s it returns 409 "currently locked by another operation". One new case: a source that the guards would
refuse outright (Nirvana/Shipped/ON_HOLD/fixed) but whose row is held for more than 3 s now gets the 409 first and the business message only on retry.
In practice the mobile client hides the difference: `wms2-mobile-ui/store/moveUnitload.js:41-55` maps every
non-2xx to one toast, `Error: Request failed due to a network or server issue. Please retry.`. So the operator sees
up to 3 s of spinner and then the same generic toast that the old stale-409 produced. Long UL holders that can trigger this are closeBOL on a large BOL
and clubline `processOrder`. Palletize and scanGate hold their locks for milliseconds.

## Q4 — does MoveUnitloadLockOrderProbeIT measure what it says?
- Test 1 (blocked in `SELECT … FOR NO KEY UPDATE` on unitload with `backend_xid` NULL, and the move completes after rollback):
  it catches a Location-first mutant, because the Location NKU assigns an xid. floor.md M1 shows xid 8523 on the flush-UPDATE mutant.
  It **cannot** catch Pickingorder-first, because the fixture has no stock and therefore no owning PO. The working-tree edit now says exactly that
  (`a Pickingorder-first mutant would pass here (blind spot, not measured)`). I accept that as a documented blind
  spot. The only realistic PO-first change is the consult's T3 option (a PO pre-lock before L0), which is a deliberate order
  change that would rewrite this test anyway. A PO fixture is worth adding only if someone later relies on the xid
  assertion as a PO-order guard.
- Test 2 (holder moves the source to Shipped and commits, and the worker must refuse with the business message): it catches both
  "guard before lock on a stale entity" (the SBDEV-3244 upgrade throws Stale) and a guard with no lock at all. A mutant
  that evaluates a guard on a **scalar** pre-read before the lock *and keeps* the post-lock guard survives. That mutant is harmless,
  because the post-lock guard still decides. Only Shipped is exercised under contention. ON_HOLD, reservations and truck guards sit
  textually after `:318`, and the unit `InOrder` rail pins lock-before-`findById(sourceLocation)`. That is adequate.
- Timing: the IT profile sets `wms.tenant.lock-timeout-ms=10000` (`application-postgres-integration.properties:187`) against a
  100 ms poll, so there is no lock-timeout flake risk. It does not exercise prod's 3 s bound, and it does not need to.
- Not measured, and stated in the javadoc: branches (b) and (c) and N1–N3. That is acceptable for T2.

## What's missing (unscored)
- The PR description should carry the Q3 behaviour note in one line.
- The consult's R2 ("fixes scanGate inversion") is sound. It rests on scanGate B3 locking the parcel before inserting
  positions (`MobileTruckLoadingWriteService:308`), which I verified as present.
- Resolver change blast radius: `existsByLabelid` also changes `StockunitService:341` and `MobileMoveStockService:119`.
  Neither relied on the side-effect load. It is neutral, costing one extra lookup where a later `findByLabelid` no longer hits L1.

## Open questions
- Is SBDEV-3250's dialect in the image actually running on Hydra prd? It is on origin/main, but per memory the deployed
  image can differ from main. Check `/api/public/version` before quoting "3 s" to operators.
