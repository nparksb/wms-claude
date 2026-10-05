---
ticket: SBDEV-3442
kind: architect-consult (T2, single pass)
base: origin/develop 5fa9bef0 (worktree .claude/worktrees/wms2-api/SBDEV-3442)
date: 2026-09-24
---
# SBDEV-3442 — lock order of scanDestination after the source-UL lock

All paths are relative to the worktree's `src/main/java/net/aim_ai/wms/`. "NKU" = `FOR NO KEY UPDATE`,
which is what `PESSIMISTIC_WRITE` emits on PG (measured, `PalletizeLockOrderProbeIT:71-72`).

## Verdict
The 2-file design (resolver exact probes → `existsByLabelid`, `:301` → `findByLabelidForUpdate`) is correct
on the questions you asked (Q1–Q3: no UL/UL inversion; Location order improves). **But it does not meet the
bar as stated.** It adds two new bounded ABBAs you did not list: **N1** UL→Pickingorder and **N2** UL→Stockunit.
It also leaves one narrow upgrade path, **N3**, on the case-insensitive resolver fallback. Removing N1 or N3
needs a repository change, which fires escalation trigger (2). N2 cannot be removed by any ordering inside
scanDestination. Recommendation below: ship the 2 files and state N1/N2/N3 as accepted residuals, **or** Nam waives.

## Lock sequence per branch (post-fix)
Common prefix: **L0 = UL(src) NKU** at `:301` (new). Everything from `:308`–`:342` is reads, except
`setStockDamaged`/`removeStockDamaged` (`:349/:354`), which leave pending writes.

**(a) location** (`:391` → `UnitloadBusinessService.transferUnitLoadToLocation`, then `:394`):
1. L0 UL(src)
2. **Pickingorder asc NKU**: every PO referenced by any `pickingorder_position` on a tree SU (`UBS:235-238`).
   `CODE_TRANSFER` is BLOCK_REALIGN (`PickLineActivityCodeClassifier:36`). `lockOwningPickingorders` has **no
   state filter** (`PickLineRealignmentService:150-158`), so finished POs are locked too.
3. Location(dest) NKU (`UBS:245`). This is an upgrade, because `:342` and `ScannedCodeResolver:170` already
   loaded the row. Pre-existing.
4. Parent pallet: **read only** (`UBS:330`). Only the parcel is written, `carrierunitload_id=NULL` (`:333-334`).
5. `processTransfer`: pending UPDATEs on src and its descendants, UPDATEs on `pickingorder_position` (realign),
   and **Replenishorder NKU** (`ReplenishmentOrderSourceSyncService:97`).
6. `handleTruckOffLoading`, for an outbound-pallet label only: its native query auto-flushes step 5. Descendant
   UL row locks come in `findByCarrierunitloadId` order, then the `billoflading_position` DELETEs (`:527,:529`).

**(b) flow bin** (`:422`/`:478` → `transferStock` `:614`):
1. L0
2. `transferStockToUnitLoad`: PO asc → **SU(src) NKU** → UL(src), a WRITE→WRITE re-lock → Location(src) →
   UL(dest) → SU(dest) → Location(dest) (`StockunitBusinessService` Hook B, `:192-198` ff)
3. Tail (`:648/:652`): `transferUnitLoadToLocation(src, EmptyPallets|EmptyTotes)` re-locks the POs and then takes
   Location(EmptyPallets) NKU. The alternative, `sendToNirvana`, uses `ignoreLock=true` and takes no Location lock.

**(c) container** (`:473` → `transferUnitLoadToCarrierCore`):
1. L0
2. Reads only: dest (`:426`, unlocked), dest's ancestors, old parent (`UBS:459,468`)
3. UPDATE src `carrierunitload_id=dest` (`UBS:503-504`). The FK `fk3qewwix…` (V2.2.00:4922) takes **FOR KEY
   SHARE** on the dest row at flush. There is no PO pre-walk on this path.
4. `processTransfer` as in (a)5

