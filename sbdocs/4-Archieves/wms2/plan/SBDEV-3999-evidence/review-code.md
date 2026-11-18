head: 3186cff5

# SBDEV-3999 — independent code review (review lane)

- Worktree: `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3999`, branch `fix/SBDEV-3999-fla-bin-departure-guard`, head `3186cff5`, base `origin/develop` `bcd20905` (merge-base confirmed).
- Instruments: `git diff origin/develop...HEAD`, `git grep` on the worktree, targeted reads, read-only SQL on wsl-wineco-prd / nywh-hydra-prd / c1wh-shipitez-prd. Mvn NOT run (suite in flight); lsp_diagnostics not run (no compile evidence of my own — compile/test verdict belongs to the running suite).
- Reviewer did not author any of this change.

## Verdict: COMMENT (approve-able; no High at HIGH confidence)

0 High · 1 Medium · 8 Low. The guard is correct for its spec, correctly placed, and I found no legitimate flow it newly refuses.

## Stage 1 — spec compliance

| Spec item | Status | Evidence |
|---|---|---|
| Refuse when UL is an FLA's container AND source = that FLA's bin AND dest differs | Met | `UnitloadBusinessService.refuseFixedAssignmentBinDeparture`: `sourceLocationId.equals(destinationLocation.getId())` early return; `findByAssignedunitloadId(unitload.getId())` + `Objects.equals(ownFla.get().getAssignedlocationId(), sourceLocationId)` |
| Allow-list `CODE_MOVE_FIX_ASSIGNMENT`, `CODE_DELETE_FIX_ASSIGNMENT` | Met | `FLA_BIN_DEPARTURE_ALLOWED_CODES`; null-guarded before `Set.of(..).contains` (which NPEs on null) |
| Stranded container (off its bin) still retirable by BOL build-truck | Met | source = lane ≠ bin → no refusal; unit pin `..._whenFlaContainerIsAlreadyStranded` |
| Foreign ULs on an FLA bin still move | Met | keyed on container id, not bin; pin `..._whenUnitLoadIsNotTheFlaContainer` |
| Bulk delete refuses whole batch in pre-scan | Met | `UnitLoadController.bulkDeleteContainer` `fixedAssignmentContainers` list thrown before the delete loop |
| UNIQUE columns | Verified | `V2.2.00__base_v2_schema.sql`: `uk_9fquk8dxneipre4peebi9pacj UNIQUE (assignedunitload_id)`, `uk_qakwvmdhdymic54v3dgie46wa UNIQUE (assignedlocation_id)`; no later migration drops them (`git grep` on the constraint names → only V2.2.00 and the v1-onboarding schema) |

## Caller census (does any legitimate flow get refused?)

Axis: `git grep -n "transferUnitLoadToLocation(\|sendToNirvana(\|relocateEmptiedContainer(\|sendToClearing(" -- src/main` on the worktree. Each site read.

| Caller | Can the subject be an FLA container on its bin, leaving? | Outcome |
|---|---|---|
| `FixLocationAssignmentService.java:171` move | yes | allow-listed `CODE_MOVE_FIX_ASSIGNMENT`; container moved before `setAssignedlocationId` (read :171-175) |
| `FixLocationAssignmentService.java:360` delete | yes | allow-listed; `sendToNirvana` before `deleteById` (:360-365); IT pin |
| `StockunitService.java:901` on-hold | yes | `location = findById(stockUnitLoad.getStoragelocationId())` (:858) → self-move → early return; unit pin |
| `StockunitService.java:690` web Move Stock container arm | no | `relocatesWholeUnitLoad(..., flaOpt.isPresent(), ...)` requires `!flaAtContainerLocation` |
| `MobileMoveUnitloadService.java:618/1053-1072` | no | already refused upstream on FLA alone (`:452` "Cannot move fixed assigned unit load") |
| `MobileCycleCountService.java:254/538` | no | `!fixAssignmentOpt.isPresent()` before `sendToNirvana` |
| `StockunitBusinessService.java:505/527` → `relocateEmptiedContainer` | no | FLA source forces split branch (`:429` `|| fixLocationAssignment != null`) and `:520` `fixLocationAssignment == null &&` — FLA container never drains |
| `PickingorderBusinessService.java:1380` | no | relocates the carrier pallet; bins refuse carriers (`CARRIER_NOT_ON_FIXLOC`) |
| `BillofladingService.java:996` build-truck emptied lane ULs | only if a lane carries an FLA | PRD: every FLA is on `flowbin` — WineCo 1592, Hydra 140, c1wh 910 (query below). Stranded case allowed by design |
| `UnitloadService.java:819` manual removal (single / recursive delete) | yes | now refused — intended. `deleteUnitLoad`/`deleteUnitLoadRecursive` are `@Transactional(rollbackFor=BusinessException)` and OMS STOCK_UPDATE is `sendAfterCommit`, so the stock already sent to Nirwana in :812 rolls back. See L1 for the message |
| `GoodsReceiptPositionService.java:233` | in principle | WineCo PRD: 0 `goodsreceiptposition` rows whose `unitload_id` is an FLA container |
| Receiving / putaway / truck-loading / picking tote / packaging / clearing callers | no | subjects are new ULs, totes, parcels, pallets |

