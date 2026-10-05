head: ee40d348

# SBDEV-3353 — P3 conformance verification (T3 lane)

- Tree: `.claude/worktrees/wms2-api/SBDEV-3353-security`, detached at `ee40d348`. Base `5fa9bef0` (origin/develop). `git status --short` was empty before and after every run. Nothing in the tree was edited; the mutant ran in a scratch copy (`git archive`).
- Date 2026-09-24. `pgrep -fl "surefire|failsafe"` was checked before every Maven run. One peer run (`SBDEV-3353-review`, unit lane) showed up after the full suite; I waited for it to exit before the IT, gate and mutant runs.
- Spec: ClickUp SBDEV-3353 (description ACs plus the 4 comments: TRIAGE, DECISION, re-tier/fix bullets, sizing/escalation), Nam's 2026-09-24 decisions as given in the brief, and the evidence files in this folder.

## Verdict

**PASS, with 1 record gap to close before merge (not a code blocker)** and 4 Low findings.

- The code builds what was decided: refuse at source, keyed on type only, on exactly the six routes decided, with `Package` out of `TYPES_THAT_REST_IN_A_STORAGE_LOCATION`, and `handleTruckOffLoading` left alone.
- Fresh evidence: compile exit 0, full suite **7111 / 0 / 0 / 1**, RTS ITs **10 / 0 / 0 / 0**, gate commit **17 red** against its parent, mutant **16 red**.
- **Record gap:** the per-tenant sizing table on the ticket reads back through the ClickUp API as the literal `undefined`. I re-measured the numbers (below) and they agree with the comment's prose, but the ticket does not currently carry readable numbers.

## Fresh evidence (all run by me)

| Check | Result | Command | Output |
|---|---|---|---|
| Compile | pass | `mvn -o -ntp clean compile` | exit 0; 5 `[WARNING]` (same count P1/P2 reported, all in untouched files) |
| Full suite | pass | `mvn -o -ntp clean test` | **Tests run: 7111, Failures: 0, Errors: 0, Skipped: 1**, BUILD SUCCESS. The one skip is `TenantPoolEndpointSecurityTest` (pre-existing). |
| Baseline comparison | pass | baseline.md: 978b3a14 → 7022/0/0/1 | Failures 0→0, errors 0→0, skipped 1→1. The +89 is SBDEV-3490 (in the rebased base 5fa9bef0) plus this branch's tests. It matches the branch's reported 7111 exactly. |
| RTS ITs | pass | `mvn -o -ntp verify -Dit.test='CancellationReversalParcelSourceIntegrationTest,CancellationReversalLockClearIntegrationTest' -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` | ParcelSource **2/0/0/0**, LockClear **8/0/0/0**, total 10, BUILD SUCCESS. Non-zero counts confirmed. |
| Gate red-first | pass | scratch `git archive 5c3e0609`, gate lane from tdd-gate-baseline.md | **247 run, 17 failures, 0 errors**. 16 are "no SBDEV-3353 refusal was raised" and 1 is "Expecting value to be false but was true" (the set test). No NPE or stubbing error. |
| Mutant (mine) | pass (killed) | scratch copy of ee40d348 with `StockunitService.java:347` guard call commented out; lane `SourceContainerGuardUnitTest,StockunitServiceParcelSourceRefusalUnitTest,CancellationReversalServiceUnitTest,MobileTransferOrderServiceUnitTest,MobileMoveUnitloadServiceUnitTest,MobilePutAwayServiceUnitTest` | **257 run, 16 failures**, 0 errors. 14 distinct tests (2 parameterized), including every `transferStock_shouldRefuse_*` arm, the re-read L1 test, the N1 lock-read test, and the three label tests. |
| Placeholders | pass | `git diff 5fa9bef0..ee40d348 \| grep '^+' ` for TODO/FIXME/@Disabled/assume | 0 hits |

**Name trap:** the brief named the IT `CancellationReversalParcelRefusalIntegrationTest`. No class by that name exists. The real one is `CancellationReversalParcelSourceIntegrationTest` (`src/test/java/net/aim_ai/wms/integration/service/CancellationReversalParcelSourceIntegrationTest.java:88`). With the brief's name, `-Dit.test` would have matched nothing for that class.

**Mutant note:** with the `transferStock` guard removed, `StockunitServiceParcelSourceRefusalUnitTest.completeReversal_shouldRefuse_whenThePickToStockSitsInAParcel` stays green. That is correct: RTS's own pre-validate guard (`CancellationReversalService.java:288`) still refuses. Deleting that pre-check is P1's mutant, and it was reported red.