## Your four questions
**Q1 (parcel in a pallet → location): no inversion; do not lock the carrier pallet.** The pallet row is never
written (`UBS:330` reads it; `:333` nulls the parcel's own column). A change *to* NULL runs no RI check, so the
pallet row gets no lock at all. The on-truck TOCTOU is still closed: `scanGate` must lock this parcel in B3
(`MobileTruckLoadingWriteService:308`) before it can insert positions, so L0 serialises against it. Locking the
pallet first would *add* a lock this path does not take today. It would also need a scalar
carrier-id-by-label, which does not exist: the repo has only `labelid`-by-id at `UnitloadRepository:173` and
`findIdsByCarrierunitloadIdOrderById`, which goes the other direction. **Ruled out.**

**Q2 (container dest): no effective inversion.** The dest row is not UPDATEd. The FK takes KEY SHARE, which
conflicts only with FOR UPDATE, DELETE, and key-changing UPDATEs. It does not conflict with the NKU that
`scanPallet`/`scanGate` take, or with `closeBOL`'s non-key bulk UPDATE. `labelid` is `uq_unitload_labelid`
(V2.2.00:3820), but Hibernate rewrites the same value, so PG classifies the UPDATE as no-key.
**Residual, not in scope:** the destination-side TOCTOU. `assertPalletNotAssignedToGate` (`:472`) reads
unlocked, and `scanGate` computes its B3 child list before this parcel joins. Closing it needs dest-first
locking (pallet→parcel order, which is correct) and a rework of the resolution order. That belongs on a follow-up.

**Q3 (Location): consistent, and better than today.** `scanGate` locks the pallet (B2 `:299`) before the gate
Location (`:468`), i.e. UL→Location. Pre-fix, scanDestination went Location(dest) `UBS:245` → UL(src) at flush,
which is the inverted order. Post-fix it goes UL→Location, so this fixes a pre-existing inversion. The
`:342` `findByName` upgrade does not change the order. It only makes `:245` a version-checked upgrade, which can
throw a spurious 409 if someone writes the Location row concurrently. Pre-existing and unchanged.
*New but vanishing:* other `ignoreLock=false` callers that do not lock the UL first take Location→UL. A cycle
needs the *same UL* moved to the *same Location* by two flows at the same moment.

**Q4 (other source loads before :301): one more, the resolver's case-insensitive fallback.**
`canonicalUnitLoadLabel`/`canonicalDestinationCode` fall back to
`caseInsensitiveUnitLoadSpellings` (`ScannedCodeResolver:203-206`) → `findAllByLabelidIgnoreCase`. That query
returns **entities** (`UnitloadRepository:151-152`, `SELECT u`). So when a label is typed in a different case,
the source is already managed at `:301` and the lock becomes a version-checked upgrade (**N3**). Nothing else
in `:289-:300` touches the source. The controller (`MoveUnitloadController:75`) reads nothing before the call.
Swapping in `existsByLabelid` on the exact path changes no behaviour: the label is UNIQUE, so `findByLabelid`
could never have thrown IncorrectResultSize there.

## New hazards the proposed design introduces (not in the ticket)
- **N1: UL(src) → Pickingorder, branches (a) and (b).** This inverts SBDEV-2481's documented "Pickingorder
  BEFORE Unitload/Stockunit/Location" (`UBS:227-234`, `StockunitBusinessService` Hook B comment). Pre-fix, the PO
  was the first lock, so this was consistent. Cycle partner: a transaction that already holds a PO referencing
  a tree SU (any state, see step (a)2) and then wants UL(src). Examples: Move Stock / on-hold / fix-assignment
  on the same stock, or a pick-confirm into or out of X. A pick-*from* X with an active line is refused by
  `checkReservedStock` (`:340`) before we ever wait on the PO, so it cannot close the cycle.
- **N2: UL(src) → SU(src), branch (b) only.** `transferStockToUnitLoad` locks SU → UL. Pre-fix, (b) inherited
  that order; post-fix it is UL → SU. The partner is a concurrent Move Stock off the same source, and no PO is
  required. This is **intrinsic**: closeBOL's measured table order is UL→SU (`MobilePalletizeWriteService`
  javadoc, `ClosebolLockOrderProbeIT`), and it already contradicts transferStockToUnitLoad's SU→UL. No
  ordering in scanDestination satisfies both.