Behavioural cross-check (365-day history, label-joined to current FLA containers, `fromlocation` = FLA bin, `tolocation` differs):
- WineCo PRD: `DELETE_FIX_ASSIGNMENT` 3665, `<null>` 2 (the incident, latest 2026-10-09). Nothing else.
- Hydra PRD: `DELETE_FIX_ASSIGNMENT` 10. c1wh PRD: `DELETE_FIX_ASSIGNMENT` 457.
- Blind spot: label-joined, so it misses moves after which the label changed (`MOVE_FIX_ASSIGNMENT` relabels to the destination name) — that code is allow-listed anyway.

Refusal order / exception type: the guard is a pure read placed before the BLOCK_REALIGN pickingorder locks and the destination `LockReads.forUpdate`, so it adds no lock and changes no lock order. The only observable change is that an FLA container headed for a locked destination now gets `BusinessException` instead of `FacadeException("STORAGELOCATION_LOCKED")` — both were refusals, and `RestExceptionHandler` maps `BusinessException` to 422 with `ex.getMessage()`. No caller distinguishes the two for this subject. The message embeds only `labelid` (operator data), not exception text — no SBDEV-3993-class leak. `BusinessException(String)` routes through the `placeholder` key like every other call site.

## Findings

### [MEDIUM] Sibling: the delete pre-run's existing FLA guard has queried the wrong column since the initial checkin
File: `src/main/java/net/aim_ai/wms/service/UnitloadService.java:583` (pre-existing, not in diff) and `src/main/java/net/aim_ai/wms/repo/jpa/FixLocationAssignmentRepository.java:65`
Confidence: HIGH
```java
List<Long> unitLoadIdList = unitLoadList.stream().map(tmpUnitLoad -> tmpUnitLoad.getId())...
List<FixLocationAssignment> fixedLocationAssignments = fixLocationAssignmentRepository.findByAssignedlocationIdIn(unitLoadIdList);
...
throw new BusinessException("Can not delete. Fix assignment exists for " + collect);
```
```java
List<FixLocationAssignment> findByAssignedlocationIdIn(@Param("unloadIdlist") List<Long> unloadIdlist);
```
Issue: the guard meant to stop deleting an FLA's container passes **unit-load ids** to a finder derived on **`assignedlocation_id`** (the param name `unloadIdlist` gives the intent away). It is dead (refuses only by id collision) and can falsely refuse an unrelated container whose id equals some FLA bin's location id. `git log -S` puts it at `a685e07b initial checkin`. PRD collisions today: 0 on WineCo, Hydra and c1wh, so no live false refusals. This is exactly the defect class SBDEV-3999 fixes. The diff works around it by adding a third FLA predicate (`isFixedAssignmentContainerOnItsBin`) and leaving the broken one next to it, so a reader of `deleteUnitLoadRecursivePreRun` still believes delete is guarded there.
Fix (sub-T3 → this ticket): replace the check with `findByAssignedunitloadIdIn` (new derived finder) filtered by the on-bin predicate, or call `isFixedAssignmentContainerOnItsBin` for each collected UL. That gives `/deleteContainer` and `/deleteContainerRecursive` an up-front refusal worded for a delete (see L1). Keep the on-bin filter so a stranded container stays deletable. Then remove or rename `findByAssignedlocationIdIn` and update the ~8 `UnitloadServiceUnitTest` stubs (`:866-1136`) that mock it with `anyList()`. Those stubs can't catch the column mix-up today.