## Guard call sites vs the covered-route list (1:1)

`git grep` of `SourceContainerGuard.` in `src/main` at ee40d348 finds exactly **6 call sites**:

| # | Call site | Route (decision) | Reached from |
|---|---|---|---|
| 1 | `StockunitService.java:347` `assertUnitloadNotParcel(sourceUnitloadId, …)`, before `if (isTransferToExistingContainer)` | Web Move Stock, both endpoints; RTS second layer | `StockUnitController:156` (`/transferStock`), `:270` (`/bulkTransferStock`), `CancellationReversalService:378` |
| 2 | `StockunitService.java:811` `assertStockNotInParcel(…)` in `setLockDamaged`, below the lock switch and the amount checks, before the first write | Web Transfer to Damaged, both endpoints | `StockUnitController:553` (`/transferToDamaged`), `:595` (`/bulkTransferToDamaged`); plus `ReturnAdviceAutoReceiveService:1003`, which only ever passes a Case (p1-fixes H1 row) |
| 3 | `CancellationReversalService.java:288`, end of the atomic pre-validate loop, before any lock clear | RTS | `completeReversal` |
| 4 | `MobileTransferOrderService.java:396`, below the lane checks and the "No stock required" return, above `amountLeft` | Mobile Transfer | `transferStock` |
| 5 | `MobileMoveUnitloadService.java:636`, inside `if (stockUnits.size() > 0)`, immediately before `transferStockToUnitLoad` | Mobile Move Unit Load, stock-move path | private `transferStock` |
| 6 | `MobilePutAwayService.java:552`, top of `case STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN` | Mobile putaway flow-bin drain | `storeBoxOnLocation` |

All 7 decided routes (Move Stock ×2 endpoints, RTS, mobile Transfer, mobile Move UL stock-move, Transfer to Damaged ×2 endpoints, putaway flow-bin drain) map to a site. No site is outside the list. `handleTruckOffLoading` (`MobileMoveUnitloadService:505`) has no guard, as decided.

Cross-check of every other drain primitive caller (`transferStockToUnitLoad` and `moveStockToNewDamagedContainer`): `BillofladingService:1075/1094`, `CustomerorderService:646` (packing), `ClubLineOrderProcessor:197`, `PickingorderBusinessService:1150` (`confirmPick`) and `MobileReplenishService:631` are system flows. None of them takes an operator-chosen parcel source, and none of them is in the decided scope. `moveStockToNewDamagedContainer` has a single caller, `StockunitService:822` (behind site 2).

## Acceptance criteria (ticket), interpreted under the DECISION

| # | Criterion | Interpretation | Status | Evidence |
|---|---|---|---|---|
| 1 | Decision on emptied-parcel disposition, recorded before implementation | Decision = refuse at source | **VERIFIED** | ClickUp comment "DECISION (Nam, 2026-09-24) — AC #1: emptied-parcel disposition = refuse at source", timestamp 1790225750777. That is before the re-tier/fix comment (1790226223121). The gate commit's parent is `5fa9bef0`, and the gate commit touches `src/test` only (`git show --stat 5c3e0609`: 7 test files). |
| 2 | Moving the last SU out of a parcel leaves no dangling `customerorder.parcel_id` / `billoflading_position.source_id` | Satisfied by refusal: nothing is emptied, so no reference can dangle | **VERIFIED** (on the 6 routes) | Every refusal test calls `verifyNothingWasWritten()`, which checks `never()` on `transferStockToUnitLoad`, `transferUnitLoadToLocation`, `transferUnitLoadToCarrier`, `createUnitload` and `createFixedLocationAssignment` (`StockunitServiceParcelSourceRefusalUnitTest:407-415`). The RTS IT re-reads in a new tx: `unitload_id` is still the parcel and the lock is 100. |
| 3 | A parcel on an open BOL is not silently detached from its carrier pallet | Satisfied for **stock** moves by refusal. **Not** satisfied for **whole-parcel relocation**. | **PARTIAL, by decision** | Refusals check `never().transferUnitLoadToCarrier/…ToLocation`. But `UnitloadBusinessService.java:333` `unitload.setCarrierunitloadId(null)` is still reachable for a whole Package through `MobileMoveUnitloadService:392` (whole-UL relocation), putaway's non-flow-bin arms, and Move UL → Damaged. That is deferred to [868m9914u](https://app.clickup.com/t/868m9914u), per Nam. This AC is only met once that ticket lands. |
| 4 | Test covering last-SU-on-a-parcel for a rack destination | Refusal test on both arms the rack case can take | **VERIFIED** | `transferStock_shouldRefuse_whenFullAmountOfParcelStockMovesToARack` (whole-UL arm) and `…_whenFullAmountOfParcelStockTakesTheSplitArm` (split arm after the set change). Both were red at 5c3e0609 and are green at ee40d348. My mutant turns both red. |
| 5 | Per-tenant sizing of the reachable population before the change ships | Live = Package SU with `entity_lock <> 405` | **PARTIAL (record gap)** | See "Sizing" below. The numbers exist and I re-measured them. The ticket's table is unreadable through the API (`undefined`). |
| 6 | Failing test first, mutation-checked | Gate red for the right reason against its parent; every new guard line mutation-killed | **VERIFIED** | Gate: 17/247 red, all assertion failures, at 5c3e0609 (parent 5fa9bef0). My mutant: 16 red. PIT claims (p1-fixes, p2-fixes): SourceContainerGuard 11/11 killed; every removed-call on the 6 sites killed. I re-ran one mutant, not PIT. |
| 7 | Full suite compared against the known baseline | Failures/errors vs 978b3a14 | **VERIFIED** | 7111/0/0/1 vs 7022/0/0/1. Same F/E/S. |