- **N3: fallback-path upgrade** (Q4). This is an `ObjectOptimisticLockingFailureException`, returned as 409
  retryable (`RestExceptionHandler:361`). It fires only if another transaction commits the source row between
  the resolver and `:301` within the same request, and only for a case-mismatched label.
- Unranked, noted only: Replenishorder (a)5 now comes after UL. Hydra prd has never had a replenishorder row.

Bounds: N1 and N2 abort as 40P01 → `PessimisticLockingFailureException` → `RestExceptionHandler:370`. PG may
pick either transaction as the victim, so a Move Stock or a pick-confirm can be the one that fails. Neither can
hang. N1 and N2 need **two concurrent operations on the same container**, which is the same precondition as
the TOCTOU (Hydra 90d: zero). The trade therefore turns a silent wrong write into a retryable abort, within the
same empty population.

## Hazards the design removes
- **R1:** in branch (b), `transferStockToUnitLoad`'s `findByIdForUpdate(UL src)` used to be a version-checked
  upgrade of the entity loaded at `:301`. It is now a WRITE→WRITE re-lock, so one StaleObjectState path is gone.
- **R2:** the Location↔UL inversion against scanGate (Q3).
- **Carried over, not new:** UL(pallet)→bol_position in (a)6 already happened at flush pre-fix. The inversion
  against closeBOL's early garbage DELETE is the known unrankable one (`MobileTruckLoadingWriteService:88-93`).

## Recommended minimal design
1. `ScannedCodeResolver:126` and `:171`: `findByLabelid(x).isPresent()` → `existsByLabelid(x)`.
2. `MobileMoveUnitloadService:301`: `findByLabelid` → `findByLabelidForUpdate`, keeping the same `orElseThrow`.
   Add a javadoc stating the per-branch order above, with N1/N2/N3 as accepted residuals, and Q2's dest
   TOCTOU as out of scope.
3. No lock on the carrier pallet (Q1). No lock on the dest pallet (Q2). Do not move the Location lock.
4. Tests:
   - A resolver unit test: `verify(never()).findByLabelid` on the exact path.
   - A row-granular probe IT modelled on `PalletizeLockOrderProbeIT`, branch (a): a second transaction holding
     UL(src) NKU must block scanDestination *before* any PO or Location lock appears in `pg_locks`.
   - An N3-free control: a re-lock in branch (b) does not throw under a concurrent version bump.
   - Mutation-check each assertion: revert `:301` → the probe goes red.

**Ruled out:**
- Pallet-first locking: Q1 needs a new repo method and adds a lock the path does not take today.
- `em.refresh(x, PESSIMISTIC_WRITE)` in place of first touch: the house rule forbids it, per
  `MobilePalletizeWriteService:89-91`.
- Detaching the fallback entities inside the resolver: that would detach instances that the other three
  callers (`StockunitService:341`, `MobileMoveStockService:119`, `:139`) may already manage. A bare
  `@PersistenceContext` is also the landlord EM.
- Re-running the guards after a late lock: that is an upgrade, which is exactly the Stale path you want to avoid.

## Tier
- **As recommended (2 files, N1/N2/N3 accepted in writing): T2.**
- **To meet the bar literally:**
  - N3 → `findAllByLabelidIgnoreCase` returns `List<String>` via `SELECT u.labelid` (one production caller;
    `ScanResolutionQueryDerivationUnitTest` pins it).
  - N1 → a PO pre-lock before L0, which needs a scalar `findIdByLabelid` plus an id-based tree walk.
    `collectStockUnitIdsForUnitloadTree` uses only `top.getId()`.
  - Both are repository/projection changes that were not anticipated, so **escalation trigger (2) fires → T3**
    unless Nam waives.
  - N2 stays in every variant, short of not locking the source on branch (b). That would mean reordering
    scanDestination so the destination is classified before the source is touched, which is a larger rework
    with operator-visible changes to message order.