### [LOW] Single and recursive delete of an FLA container answer with a "move" message
File: `UnitloadBusinessService.java` (new guard) reached via `UnitloadService.java:819` `sendToNirvana(unitLoad, CODE_MANUAL_REMOVAL, ...)`
Confidence: HIGH
```java
throw new BusinessException("Cannot move fixed assigned unit load " + unitload.getLabelid()
    + " off its fixed location. Move or delete the fixed assignment instead.");
```
Issue: `/deleteContainer` and `/deleteContainerRecursive` hit only the central guard. The operator clicked Delete and is told they "cannot move" it. Bulk says "Nothing was deleted: fixed assignment container(s) on their location: … Delete the fixed assignment instead." So one action gets two different wordings depending on the endpoint. There is also no test on either single endpoint.
Fix: fixing the Medium gives those endpoints a delete-worded pre-check. Otherwise, make the guard text neutral ("…cannot leave its fixed location…"). Add one controller/IT test for `/deleteContainer` on an FLA container.

### [LOW] Unit fixture's id collision lets a column-swap mutant survive the unit tests
File: `src/test/java/net/aim_ai/wms/unit/service/UnitloadBusinessServiceUnitTest.java` (Sbdev3999 nest, `fla.setAssignedlocationId(1L); fla.setAssignedunitloadId(1L);`, UL 1L on location 1L)
Confidence: HIGH (reasoned mutant, not executed)
Issue: the mutant `Objects.equals(ownFla.get().getAssignedunitloadId(), sourceLocationId)` survives every test in the nest. On the refuse tests it compares 1 to 1. On the stranded pin it compares 1 to 2, which allows the move, which is what that pin expects. Only `FixLocationAssignmentServiceIT` (real, distinct ids) kills it. The field-keyed fake itself is sound: each finder is keyed on its own column of the live `fla`, so editing `fla` stays consistent. The problem is the shared fixture ids. This is the same UL-id/location-id confusion as the Medium.
Fix: in the nest, put the UL on a location id different from its own id (for example UL 1L on bin 10L, `fla(bin=10L, ul=1L)`), or add one refuse case with distinct ids.

### [LOW] Nothing pins "refused before any lock"
File: `UnitloadBusinessServiceUnitTest.java` `transferUnitLoadToLocation_shouldRefuse_whenFlaContainerLeavesItsBin`
Confidence: MEDIUM
Issue: the parameter set includes `CODE_MANUAL_TRANSFER` / `CODE_TRANSFER` (BLOCK_REALIGN codes), but the test asserts only `never().save`. Moving the guard below `lockOwningPickingorders` or the destination `findByIdForUpdate` stays green, even though the javadoc and the commit treat the placement as deliberate.
Fix: add `verify(pickLineRealignmentService, never()).lockOwningPickingorders(any())` and `verify(locationRepository, never()).findByIdForUpdate(anyLong())` (the second needs an `ignoreLock=false` case).

### [LOW] Guard decides on the caller's snapshot of the source location
File: `UnitloadBusinessService.java` `Long storagelocationId = unitload.getStoragelocationId();` → `refuseFixedAssignmentBinDeparture(unitload, storagelocationId, ...)`
Confidence: MEDIUM
Issue: `processTransfer` re-reads the row (`findById(staleUnitload.getId())`), but the guard uses the caller-supplied instance, which may be detached and stale (controllers outside a transaction, see the SBDEV-3341 F1 note in `StockunitService`). A container that a concurrent FLA move just took off or put on the bin can be judged on the old location. The pre-existing destination checks have the same shape and the window is small.
Fix: optional. Read `storagelocationId` from a `findById` inside the method, or accept it and say so in the javadoc.

### [LOW] Null-safety asymmetry between the two predicates
File: `UnitloadBusinessService.java` `fixLocationAssignmentRepository.findByAssignedunitloadId(unitload.getId())` vs `UnitloadService.isFixedAssignmentContainerOnItsBin` (`unitLoad.getId() == null` → false)
Confidence: MEDIUM
Issue: a derived finder given `null` compiles to `assignedunitload_id IS NULL`. A transient UL with a non-null `storagelocationId` would match any FLA without a container on that bin, and would throw `IncorrectResultSizeDataAccessException` if there were several. PRD WineCo has 0 FLAs with a null container or bin, and every current caller passes a persisted UL, so this is latent only.
Fix: `if (unitload.getId() == null) return;` alongside the `sourceLocationId == null` check, to match the UnitloadService twin.