## Nam's decisions (2026-09-24)

| Decision | Status | Evidence |
|---|---|---|
| Refuse at source | **VERIFIED** | The guard throws `BusinessException(MSG_TRANSFER_SOURCE_IS_PARCEL, label-or-id)` before any write on all 6 sites (table above). No new `relocateEmptiedContainer` case: `UnitloadBusinessService.java` changes only a comment (`git diff --stat`: 2 lines). |
| Type-only: no shipped test, no CANCELED exemption | **VERIFIED** | `SourceContainerGuard.judge`: `if (WmsConstants.UNIT_LOAD_TYPE_PACKAGE.equals(type.getName())) throw …`. `git grep` of `entityLock\|CANCEL\|SHIPPED\|405` in the guard's code lines: 0. `transferStock_shouldRefuse_whenShippedParcelStockMovesToDamaged` pins the lock-405 case as refused. |
| Web Move Stock (both endpoints) | **VERIFIED** | Site 1; `/transferStock` and `/bulkTransferStock` both call `stockunitService.transferStock`. |
| RTS | **VERIFIED** | Sites 3 + 1. Unit `completeReversal_shouldRefuseBeforeTheLockClear_…`; IT `aReversalOutOfAParcelIsRefusedAndLeavesTheLockAt100` 2/2 green, with a Case control that writes exactly 1 outbox row. |
| Mobile Transfer | **VERIFIED** | Site 4; `MobileTransferOrderServiceUnitTest$Sbdev3353ParcelSource` refusals ×5 (4 arms + re-read), plus Case controls. |
| Mobile Move Unit Load stock-move path | **VERIFIED** | Site 5; `scanDestination_shouldRefuse_whenMoveStockDrainsAParcel`, `…IntoAFixedAssignedUnitLoad`, `…IntoAFlowBinLocation`. |
| Web Transfer to Damaged (both endpoints) | **VERIFIED** | Site 2; `setLockDamaged_shouldRefuse_whenTheStockSitsInAParcel` and `…ReReadRow…`; N4 pin `setLockDamaged_shouldKeepTheLockMessage_…` ×3. |
| Mobile putaway flow-bin drain | **VERIFIED** | Site 6; `storeBoxOnLocation_shouldRefuse_whenAParcelWouldBeDrainedIntoAFlowBin`, plus a scope pin that the whole-relocation arms still relocate. |
| NOT handleTruckOffLoading | **VERIFIED** | No guard in `handleTruckOffLoading`/`…NoClear` (`MobileMoveUnitloadService:505-562`). |
| Whole-parcel relocation deferred to 868m9914u | **VERIFIED (deferred)** | Not guarded; the comments cite 868m9914u (`MobilePutAwayService:551`, `UnitloadService` javadoc). |
| Package removed from `TYPES_THAT_REST_IN_A_STORAGE_LOCATION` | **VERIFIED** | ee40d348 `UnitloadService.java:733-737` = {BOX, PICKLOCATION, DEFAULT}. At 5fa9bef0 `:716-721` it also had `UNIT_LOAD_TYPE_PACKAGE`. Pinned by `restsInStorageLocation_shouldBeFalse_whenTheContainerIsAPackage` (red at gate). |

## Sizing (AC 5): what is recorded, and what is missing

