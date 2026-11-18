---
title: "Add-to-pallet writers: gate-guard the manual split and lock the destination pallet before judging it"
ticket: "SBDEV-4047"
ticket_url: https://app.clickup.com/t/868mtu3qj
type: "bug"
priority: "normal"
status: "archived"
revision: "r3 — applies review-architect-r2.md (N1–N3, L1–L3) and review-critic-r2.md (L1–L4). r2 answered round 1. Disposition: §11."
tier: T3
project: [wms2]
version: "v2"
repos: [wms2-api]
branch: "bugfix/SBDEV-4047-add-to-gate-pallet-guard-and-lock"
base_commit: "wms2-api origin/develop 5ed6f000 (merge of SBDEV-3441, PR #636; first parent 295cabf3)"
db_verified: true
db_verified_note: "PRD wh01_om1_v2 (read-only): 2 position-less children (PM-016720 / BOL 32250854, v1 era) vs 56,323 control, v2-era 0; 120-day joins onto OUT-/PM- 0; los_sysprop inbound/outbound patterns disjoint (2026-11-07). DEV dev_wh01_om1, Pallet-typed (2026-11-07): TRUCK_LOADING 4, CLOSED 15,890, happy-path pallets 1,054."
requester: "Nam Park"
created: "2026-11-06"
updated: "2026-11-07"
related: ["[[SBDEV-3441]]", "[[SBDEV-3442]]", "[[SBDEV-3862]]", "[[SBDEV-3452]]", "[[SBDEV-3487]]"]
tags: [plan]
---

# SBDEV-4047: gate-guard the manual split, and lock the destination pallet in both add-to-pallet writers