### [LOW] Bulk delete reports the two refusal lists one round-trip at a time
File: `src/main/java/net/aim_ai/wms/controller/UnitLoadController.java:174-181`
Confidence: HIGH
```java
if (!alreadyToDelete.isEmpty()) { throw new BusinessException("Nothing was deleted: already To Delete ..."); }
if (!fixedAssignmentContainers.isEmpty()) { throw new BusinessException("Nothing was deleted: fixed assignment container(s) ..."); }
```
Issue: the `else if` means a To-Delete id is never also checked as FLA (correct). A batch holding both kinds reports only the To-Delete list, and the operator learns about the FLA containers on the retry. The labels are consistent: `originalLabel` vs `getLabelid` match for a non-To-Delete UL. The pre-scan reads outside any transaction, so a race can still produce a partial batch. That is backstopped by the central guard inside each `deleteUnitLoad` and is the same shape as the existing To-Delete pre-scan.
Fix: optional. Build one message with both lists.

### [LOW] IT: new block inserted between `deleteCommitted`'s javadoc and the method
File: `src/test/java/net/aim_ai/wms/service/FixLocationAssignmentServiceIT.java:489-500`
Confidence: HIGH
Issue: the `/** Child-first delete of everything the committed SBDEV-3128 fixtures created … */` javadoc now sits directly above the SBDEV-3999 section and so documents `@Autowired private UnitloadBusinessService unitloadBusinessService;`. `deleteCommitted` (now `:551`) has lost its doc. The `@Autowired` field also lands mid-class instead of with the other injections.
Fix: move the SBDEV-3999 block (and the field, up to the field block) above that javadoc.

### [LOW] Javadoc precision
Confidence: HIGH (each claim checked as stated)
- `refuseFixedAssignmentBinDeparture`: "Covers transferUnitLoadToLocation only. Carrier/cart moves, SDR Unitload writes and the BOL bulk SQL transfers do not pass through here." **Accurate.** `transferUnitLoadToCarrier` goes straight to `processTransfer` (`:504-507`). BOL bulk SQL is at `BillofladingService.java:665`/`:1699`. The carrier gap is unreachable today: the 7 `transferUnitLoadToCarrier` callers move new ULs or parcels, or are FLA-guarded upstream (`MobileMoveUnitloadService:452`).
- `FLA_BIN_DEPARTURE_ALLOWED_CODES`: move and delete ordering, and the on-hold self-move, are all **accurate** (read at `FixLocationAssignmentService:171-175`, `:360-365`, `StockunitService:858/:901`).
- `UnitloadService.isFixedAssignmentContainerOnItsBin`: "Same predicate as UnitloadBusinessService's bin-departure guard" is **near-equivalent, not identical**. The guard also exempts allow-listed codes and same-location moves and lacks the id-null check. Suggest "the same container-on-its-bin test".

## Open Questions (low confidence, not blocking)
- None at High severity. If a tenant ever configures an FLA on a transfer lane, a lane FLA container that empties would now refuse inside build-truck's `relocateEmptiedContainer` loop and roll back the BOL run, where today it is retired. Today: 0 such FLAs on WineCo, Hydra and c1wh PRD (all on `flowbin`). nywh-shipitez was not queried.

## Positive observations
- The predicate is narrow (container AND bin), with a written reason for each half. That keeps BOL build-truck able to clean up stranded containers and leaves foreign-UL moves alone.
- `activityCode != null &&` before `Set.of(...).contains` avoids the known `Set.of().contains(null)` NPE trap, and a test (the null-activity-code refuse) kills its removal.
- Bulk delete refuses up front because the endpoint has no outer transaction, matching the SBDEV-3500 To-Delete pre-scan pattern.
- The pins are meaningful against the realistic mutants. Bin-only keying is killed by the foreign pin, UL-only keying by the stranded pin, dropping the allow-list by the allow-list pin, and dropping the same-location check by the on-hold pin. The real-PG IT covers the allow-listed FLA delete end to end.
- The message is consistent with the existing mobile refusal ("Cannot move fixed assigned unit load …", `MobileMoveUnitloadService:452`).

## Recommendation
COMMENT. Mergeable as is. I'd fix the Medium on this ticket: it is the same defect class, one file plus its test stubs, and it also resolves L1. The Lows are cheap; per house rule address them in the same pass (fixture ids, lock pin, IT javadoc placement, id-null check, message wording).