- **On the ticket:** comment 90110272910995, "Per-tenant sizing (AC), measured 2026-09-24". Its table body comes back from `clickup_get_task_comments` as the literal text `undefined`. The prose survives: "The live column is non-zero on 4 tenants", "No production exposure on Hydra PRD", and "blocks no inbound hub-and-spoke parcel". **The per-tenant numbers themselves cannot be read off the ticket.** The table may still render in the ClickUp UI, but I cannot confirm that. It should be re-posted as plain text.
- **On disk:** the evidence folder has live numbers for only 2 tenants (`p1-security-review.md`: Hydra PRD `[]`, WineCo UAT 63+15+1), plus per-tenant `unitload_type` counts for 6. There is no file with the 4-tenant table.
- **Re-measured by me** (read-only; `stockunit ⋈ unitload ⋈ unitload_type WHERE name='Package'`; live = `coalesce(s.entity_lock,-1) <> 405`; "with order parcel" = `EXISTS customerorder c WHERE c.parcel_id = u.id`):

| Tenant (MCP) | Package SUs total | Live SUs | Live parcels | Live SUs on an order parcel |
|---|---|---|---|---|
| Hydra PRD (`wms2-hydra`) | 491 | **0** | 0 | 0 |
| WineCo UAT (`wsl-wineco-uat`) | 1,677,563 | **79** | 28 | 79 |
| Hydra UAT (`nywh-hydra-uat`) | 17,869 | **1** | 1 | 1 |
| ShipItEZ NY UAT (`nywh-shipitez-uat`) | 6,692 | **0** | 0 | 0 |
| ShipItEZ c1 UAT (`c1wh-shipitez-uat`) | 337,600 | **4,014** | 3,896 | 4,014 |
| WineCo DEV (`wms2-wineco-dev`) | 1,395,559 | **2,863** | 1,372 | 2,863 |

  This agrees with the comment's prose: 4 tenants non-zero, Hydra PRD 0, and live = on-an-order-parcel on every tenant, so no hub-and-spoke parcel is refused today. It also agrees with WineCo UAT's 79/28 in the re-tier comment. The first query on each UAT/DEV server dropped ("server closed the connection"), the known idle drop; the retry succeeded.
- **To close:** re-post this table (or the original) as a plain-text comment on SBDEV-3353, or save it as a file in this folder.

## Gaps / findings

- **[Record] Sizing table unreadable on the ticket.** Risk: medium (the AC is "before the change ships"). Fix: re-post it as plain text (table above).
- **[Low] Stale sibling copy of the N5 wording.** `StockunitService.java:330-331` still says "RTS also checks in its own pre-validate … so a refused reversal writes nothing". N5 corrected the `CancellationReversalService` copy to "COMMITS nothing" but missed this one. Fix: reword it the same way.
- **[Low] False evidence claim: the ITs run on H2, not Postgres.** `p2-fixes.md` says the RTS ITs "confirm the new JPQL projection resolves the type id and the label on real Postgres". `BaseRollbackIntegrationTest:36` is `jdbc:h2:mem:rollback_tenant;…MODE=PostgreSQL`, and my IT log shows only `H2Dialect`. `implementation.md` says H2 correctly. The JPQL is portable, so the practical risk is low, but the claim is wrong. Fix: correct p2-fixes (append a correction, as N3 did).
- **[Low] `ee40d348` has had no independent code-review lane.** `p2-rereview.md` graded `69de9e8e`. This lane is conformance and ran the tests and one mutant, but it did not line-review the N1/N4 fix commit for defects. Fix: a scoped re-review of `69de9e8e..ee40d348`, or accept it explicitly.
- **[Low, known, by decision] Residuals stay open outside this ticket:** whole-parcel relocation, including the carrier detach at `UnitloadBusinessService:333` (868m9914u, AC 3 partial); `adjustAmount` (named in the `UnitloadService` javadoc; no decision from Nam yet); the L1 check-then-act window (accepted); Move UL flow-bin LOCATION arm's `createFixedLocationAssignment` running before the guard (rolled back by `rollbackFor`, per p1-fixes).
- **[Info] Mutant coverage:** I re-ran one hand mutant (site 1). The PIT figures for sites 2–6 are the branch's claim, which I did not re-run; P1/P2 report each site's removed-call mutant as KILLED.

## Recommendation

**APPROVE for PR once the sizing table is re-posted readably on the ticket.** Fix the StockunitService:331 wording and the p2-fixes H2/Postgres claim in the same pass; they are Lows, and the standing rule is to fix Lows too. The code conforms to every decision, and every AC the refusal design can satisfy is backed by fresh green runs, a red gate and a killed mutant. AC 3 is only partly met, by the documented deferral to 868m9914u.