**Ticket:** [SBDEV-4047](https://app.clickup.com/t/868mtu3qj) · **Tier:** T3 (lock topology against scanGate and closeBOL; data integrity: a shipped child with no BOL position strands its order) · **Evidence:** `owl/.omc/research/SBDEV-4047/{analysis,decisions,review-architect-r1,review-critic-r1}.md` · **Register:** P72 (this ticket), P73 (closeBOL backstop)

**Severity, plainly:**
- **Bug 1** (the split has no gate guard) is deterministic, but no one has exercised it on WineCo: PRD shows 0 joins onto `OUT-`/`PM-` pallets in 120 days.
- **Bug 2** (the writers judge the pallet unlocked) is a latent race with 0 v2 instances. The 2 PRD rows of this shape are v1-era.

## 0. Affected sites

**Method** (analysis §3): `git grep -n -E "transferUnitLoadToCarrier(Core)?\(|transferUnitLoadToCart\("` plus `git grep -n "setCarrierunitloadId("` on `origin/develop -- src/main`. Native and JPQL writes to `carrierunitload_id` returned 0 hits. `Unitload` is in `SDR_WRITE_WITHDRAWN`. **Blind spots:** reflection, onboarding scripts, and SQL outside `src/main`. Sites 1 and 2 below are this grep's add-to-pallet writers that lack a lock; the plan claims nothing beyond that set.

| # | Site | Gate guard today | Destination locked today | Verdict |
|---|---|---|---|---|
| 1 | `MobileMoveUnitloadService.scanDestination`, CARRIER_WHOLE arm | yes, on an unlocked `destUl` | **no** ("never a ForUpdate variant here") | **IN: Fix B** |
| 1b | same, NO_UL inbound find-or-create (`unitloadService.createUnitload(...)`) | yes, after the create | no | **OUT, closed by construction (R1, §5)** |
| 2 | `StockunitService.transferStock`, existing-container pallet branch | **none.** `assertCanReceiveStock` enforces only Nirvana; lock/Shipped are shadow-only (`TRANSFER_DESTINATION_ELIGIBILITY_ENABLED=false` on DEV and PRD) | **no** (`findByLabelid`) | **IN: Fix A** |
| 3–4 | `MobilePalletizeWriteService`, `ParcelMonitorViewService` | yes, after the lock | yes | OUT: correct; they are the precedent |
| 5–9 | `AdviceService`, `ReceivingService`, `MobilePickingService` (cart), `BillofladingService` (minted pallet), ULBS leave (null carrier) | — | — | OUT. `ReceivingService` is residual R2 (analysis §3 row 6) |

## 1. Problem

scanGate PHASE B3 reads the pallet's children unlocked. PHASE D re-reads them unlocked and moves each one to the gate, but writes `billoflading_position` rows only for the B3 set. A unit load that joins in between reaches the gate with no position. closeBOL ships it (it selects by `carrierunitload_id`) and strands its order (it handles orders through positions only; analysis §4). SBDEV-3441, now merged, re-checks parcels that LEAVE; TLWS:430 reads *"One JOINING the pallet after the id read is SBDEV-4047."* A manual split onto a gate-assigned pallet reaches the same end state with no race at all.

| Query (read-only) | Env | Result |
|---|---|---|
| Children of a pallet with a BOL position that have no position of their own | PRD / DEV | **2** (PM-016720, BOL 32250854, 2026-04-24, v1 era, joined AFTER closeBOL) vs 56,323 control; v2-era **0** / DEV **0** |
| `unitload_record` joins, 120 days, by the `tounitload` prefix | PRD | TRANSFER 6,862 (all `IN-`), MANUAL_SPLIT 1 (`IN-000484`); **0 onto `OUT-`/`PM-`**. Blind spot: the prefix is a naming convention; WineCo only |
| FK `unitload.carrierunitload_id → unitload.id` (not deferrable) | DEV, PRD | present, so a join takes `FOR KEY SHARE` on the pallet |

## 2. Root cause

- **Bug 1 (deterministic).** After a plain `findByLabelid`, the split's pallet branch runs only `destinationEligibilityService.assertCanReceiveStock(unitLoad)`, then mints a Case and joins it. The palletize writers (MPWS ×3, PMVS) and Move UL run `assertPalletNotAssignedToGate` (method: `git grep -n assertPalletNotAssignedToGate`, 6 call sites); this branch does not.
- **Bug 2 (race).** scanGate B2 takes FNKU on the pallet. The join's FK UPDATE takes only `FOR KEY SHARE`, which does not conflict with it (SBDEV-3442 concurrency review: *"The parent is read, not locked."*). So neither writer ever waits on scanGate, and its gate guard judges uncommitted-away state.
- **Why scanGate cannot fix it alone.** A writer whose unlocked guard passed before scanGate's position INSERTs commit can commit its join *after* scanGate commits. Only a writer-side conflict on D's FNKU excludes that (architect antithesis rebuttal).

## 4. Architecture

```
scanGate (TLWS, unchanged):   BOL ─► PALLET D (FNKU, B2) ─► children asc (B3) ─► … ─► D: re-read children, INSERT positions
                                           ▲ conflicts
Move UL CARRIER_WHOLE (B):    Location read ─► self-ref refusal ─► classify (plain) ─► D (FNKU) ─► source P (FNKU) ─► re-derive + guards ─► join
Manual split, pallet (A):     findByLabelid + type (plain) ─► D (FNKU) ─► shipped ─► gate ─► eligibility ─► mint Case ─► SUBS ─► join
Palletize / closeBOL:         D ─► parcel  /  pallets asc ─► children asc
```
After the fix, sites 1 and 2 take the **pallet before the parcel**, the table order (`Billoflading → Unitload (pallet, then parcels) → …`, SBDEV-3419/3440) that palletize, closeBOL and scanGate already follow. The architect traced every lock the carrier arm takes after D and found no cycle (review Q1):
- the carrier arm takes no Pickingorder or Location lock;
- Pallet and Cart are `stockunitallowed=false`, so no stock path ever holds a SU and then waits on D;
- the split's code `CODE_MANUAL_SPLIT` is `PASS_THROUGH`, so it takes no PO lock.

## 5. Fix design

### Fix A: manual split, pallet branch (`StockunitService.transferStock`)

1. Resolve the Pallet type **before** the eligibility call: a pure read, hoisted.
2. Call `assertCanReceiveStock` **once** (architect L2: a second call would double the SBDEV-2994 shadow WARN):
   - on the non-pallet branch, where it is today;
   - on the pallet branch, after the lock.
3. On the pallet branch, **replace `Unitload pallet = unitLoad;` (:502)** with:
   1. `Unitload pallet = LockReads.forUpdate(entityManager, Unitload.class, unitLoad.getId(), unitloadRepository::findByIdForUpdate).orElseThrow(() -> new BusinessException(MSG_TRANSFER_DESTINATION_UNITLOAD_NOT_FOUND, resolvedUnitLoadLabelId));`. The row is managed, so this does a scalar FNKU and a refresh: no version-checked upgrade, and the same instance comes back.
   2. `billofladingPositionService.assertPalletNotShipped(pallet.getLabelid(), ShippedGuardSite.MANUAL_SPLIT)`, the shipped diagnosis first (decision 6).
      - Palletize has no destination-side shipped check; its "specific wins" order is the source-side pair.
      - This is the existing destination-pallet guard (CLOSED only; key `billOfLadingPositionUnxepectedStateFound`).
   3. `billofladingPositionService.assertPalletNotAssignedToGate(pallet.getLabelid())`: always on, existing message.
   4. `destinationEligibilityService.assertCanReceiveStock(pallet)`.
4. The rest is unchanged. `palletLocation` reads the refreshed row. All refusals fire before `assertMintedContainerIsPermittedAtDestination` and `createUnitload`, so nothing is minted and no sequence number is burned.
5. **Wiring:**
   - add `BillofladingPositionService` to the constructor (the architect traced no bean cycle; 5 services already inject it);
   - add `@PersistenceContext(unitName = "tenant") private EntityManager entityManager;`.
6. **Lock order:** D → source SU → source UL → source location → Case (own INSERT) → destination location.
7. **Callers:** RTS passes `existing=false`; the controller is not transactional.

### Fix B: Move UL, CARRIER_WHOLE, M-first (decision 5)

0. **Self-reference refusal (architect M1, scoped by r2 N1).** Place it immediately after the hoisted `destinationStorageLocation = locationRepository.findByName(dest)`, which loads no Unitload, and before any Unitload read or lock.
   - Condition: `destinationStorageLocation == null && !dto.isMoveStock() && dto.getDestinationLabel().equals(dto.getUnitLoadLabel())`.
   - Action: `throw new FacadeException("CARRIER_SELF_REFERENCE", dto.getDestinationLabel())`, the core's own key and message.
   - Both labels are canonical (the resolvers return the stored spelling), so case variants are caught.
   - It does **not** fire when a Location of that name exists: Location precedence wins, as today. DEV has 1,346 unit loads whose label equals a location name, and those keep today's LOCATION_WHOLE outcome.
   - It does not fire for `moveStock`, which is a stock-arm request.
   - Without it, a Case scanned onto itself would load the source through the hoisted destination read, and `findByLabelidForUpdate` would become the version-checked upgrade the SBDEV-3442 javadoc forbids.
1. **Hoist the classification reads above the source lock, and only the reads:**
   - `destinationStorageLocation` (already read in step 0);
   - `locationType` (only when the destination is a Location);
   - `destUl`, `fla`;
   - then `DestArm destArm = classifyDestination(locationType, destUl, fla, dto.isMoveStock())`, called **once** and reused by the switch (architect M2). The inline predicate is gone.
2. Then `destUl = lockCarrierDestinationIfJoin(destArm, destUl)`, a new private helper. Only for `destArm == CARRIER_WHOLE` does it read the type: `UnitloadType type = unitloadTypeRepository.findById(destUl.getTypeId()).orElseThrow(() -> new EntityNotFoundException("UnitLoadType", destUl.getTypeId()))`.
   - **An empty lookup throws** (r2 N2). This is the same exception the core throws at ULBS:487-488. It is unreachable while `unitload.type_id` is NOT NULL with an FK; in unit tests, an unstubbed lookup fails loudly instead of silently skipping the lock.
   - It locks **iff** `Boolean.TRUE.equals(type.getUnitloadallowed())` (null-safe, r2 L1), with `LockReads.forUpdate(entityManager, Unitload.class, destUl.getId(), unitloadRepository::findByIdForUpdate)`. A vanished row → `BusinessException("No destination found for …")`.
   - `unitloadallowed=false` (or null) → no lock, which is today's behaviour; the core then refuses the type.
   - On the carrier path, the core's later `findById` of the type is an L1 hit, so the type read costs nothing.
3. Then the source `findByLabelidForUpdate`. It is still the source's first entity touch: step 0 guarantees that no hoisted read loaded the source row on a carrier-candidate path.
4. **Re-derived after both locks, from the instance the helper returned (architect M3).** These stay exactly where they are today and must not be hoisted:
   - `final Unitload destinationUnitLoad = destUl` is assigned **after** the helper's return replaces `destUl` (r2 L2). In unit tests with no EntityManager, the finder returns a different instance from the plain read;
   - `palletLocation` in the CARRIER_WHOLE case, which reads `destinationUnitLoad.getStoragelocationId()`;
   - `effDestLocId = destUl.getStoragelocationId()`;
   - `assertNotOntoNirvanaOrShipped`;
   - `destDamaged` / `srcDamaged` and the Damaged permission check;
   - `assertSourceCarrierNotOnTruck`, `assertNotFencedToteOntoCarrier`, `assertPalletNotAssignedToGate`;
   - `assertParcelNotIntoStorageArea(…, destUl.getStoragelocationId(), …)`.
   `fla` is not re-read: an FLA being assigned to a Pallet mid-scan is not plausible. Recorded, not closed.
5. **Javadoc:** a two-line rule replaces the SBDEV-3442 *"This is the transaction's first row lock"* paragraph: *"CARRIER_WHOLE: the destination carrier first, then the source; every other arm: the source first."*
   - The SBDEV-3862 bullet changes to: the window where **D itself** is moved onto or off Damaged is closed. The window where D is a child of a carrier E stays open, because E reads the tree plain. That case is unreachable on the measured tenants: Pallet/Cart have `onotherunitloadallowed=false` (architect L1).

**Inbound find-or-create (1b): no lock; closed by construction (architect Q4).**
- The branch accepts only `STRING_PATTERN_INBOUND_PALLET` labels.
- The only writer of BOL positions is TLWS, behind `requireOutboundPalletLabel`.
- On PRD, the inbound pattern (`CART-\d{4}|IN-\d{6}`) is disjoint from the outbound pattern (`OUT-\d{6}|TESTPALLET-\d{4}`) and from the printing pattern (`PM-%1$06d`), so a pallet returned there cannot hold a position.
- §7.1 row 1 keeps this checked per tenant.

### Rejected alternatives and out of scope

| Alternative / item | Why not |
|---|---|
| scanGate B2 as a full `FOR UPDATE` | Closes B3→D only, not the stale-guard window. Leaves Bug 1 open. Blocks the KS of all 8 FKs to `unitload(id)`. Native SQL. A new deadlock shape on the hot path |
| scanGate PHASE D membership re-check | Unlocked, so it only narrows the window and cannot catch a join that commits after scanGate (§2). Decision 8: no scanGate behaviour change. Listed as a follow-up candidate |
| Lock inside `transferUnitLoadToCarrierCore` | 6 callers. The caller-holds-locks contract (SBDEV-2232). It would land M-append/S-late: three cycles, and a Case minted at a stale location |
| M-append (source, then destination) | Three bounded 40P01 cycles vs palletize, closeBOL and scanGate (analysis §2); made deterministic by AC-9 |
| Enable `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` | Checks lock and Shipped, not BOL assignment |
| `NOWAIT` | Decision 2 |
| closeBOL backstop | P73 (decision 7) |

## 6. File change summary

| File | Change |
|---|---|
| `service/StockunitService.java` | Fix A; +1 constructor parameter; +tenant EntityManager |
| `service/mobile/MobileMoveUnitloadService.java` | Fix B: self-ref refusal, hoisted classification, `lockCarrierDestinationIfJoin`, javadoc |
| `service/BillofladingPositionService.java` | `ShippedGuardSite.MANUAL_SPLIT` (scaffolding commit, §7.2) |
| `service/mobile/MobileTruckLoadingWriteService.java` | **Comment only**, at TLWS:430: "joining is excluded by the writers' pallet lock (SBDEV-4047)" |
| 8 `unit/service/StockunitService*Test.java` (`AuditCommentClamp`, `DamagedOrderNumber`, `ParcelSourceRefusal`, `ReturnPreview`, `ToteContainerRelocation`, `TransferStockDestination`, `TransferStockGuard`, `UnitTest`; one `@InjectMocks` each) | `@Mock BillofladingPositionService`: Mockito passes `null` for a missing constructor argument. With no EntityManager set, `LockReads` falls back to the finder, so pallet-branch tests stub `unitloadRepository.findByIdForUpdate` |
| `unit/service/mobile/MobileMoveUnitloadServiceUnitTest.java` | (a) **Every Pallet/Cart `UnitloadType` fixture sets `unitloadallowed=true`** (critic H2, r2 N3). Sites, from `grep -n "new UnitloadType"` at 5ed6f000: the `unitloadType(id, name)` helper (:1522), and the inline builders at :3245, :3279 (`palletTypeForCreate`), :3719, :4234, :4452 and :4498 (`palletType`). The Tote/Package/Case builders at :3939/:3942/:3945 stay `false`. The default is `false` (`UnitloadType:31`), so a missed site would silently take the no-lock path. (b) **Rewrite `peeksTheDestinationUnitLoadOnceWithoutARowLock`** (SBDEV-3862 AC-17 control): for `moveStock=false`, assert `containsExactly("findByIdForUpdate(2)", "findByLabelidForUpdate(UL001)")` and replace the "carrier arm locks no destination" comment; `findByLabelid("PAL001")` stays `times(1)`; the `moveStock=true` case is unchanged. (c) Stub `findByIdForUpdate(destId)` wherever the carrier arm is reached |
| `integration/service/mobile/AbstractTruckLoadingPgFixture.java` | **Extend, do not copy:** a `seedCaseStockOn(location)` helper plus a Case-count-by-watermark helper |
| NEW `integration/service/mobile/AddToGatedPalletRaceIT.java` (extends the fixture) | AC-6, AC-7, AC-9 |
| `integration/service/mobile/MoveUnitloadLockOrderProbeIT.java` | AC-8 |
| Docs (this PR) | `wms2-bol-truck-loading-workflow.md` :180 row ("JOINING … SBDEV-4047" → excluded by the writer lock); OSIV map: a **new §8.6** "Move UL carrier-arm lock order" (§8.5 is the replenish order; architect L4); P72 corrected and closed |

## 7. Implementation steps

### 7.1 Prerequisites

| # | Prerequisite | Value |
|---|---|---|
| 1 | **Per-tenant label-pattern disjointness (R1)** | `SELECT syskey, sysvalue FROM los_sysprop WHERE syskey IN ('STRING_PATTERN_INBOUND_PALLET','STRING_PATTERN_OUTBOUND_PALLET','PRINTING_PATTERN_OUTBOUND_PALLET_LABEL');` gives disjoint patterns. **PRD WineCo, 2026-11-07: `CART-\d{4}\|IN-\d{6}` vs `OUT-\d{6}\|TESTPALLET-\d{4}` vs `PM-%1$06d`: disjoint ✓.** Hydra: not reachable from here, so Nam runs it before Hydra enables Move UL carrier moves. If it is ever not disjoint, R1 reopens |
| 2 | DB, sysprops, config | None. FK in `V2.2.00`; `lock-timeout-ms=3000` as is; no sysprop |
| 3 | Deploy order | None. 3441 is merged (`5ed6f000`); this branch is off it |
| 4 | Access, monitoring | None. Existing WARNs. Only the shipped path carries the `[MANUAL_SPLIT]` tag; the gate WARN takes no site argument (critic Low) |

### 7.2 Checklist (commit order)
1. `ticket-lease.sh claim SBDEV-4047`. Worktree `.claude/worktrees/wms2-api/SBDEV-4047` off freshly fetched `origin/develop` (5ed6f000). Capture the full-suite baseline.
2. **Scaffolding commit (no behaviour change, critic H1):** add `ShippedGuardSite.MANUAL_SPLIT`, which is only a logging tag. Set `unitloadallowed=true` on all 7 Pallet/Cart fixture sites in §6(a). Add the 8 `@Mock`s. Suite stays green against the baseline.
3. **Failing tests (wms-tdd-gate):** AC-1–AC-3, AC-5–AC-8, AC-10 red with the §8.1 message. AC-4 and AC-9 are green regression guards, proven only by mutation.
4. Fix A. Gate: AC-1–AC-4 and AC-6 green.
5. Fix B, the TLWS comment, and the AC-17 rewrite. Gate: AC-5, AC-7–AC-10 green; `PalletizeLockOrderProbeIT` and the location-branch probe unchanged and green.
6. The floor: §8.2; full `mvn verify` against the baseline; code review, fixing every finding including Low; docs (§6); DEV manual test (§8.3).

## 8. Testing plan

**Harness:**
- Real Postgres only; H2 renders `FOR UPDATE`.
- Extend `AbstractTruckLoadingPgFixture`, with the shape of `MobileTruckLoadingParcelMembershipIT`:
  - a raw-JDBC holder with autocommit off;
  - a single-thread worker;
  - an observer on `holderPid = ANY(pg_blocking_pids(pid))`;
  - `BlockedBackendReads.confirmedBlockedStatement` containing `unitload` and `for no key update`.
- Detection is time-boxed at 2 s, and the holder commits or rolls back **immediately** after detection. A 55P03 is a **fixture failure**, never a pass (critic Low).
- Confirm in the first IT run that `wms.tenant.lock-timeout-ms` reaches the IT tenant datasource (critic open question): a hung holder would otherwise hang the test.
- Every assertion carries `.as("…")` naming what it guards. Refusals assert the **message**, never only the type.

### 8.1 Acceptance criteria

| AC | Test | Setup → assertion | Pre-fix red |
|---|---|---|---|
| AC-1 | `StockunitServiceTransferStockDestinationTest#split_ontoGateAssignedPallet_refusedAndMintsNothing` | The gate guard throws → the message contains "is already assigned to gate"; `createUnitload`, `transferStockToUnitLoad`, `transferUnitLoadToCarrier` never invoked | `expected BusinessException but nothing was thrown` |
| AC-2 | `…#split_pallet_lockBeforeGuards_inOrder` | `InOrder`: `findByIdForUpdate(palletId)` → `assertPalletNotShipped(label, MANUAL_SPLIT)` → `assertPalletNotAssignedToGate` → `assertCanReceiveStock(locked)` (exactly once) → `createUnitload` | `wanted but not invoked: findByIdForUpdate` |
| AC-3 | `…#split_ontoClosedPallet_shippedDiagnosisWins` | The shipped guard throws → message "already shipped on closed BOL"; gate guard never invoked; nothing minted | `expected BusinessException` |
| AC-4 | `…#split_ontoNonPallet_takesNoDestinationLock` | Case destination → `findByIdForUpdate` and both BOL guards never invoked; `assertCanReceiveStock` once | green (regression guard; mutant H4) |
| AC-5 | `MobileMoveUnitloadServiceUnitTest#carrierWhole_locksDestinationThenSource_guardsAfterBoth` | `InOrder`: `findByIdForUpdate(destId)` → `findByLabelidForUpdate(src)` → `assertPalletNotAssignedToGate`. Variant: a type with `unitloadallowed=false` → no destination lock | `wanted but not invoked: findByIdForUpdate(destId)` |
| AC-5b | `…#carrierWhole_damagedAfterLock_rederivesFromLockedRow` | The plain read has the destination on L1; the locked stub returns it on Damaged → `setStockDamaged` and the `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` check fire | `wanted but not invoked: accessService.doesUserHaveAccess` |
| AC-5c | `…#selfReference_refusedBeforeAnyUnitloadReadOrLock` | `dest == source`, no Location of that name, `moveStock=false` → `FacadeException` key `CARRIER_SELF_REFERENCE`; the `locationRepository.findByName` read is allowed; `verifyNoInteractions(unitloadRepository)`. Variant `…_sameNamedLocationExists_noSelfReferenceRefusal`: a Location named like the source exists → no `CARRIER_SELF_REFERENCE`; LOCATION_WHOLE proceeds as today | `expected FacadeException CARRIER_SELF_REFERENCE but nothing was thrown`, or `verifyNoInteractions(unitloadRepository)` fails (the core is a mock in this test, so nothing throws there; critic r2 L2) |
| AC-6 | `AddToGatedPalletRaceIT#split_blocksOnHeldPallet_thenRefusedOnCommittedPosition` | The holder takes FNKU on D. The worker splits onto D → blocked by the holder. The holder INSERTs a TRUCK_LOADING position (`source_id=D`) and commits → message "is already assigned to gate"; SU amount unchanged; Case count after the watermark = 0. **Positive control** `split_ontoUnassignedPallet_mintsOneCase`: the same count query = 1 | `worker blocked by holder: expected true but worker completed` |
| AC-7 | `…#moveUl_blocksOnHeldPallet_thenRefusedOnCommittedPosition` | As AC-6 with `scanDestination(P→D)`; `P.carrierunitload_id` unchanged. **Positive control:** with no INSERT, the holder rolls back → the move completes and the carrier = D | same message |
| AC-8 | `MoveUnitloadLockOrderProbeIT#carrierArm_holdsDestinationWhileWaitingOnSource` | The holder locks P; the worker runs the carrier arm → blocked on P, with D's `xmax` = the worker's `backend_xid` (`confirmedBlockedStatementAndXid`). **Positive control:** the holder rolls back → outcome null, `carrierunitload_id = D` | `D xmax: expected worker xid but backend_xid was NULL` (asserted null-safe; architect L3) |
| AC-9 | `AddToGatedPalletRaceIT#moveUl_vsPalletize_heldSource_noDeadlock` | **Fixture (r2 L3):** D is a Pallet with an **outbound** label (palletize checks the outbound pattern before its lock) and no BOL position; P is a parcel with a customer order, not on a truck, on another Palletizing pallet. Steps, with two holders (architect M4): (1) the holder takes FNKU on P; (2) Move UL P→D starts → confirmed blocked on P; (3) palletize P→D starts → confirmed blocked **on D by Move UL's pid**, `.as("lock order: Move UL holds D while waiting on P")`; (4) the holder rolls back → Move UL commits with P's carrier = D. Palletize then completes with **no 40P01/55P03** and P still on D: an idempotent re-palletize **success** with no refusal (`MobilePalletizeWriteService` javadoc: "re-palletizing an already-palletized order onto the same pallet is a legitimate idempotent re-scan"; at most the SBDEV-3398 WARN). Assert no exception and P on D | green (regression guard). Under H3 (M-append) the **primary kill is step 3's confirmation**: palletize is blocked by the holder on P, not by Move UL on D (critic r2 L1). A `40P01` is an acceptable kill only if step 3 passes. On that path the test tears down both workers (holder rollback, worker futures cancelled and joined) |
| AC-10 | `MobileTruckLoadingParcelMembershipIT` | Unchanged and green: 3441's leave-side re-check still refuses | — |

The lock order is carried by AC-8 together with `PalletizeLockOrderProbeIT` (pallet before parcel). AC-9 proves the absence of the cycle.

### 8.2 Mutation checks (the floor)

**PIT:**
```
mvn -q test-compile && mvn org.pitest:pitest-maven:mutationCoverage \
  -DtargetClasses=net.aim_ai.wms.service.StockunitService,net.aim_ai.wms.service.mobile.MobileMoveUnitloadService \
  -DtargetTests=net.aim_ai.wms.unit.service.StockunitServiceTransferStockDestinationTest,net.aim_ai.wms.unit.service.mobile.MobileMoveUnitloadServiceUnitTest
```
- **Only these mutants gate:**
  - VoidMethodCall removals of `assertPalletNotShipped`, `assertPalletNotAssignedToGate` and `assertCanReceiveStock` in the pallet branch;
  - the negated conditionals in `lockCarrierDestinationIfJoin` (`== CARRIER_WHOLE`, `getUnitloadallowed()`) and in the self-ref check.
- Pre-existing survivors elsewhere in these 1.5k/1.3k-line classes do not gate.
- **Hand-apply each gating mutant once and record its first red message**: PIT's KILLED can come from a downstream NPE on an unstubbed mock, not from the assertion (critic M4).

**Hand mutants** (PIT does not reorder statements or drop a non-void call):
- **H1:** remove the lock → AC-2, AC-5, AC-6, AC-7 red.
- **H2:** guard before lock → AC-2, AC-5 red; AC-6/AC-7 red at the message assertion.
- **H3:** Move UL back to source-first (M-append) → AC-8 red; AC-9 red at its step-3 confirmation (`40P01` only if step 3 passes).
- **H4:** split lock above the `if (Pallet)` type check → AC-4 red ("never wanted: findByIdForUpdate").

### 8.3 Manual test (DEV `dev_wh01_om1`, wms-dev-probe; take a `snapshot.sh` first, because the split mints a Case)

Counts recorded on 2026-11-07. The Pallet filter is needed because `billoflading_position.source_id` also names parcels (critic H3: without it the counts are 11 / 411,901).

| Scenario | Environment | Precondition query → dev count | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| Split onto a gate-assigned pallet | dev | `SELECT count(DISTINCT u.id) FROM unitload u JOIN unitload_type t ON t.id=u.type_id AND t.name='Pallet' JOIN billoflading_position p ON p.source_id=u.id JOIN billoflading b ON b.id=p.billoflading_id WHERE b.state='TRUCK_LOADING';` → **4** (PM-666661 among them). Case split sources → **19,490** (analysis §7) | Web Move Stock: split 1 from a Case onto PM-666661 | develop: succeeds. Fixed: "Pallet PM-666661 is already assigned to gate…"; no Case minted; SU unchanged | |
| Split onto a CLOSED pallet | dev | Same query with `b.state='CLOSED'` → **15,890** | Split onto one of them | "…already shipped on closed BOL…" | |
| Move UL onto a gate-assigned pallet | dev | TRUCK_LOADING → **4** | Mobile: a parcel onto PM-666662 | Gate refusal (unchanged; the lock path is exercised) | |
| Happy path | dev | `SELECT count(*) FROM unitload u JOIN unitload_type t ON t.id=u.type_id AND t.name='Pallet' JOIN location l ON l.id=u.storagelocation_id WHERE l.name NOT IN ('Shipped','Nirwana','Damaged') AND NOT EXISTS (SELECT 1 FROM billoflading_position p WHERE p.source_id=u.id);` → **1,054** (positive control: the exclusion removes 12, all on `Nirwana`) | Split onto one; Move UL a parcel onto it | Both succeed; the carrier is set | |
| Restore | dev DB | — | `snapshot.sh` diff | No residue | |

**Verify script: NONE.** Each invariant this plan states is pinned by an AC above. The one cross-tenant fact (pattern disjointness) is a prerequisite query, not a code invariant.

## 9. Risks

| Risk | Mitigation |
|---|---|
| A writer waits ≤ 3 s behind scanGate, or gets a 55P03 (409). Every carrier-arm source refusal now also waits on D | Intended (decision 2); scanGate holds D for milliseconds |
| The rule now differs per arm in one method (the 3442 author avoided per-branch rules) | One named helper; a two-line javadoc rule; AC-8 pins the carrier arm, the location probe pins the rest |
| Crossed pallet-onto-pallet Move ULs (both refused by the core anyway) can 40P01 | Needs `unitloadallowed` on both ends and simultaneous crossed scans; bounded |
| `createUnitload` mints through `SequenceTransactionService` (`REQUIRES_NEW`) while D is held, so a second pool connection is open for that moment (architect L5) | Existing pattern on this path; held for one sequence fetch |
| Per-tenant data: type flags and label patterns (Hydra unchecked) | §7.1 row 1. Only `unitloadallowed=false` skips the lock (today's behaviour); a missing type row throws `EntityNotFoundException`, as the core does |

**Horizontal scalability** (the rows that are not N/A):
- row 4: long transactions get slightly longer (≤ 3 s wait);
- row 2: a momentary second connection for the mint (above);
- row 6: refusals roll back and mint nothing;
- row 8: FNKU inside `tenantTransactionManager` transactions, which works across replicas.
All other rows are No (no in-JVM state, jobs, affinity, async, cache or notifications).

**v2 constraints:** OSIV is off, and every lock and guard runs inside the existing `@Transactional(tenantTransactionManager)` methods. Jakarta `EntityManager`/`PersistenceContext`. Lock assertions are PG-only. No endpoint, SQL or metric change.

**Completeness:**
- **0** DB verified: §1, §8.3, §7.1 row 1.
- **1** Call sites: §0 by the named greps.
- **4** Concurrency: §4, AC-5–AC-9.
- **5** Multi-tenant: tenant EntityManager; per-tenant flags and patterns in §7.1.

## 10. Decisions

Nam's 8 binding decisions: [`decisions.md`](../../../../.omc/research/SBDEV-4047/decisions.md). Two notes:
- **Decision 3** ("merge in either order") is moot: 3441 is merged. This branch is off `5ed6f000` and extends its fixture.
- **Decision 8** ("no scanGate change") stands, but its stated reason, independence from 3441, has **expired**. Its substance holds on the merits: no scanGate-side check can exclude a join that commits after scanGate (§2). Only comment and doc edits touch TLWS here. Flagged for Nam, not reopened.

**ADR**
- **Decision:** at sites 1 and 2 (§0's set), lock the destination pallet (FNKU) before the source, and judge the shipped, gate and eligibility guards only on the locked row. The split gains the guards it lacked.
- **Alternatives:** see §5's table.
- **Consequences:**
  - writers can wait ≤ 3 s behind scanGate;
  - the carrier arm's first row lock is the destination;
  - classification reads move above the source lock, with an up-front self-reference refusal;
  - SBDEV-3862's D-itself Damaged window closes;
  - one new enum tag.
- **Follow-ups:**
  - P73, the closeBOL backstop;
  - R2, `ReceivingService`, kept in P72;
  - **candidate proposal (not filed, not in scope):** a scanGate PHASE D membership re-check as defence in depth, now unblocked by 3441's refusal pattern.

## 11. Review disposition

- Round 1: `owl/.omc/research/SBDEV-4047/round1-disposition.md` (reviews: `review-architect-r1.md`, `review-critic-r1.md`).
- Round 2 (final; critic APPROVE, architect SOUND-WITH-CHANGES): `review-architect-r2.md` N1 → Fix B step 0 + AC-5c; N2 → step 2 `orElseThrow` + AC-5 + §9; N3 → §6(a) + §7.2; L1 → step 2; L2 → step 4; L3 → AC-9 fixture. `review-critic-r2.md` L1 → AC-9 + §8.2 H3; L2 → AC-5c; L3 → resolved by N1 (no §9 row); L4 → resolved by N2.

## 12. TDD gate baseline (2026-11-07)

Worktree `owl/.claude/worktrees/wms2-api/SBDEV-4047`, branch `bugfix/SBDEV-4047-add-to-gate-pallet-guard-and-lock`, off `5ed6f000`. Commits: `8b4a6ea9` (scaffolding, no behaviour change: the `MANUAL_SPLIT` enum constant is the only `src/main` line), `c136b665` (failing tests). Not pushed.

- **Unit tests, re-run independently:** `StockunitServiceTransferStockDestinationTest` + `MobileMoveUnitloadServiceUnitTest`: 205 run, **7 failures, 0 errors**. Every failure is an assertion: AC-1, AC-2, AC-3, AC-5, AC-5b, AC-5c and the rewritten AC-17 pin.
- **ITs** (lane run on throwaway containers; the reusable container holds another branch's V2.2.46): `AddToGatedPalletRaceIT` 5 run, 4 failed (AC-6, AC-7, AC-7 control, AC-9). `MoveUnitloadLockOrderProbeIT` AC-8 is red for the right reason (`backend_xid` NULL). AC-6's split control is green.
- **Green by design:** AC-4, the AC-5 no-lock variants (`unitloadallowed` false and null), the AC-5c same-named-location variant, and AC-10 (3441's membership IT).
- **Lock timeout:** the IT tenant datasource is bound at 10 s (`show lock_timeout`).

**Corrections to §7.2/§8.1 found by the gate:**
1. **AC-9 is RED before the fix, not a green regression guard.** Its step 3 needs Move UL to already hold D, which only Fix B provides. The first draft passed vacuously, because palletize waiting on P also queues behind Move UL's pid. It was tightened to: Move UL `backend_xid` not null, D's `xmax` = Move UL's xid, and palletize `backend_xid` null.
2. **Fix A turns an existing test red that §6 does not list:** `StockunitServiceTransferStockDestinationTest$EligibilityIsConsulted.gateIsConsultedWithTheResolvedDestination` pins "eligibility before `findByName(Pallet)`". Fix A step 1 resolves the Pallet type first, so the executor rewrites this pin to the new order. This is an intended contract change, not a regression.
3. AC-9 drives `scanPallet` with D's existing label. The outbound-pattern check runs only on create, so it does not gate the lock.
- Full unit-suite baseline (origin/develop 5ed6f000, 2026-11-07, detached worktree): 9814 run, 0 failures, 0 errors, 1 skipped. BUILD SUCCESS.

## 13. Implementation status (2026-11-07)

- **PR:** https://github.com/SiteBossInc/wms2-api/pull/639 → `develop`. Branch `bugfix/SBDEV-4047-add-to-gate-pallet-guard-and-lock`, base origin/develop `65444c6b`, tip `ef3752ea`. Not merged.
- **Commits:** 76f43d0c scaffolding · e72e27e7 failing tests AC-1..9 · 43cc18a0 Fix A · 58ce4dfe Fix B · 830d6911 TLWS comment · 52500d4e null-safe never() matcher · 934f496b review fixes (M1, L1–L9, sec L1–L4) · 07a2c19b IT timing + stockrecord residue · 4804b88b rail recognises createNewUnitload · cff87740 N1–N4 · ef3752ea L-A/L-B javadoc.
- **Tests:** full unit suite 9855 run / 0 fail / 0 err / 1 skip on cff87740 (baseline 9814/0/0/1); ITs 9/9 (AddToGatedPalletRaceIT 5, MoveUnitloadLockOrderProbeIT 3, MobileTruckLoadingParcelMembershipIT 1). PIT: all gating mutants killed; one equivalent survivor at the deferred read (`destUl != null`).
- **Reviews:** verifier PASS; code review ×4 (last at ef3752ea: APPROVE); security PASS (L1–L4 fixed; M1 → proposal P74).
- **Open after merge:** flip the three `✓ merged(SBDEV-4047: #639 0b9704dd, 2026-11-07)` doc markers; DEV manual test plan (in the PR body); P73 / P74 await decision.

## 14. Merge and dev (2026-11-07)

- **Merged:** PR #639 as `0b9704dd` (head `ed9acafe`, base `66d57882`). Dev serves `develop-0b9704dd` (`post-merge-verify`: ALL PROVEN; develop push run 42318318335, test + build success).
- **CI fix before merge (`2a57a946`, test-only):** the first PR run failed `AddToGatedPalletRaceIT.split_ontoUnassignedPallet_mintsOneCase` (expected 1, was 0). The id-watermark count missed the minted Case, because sibling ITs insert `unitload` rows with explicit ids, which leaves `max(id)` above the sequence. Reproduced with a planted high-id row (old query 0, new 1). It now counts Case children of the fresh pallet. Independent review: APPROVE, 3 Lows with no change needed.
- **Re-grade:** merged develop `66d57882` (7 commits, no file overlap, no conflicts) as `ed9acafe`. CI on the merge: unit 9875/0/0/1, ITs 1253/0/0/23.
- **DEV manual test:** all 4 scenarios ✅ (split onto gate pallet refused with the gate message; onto a CLOSED pallet refused with the shipped diagnosis; control split onto an unassigned pallet minted exactly one Case; Move UL onto the gate pallet refused). The snapshot restore proof printed `restored` for all three snapshots. Left on dev: 3 stockrecord and 2 unitload_record audit rows, and the used label UL323323. 0 OMS messages.
- **Doc markers:** 5 `pending-merge(SBDEV-4047)` markers flipped in 4 files.
- **Next:** `archive-plan`. P73 and P74 await decision.

## Archive note (2026-11-07)

**Findings disposition:**
- Fix A, Fix B, and the CI test fix: **fixed**, in #639, merged as `0b9704dd`.
- P73 (a closeBOL backstop for a child with no position): **proposed**, register row P73.
- P74 (manual split onto an existing container skips the Damaged permission): **proposed**, register row P74.
- scanGate pre-PHASE D membership re-check: **proposed**, register row P76.
- R2, the `ReceivingService` :624 carrier race: **dropped**. It is practically unreachable, because the carrier must be at the inbound workstation or parked at PutAwayLane/EmptyPallets (analysis §3 row 6). Nam decided this on 2026-11-07.
- P72 is shipped and has moved to the register log.

> No acceptance script: the plan had none (T3 opt-in, not taken).
> Implementation worktree(s) removed 2026-11-07: wms2-api/SBDEV-4047
