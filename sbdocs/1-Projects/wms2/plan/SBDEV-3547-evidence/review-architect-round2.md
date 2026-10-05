# SBDEV-3547 — architect review, round 2 (2026-09-27)

**Verdict: SOUND-WITH-CHANGES.** All seven round-1 findings are fixed. I found no new High or Medium issues. The four new Lows are text edits to the plan only and none blocks the TDD gate.

One correction to the question you asked: the R9 drain measurement does **not** overstate the cost. In the DB, about 97% of the drained rows are on totes that last reached Clearing from a cancelled order. The plan's "upper bound" caveat is actually wrong in the other direction (N1).

**Base drift:** origin/develop is now `0ac108e2`, not `a5b36931`. The only `src/main` change since then is one line in `StockViewRepository` (SBDEV-3550). Every MMU, UnitloadService, StockunitService and rail line the plan cites is unchanged.

## F1–F7 status

| F | Status | Where addressed / checked |
|---|---|---|
| F1 | Fixed | §0 M6, §2 B3, §4 A5, §7.1 `adjustAmount_lock100_…` (RED, checks for the hint text), §4 A4 (:869/:871 moved to EXEMPT). `unitloadRepository` is injected in StockunitService (:65) |
| F2 | Fixed by construction | The D1′ check is a private method in MMU. MMU calls `.transferUnitLoadToCarrier(`, so it is inside the rail's derived scope. The rail census still reports 19 classes and 8 offenders on 0ac108e2 |
| F3 | Fixed | §4 A3, §7.5 ("2 slots briefly") |
| F4 | Fixed | §7.1 A1: the captor is on `recordForTransferUnitLoad` args 8 and 9. Checked: those are `orderNumber` and `comment` (`UnitloadRecordService:41`, called at `UnitloadBusinessService:542`) |
| F5 | Fixed | §4 B-2 `isToteType` checks `typeId == null` before `findById`; test `_toteTypeIdNull_` uses `never().findById(any())` |
| F6 | Fixed | §4 B-1: the check goes inside the existing lambda |
| F7 | Fixed | §4 B-3: the refusal comes after the To-Delete check (:583) and the child check (:590), and before the loop (:596, which calls `sendStockUnitToNirvana` at :604). The pre-run check uses `findByUnitloadIdIn` |

## New work, verified

- **D1′ call sites.** `:485` (inbound-pattern branch, under `!isMoveStock`, before `createUnitload` at :492) and `:512` (before `transferUnitLoadToCarrier` at :514) are the only places MMU puts a source onto a carrier. A new inbound pallet flows on to `:512` as well, so `:512` covers both cases and `:485` exists only to avoid leaving an orphan pallet. The other arms either relocate (`:424` → :426) or call `transferStock` (:457/:505/:519), which M1 already refuses.
- **Carrier writers across `src/main`.** I grepped both `transferUnitLoadToCarrier/Cart(` and direct `setCarrierunitloadId(` calls. None of them lets a picked tote carrying 100 stock onto a carrier:
  - `AdviceService:238` and `ReceivingService:575` handle inbound parcels.
  - `ParcelMonitorViewService:320/:322` and both palletize paths (:402, :589) resolve the order by parcel label.
  - `StockunitService:410` moves stock first with `ignoreLock=false`.
  - `MobilePickingService:1645` runs at pick start.
  - `BillofladingService:865` attaches a Package it has just created.
- **SDR.** `Unitload` and `Stockunit` are both in `SDR_WRITE_WITHDRAWN` (`RestConfiguration:441`), so `carrierunitloadId` cannot be written over HTTP.
- **R10 (truck loading).** `BillofladingPositionService.createEntity` (:140) is the only place that creates BOL positions. Its only callers are `MobileTruckLoadingWriteService:473/482/490`, which are reached only through `scanGate`. `scanGate` is guarded by `requireOutboundPalletLabel` at `MobileTruckLoadingService:167` before the write transaction opens, and `checkPallet` is guarded at :92. The plan's reachability statement holds.
- **Rail.** I ran `rail-census.py` read-only: 19 classes, 8 offenders, same allowlist-conjunct set. The B-2 shape as written is flagged, so its EXEMPT entry is live. The rail earns its place only as a recurrence check; the plan says so itself (see N3).
- **R9, and whether it is honest.** Code on develop sends a Tote to Clearing only through the cancel `sendToClearing` callers (`CustomerorderService:494/1034`, `PickingorderBusinessService:698`) or an operator relocation. `MMU:722` sends only default/Package types; an emptied Tote goes to EmptyTotes (:707). On PRD (read-only), for each drain row I looked at the tote's most recent arrival at Clearing:

| Tenant | Drain rows | Totes | Rows whose last Clearing arrival carries a CANCELED (800) order number | Totes |
|---|---|---|---|---|
| WineCo | 372 | 78 | 362 | 73 |
| c1wh | 72 | 21 | 72 | all |

  Every order number found in those arrivals resolves to state 800. So D2's measured cost is real, and the G3 floor briefing for WineCo and c1wh is justified. The last WineCo drain is 2026-09-23, three days before WineCo went live on v2, so these rows record v1-era floor habit, not v2 behaviour.

## New findings

**N1 — Low. R9's "upper bound" caveat has the wrong mechanism.**
- Evidence: `MMU:703-722` never sends a Tote to Clearing (Tote → EmptyTotes at :707), and the DB split above shows about 97% of rows are cancel-related.
- Also, `stockrecord.unitloadtype` records the **destination** unit load's type (`StockrecordService:439`). Filtering on it gives 204 rows / 43 totes, but only because it catches tote→tote moves. The plan's current-type join is the right instrument.
- Change: replace the caveat with the 362/372 and 72/72 split. Note that WineCo's rows are all before the v2 go-live. Add one line saying why the plan joins on the current type instead of filtering on `stockrecord.unitloadtype`, so nobody "corrects" the count to 204/43.

**N2 — Low. The §0 reachability census is missing some writers.**
- Evidence: the plan names only `MobilePalletizeWriteService:357` (`scanPallet`). `scanParcelBulk` (:557 → :589) resolves the order the same way (`findIdByParcelLabelId`). The plan's grep also misses direct `setCarrierunitloadId(` writers: `BillofladingService:865` and `ParcelMonitorViewService:322`.
- Change: add those three sites, add `setCarrierunitloadId(` to the stated grep, and add the SDR-withdrawn fact. All of them are already covered by the existing DB control (every order parcel is a Package, on all four tenants).

**N3 — Low. The rail pins only the literal shape of the D1′ check.**
- Evidence: I ran the script's `scan()` on two equivalent rewrites and both returned `[]`. One uses a guard with `continue`; the other uses `stream().anyMatch(...)` followed by `if (fenced && isToteType) throw`. After such a refactor the D1′ EXEMPT entry goes stale, and the obvious "fix" is to delete that line.
- Change: in §4 A4, AC-6 and §6.3 step 2, say that the two RED MMU tests (`scanDestination_carrierArm_refuses…` and `…inboundPalletArm_refuses…_beforeCreateUnitload`) are what pins D1′. The stale-entry failure only asks for a review of the change.

**N4 — Low. Housekeeping.**
- Update `base_commit` to 0ac108e2, noting that the drift touches only `StockViewRepository`.
- §4 B-2 says the type is read "at most once per call". For a Package at 100 sent to a new inbound pallet, both `:485` and `:512` run, so there are two unlocked `findById` reads per request. The cost is harmless; say "per call site" instead.

## References
- `v2/wms2-api` origin/develop `src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java` :359-365, :424-426, :485-492, :505-519, :703-722
- `.../service/UnitloadBusinessService.java` :503, :542; `.../service/UnitloadRecordService.java` :41
- `.../service/mobile/MobilePalletizeWriteService.java` :352-357, :557-589
- `.../service/BillofladingService.java` :865; `.../service/ParcelMonitorViewService.java` :320-322; `.../service/StockunitService.java` :410
- `.../service/BillofladingPositionService.java` :140; `.../service/mobile/MobileTruckLoadingService.java` :92, :167
- `.../RestConfiguration.java` :441 (SDR_WRITE_WITHDRAWN includes Stockunit and Unitload)
- `.../service/StockrecordService.java` :407-439 (records the destination type)
- `.../service/UnitloadService.java` :583-604, :427-436
- `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3547-evidence/rail-census.py` (run read-only; output matches §4 A4)
- PRD read-only: wsl-wineco-prd and c1wh-shipitez-prd, joining `stockrecord` MANUAL_SPLIT rows from Clearing to `unitload_record` arrivals at Clearing to `customerorder.state`
