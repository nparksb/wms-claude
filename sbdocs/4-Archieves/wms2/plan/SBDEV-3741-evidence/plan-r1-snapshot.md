---
title: "SBDEV-3741 — Return to Stock: let the operator choose a staging-lane destination"
ticket: "SBDEV-3741"
ticket_url: "https://app.clickup.com/t/868mgde8k"
type: "feature"
priority: ""
status: "pending approval"
tier: T3
db_verified: true
project: [wms2]
version: "v2"
requester: "Nam Park"
created: "2026-10-12"
updated: "2026-10-12"
related:
  - "[[SBDEV-3741-evidence/analysis]]"
  - "[[SBDEV-3547]]"
  - "[[SBDEV-3381]]"
  - "[[261012-wineco-cancelled-orders-stock-shipped]]"
  - "[[261012-c1wh-pending-reversals-waive]]"
tags:
  - plan
---

# SBDEV-3741 — Return to Stock: let the operator choose a staging-lane destination

**Ticket:** [SBDEV-3741](https://app.clickup.com/t/868mgde8k) · **Tier:** T3 (new authz function + Flyway migration + two repos) · **Version:** v2
**Evidence:** [analysis.md](SBDEV-3741-evidence/analysis.md). Code claims are from `origin/develop`: wms2-api `60ddb320`, wms2-mobile-ui `b03b96a` (fetched 2026-10-12). Snippets are quoted so they can be grepped. Line numbers are approximate.

---

## 0. Affected sites

Full table with rationale: analysis §A. Each row is covered (C) or excluded (X).

| # | Repo · site | C/X | Where in this plan |
|---|---|---|---|
| A1 | api `json/CancellationCompleteRequest` adds nullable `destinationLocationName` | C | §3.1 |
| A2 | api `OrderCancellationController.completeReversal` passes the field through; keeps class gate only | C | §3.1, §3.3 |
| A3 | api `CancellationReversalService.completeReversal` gets a 4-arg overload; the 3-arg form delegates with `null` | C | §3.2 |
| A4 | other production callers of `completeReversal(` | X | `git grep "completeReversal(" -- src/main` finds only the controller plus comments. Blind spot: reflective or SpEL callers, of which none are known |
| A5–A7 | `transferStock`, `transferStockToUnitLoad`, residue re-lock | X | No change. Analysis §B4/§B5. Covered by AC-3 and AC-14 |
| A8 | `SourceContainerGuard` (3353) | X | Judges the source container. AC-13 |
| A9 | `waiveReversal` | X | Shares the FOR UPDATE lock and ignores the destination |
| A10 | `WmsConstants.FunctionEnum` adds `MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION` | C | §3.3 |
| A11 | Flyway `V2.2.38` (provisional): function row, grants, and the new column | C | §3.3, §3.4 |
| A12 | `UtilRestController.initDB` `grantFunction` line | C | §3.3 |
| A13 | `audit-access-invariants.sql` SET 9 `step6` row | C (optional) | §5 Phase 1 |
| A14–A18 | Seed/initDB unit tests, GOLDEN_MAP, `FunctionGuardMockMvcUnitTest` T11 pin, `ActionGuardAnnotationContractUnitTest` | C | §7 (A16 must stay unchanged; A18 cannot see a programmatic check, see §7 blind spots) |
| A19–A20 | `OrderCancellationControllerUnitTest`, service unit test and IT | C | §7 |
| A21 | `CancellationLogEntryDto` adds `reversalDestinationLocation` | C | §3.4 |
| A22 | `CancellationLogService`, pending job, finders | X | They list pending rows; the destination only matters at completion |
| A23 | club-line `validateStockOnStagingLane` | X | Lock-0 RTS stock can be consumed by the lane's batch. Accepted (D1) |
| A24 | mobile `store/cancellation.js` | C | §3.5 |
| A25 | mobile `components/cancellation/cancellationAction.vue` | C | §3.5 |
| A26 | mobile `pages/cancellation.vue` | X | `resetState` rebuilds from `initialState()`. AC-18 pins it |
| A27 | mobile Jest specs | C | §7 |
| A28 | wms2-web-ui | X | `git grep -i "reversalNotes\|reversal_notes\|cancellation/"` gives 0 hits. Blind spot: dynamic URL building |

## 1. Problem

On WineCo PRD between 2026-09-25 and 2026-10-12 there were **3 cancel-and-re-create events covering 43 units**. In each, an order was cancelled after picking and re-created right away (source: `261012-wineco-cancelled-orders-stock-shipped.md` §5.3, §8 row 3). The picked stock was physically needed on a staging lane for the re-created order.

Today's fallbacks:
- Return to Stock (RTS) sends the stock back to the **source bin** (`log.getPickfromlocationname()`) and the re-created order re-picks it. That is a wasted round trip.
- The operator used to work around this with a hand Move Stock to the lane. **SBDEV-3547 now refuses that move**, because lock 100 has exactly two exits: complete and waive.

What's missing is a third option inside the sanctioned exit: complete the reversal **to a staging lane the operator scans**.

Scope limit (F6): of the 37 pending rows on WineCo PRD, **23 are refused regardless of destination**: 13 in Nirwana at lock 2, and 10 in shipped Packages at lock 405 (refused by 3326/3353). Source: analysis DB-3. This feature does **not** help those 23. **SBDEV-3740 (waive) does.** It applies to the 11 Clearing tote rows and the 3 Case rows.

## 2. Current architecture

See analysis §B, which is not restated here. The anchors:
- **B1:** the class gate is `MOBILE_UI_VIEW_CANCELLATION`, and `/complete` has no method annotation.
- **B2:** order inside `completeReversal`: input checks, then `findPendingReversalsForUpdateByCustomerorderId`, then pre-validation (3316 recovery save, null-source refusal, 3326 lock set, 3353), then the movement loop calling `transferStock(stockUnit, log.getAmountPicked(), false, log.getPickfromlocationname(), null, null, false)`, then the residue re-lock and stamps, then `enqueueReversalCompletedIfClosed`.
- **B4:** a lane destination takes the new-container branch. One new unit load is created per call at lock 0. The flow-bin branch and the Damaged (D5) branch cannot be reached.
- **B7:** adding a function needs three touches.
- **B9:** the mobile client sends one POST per position and `notes: ''`.

DB evidence (WineCo PRD, read-only): see analysis DB-1..DB-5.
- 20 lanes. All are lock 0, type `cases and pallets`, no fixed-location assignment, no container constraints.
- 13 of the 20 hold an unfinished club batch.
- Blind spot: only WineCo PRD was queried. Phase 1 prerequisite P1 re-runs DB-1 on the other five tenant DBs.

## 3. Design

### 3.1 Request and controller (A1, A2)
- `CancellationCompleteRequest` gains `private String destinationLocationName;` (nullable, no annotations).
- The controller call becomes `completeReversal(customerOrderId, request.getNotes(), request.getPositionIds(), request.getDestinationLocationName())`.
- **No** method-level `@RequiresFunction`. A method gate *replaces* the class default (waive javadoc), so adding one would change who can run plain RTS.

### 3.2 Service (A3): order of checks, all before the FOR UPDATE read
```
completeReversal(id, notes, positionIds)                       → delegates (…, null)
completeReversal(id, notes, positionIds, destinationLocationName):
  1. existing positionIds checks (unchanged)
  2. Location dest = (destinationLocationName == null) ? null : validateOperatorDestination(destinationLocationName)
  3. findPendingReversalsForUpdateByCustomerorderId(...)        ← unchanged from here on, except:
  4. loop: transferStock(su, amt, false, resolveDestinationName(log, dest), null, null, false)
           if (dest != null) log.setReversalDestinationLocation(dest.getName())
```

`validateOperatorDestination(raw)` is private. It runs only when `raw != null`:
1. **Gate (D3):** `if (!accessService.doesUserHaveAnyAccess(SecurityContextUtils.getAuthorizedName(), MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION.name())) throw new AccessDeniedException("Missing function " + …)`.
2. Trim. If blank, throw `BusinessException`.
3. Resolve the name: `scannedCodeResolver.canonicalLocationName(..)`, then **`locationRepository.findByName(..)`**. If nothing is found, throw `BusinessException(MSG_TRANSFER_DESTINATION_LOCATION_NOT_FOUND)`.
4. Refuse when `!loc.isStaginglane()`, with the message "… is not a staging lane — Return to Stock can only send stock to a staging lane".
5. Refuse a lane whose lock is not 0. Mirror the downstream predicate in `StockunitBusinessService` (`lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED` → `"Destination location=… is locked="`) and treat a null lock as refused. `location.entity_lock` is a nullable `integer` per the V2.2.00 DDL.
6. Refuse a location type equal to `STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN` (D2). This keeps `createFixedLocationAssignment` unreachable.

`resolveDestinationName(log, dest)` is private: `dest != null ? dest.getName() : log.getPickfromlocationname()`. This is the seam SBDEV-3733 will extend (analysis §C5). Keeping it separate from validation means a future system-chosen fallback skips the operator gate.

**Positions taken:**

- **F3 (null `pickfromlocationname` with a destination): keep refusing.**
  - The pre-validation refusal ("no source location was recorded at cancellation time") stays ahead of any destination logic.
  - Relaxing it changes the meaning of a row whose initiation was already defective. That belongs to 3733's fallback design, and the seam above is where it will go.
  - AC-7b pins the refusal so 3733 has to change it deliberately.

- **F9 (cache): Location *is* cached, through `LocationService.getByName`, but this design does not use it.**
  - `LocationService.getByName` is `@Cacheable(value = "locations", key = "…cacheKey(…getCurrentTenant()) + ':' + #name")`. Its result is a detached entity, so `staginglane` and `entity_lock` can be stale.
  - The validation therefore reads **`locationRepository.findByName`**, the same uncached call `transferStock` uses (`Location destinationLocation = locationRepository.findByName(locationName)`).
  - The pre-check is a fast-fail only. The authoritative lock check is the downstream one inside `transferStockToUnitLoad`, under the row lock.
  - Nothing here writes Location, so there is nothing to evict. Scalability row 9 is "No".

- **F10 (identity): the gate uses `SecurityContextUtils.getAuthorizedName()` with `AccessService.doesUserHaveAnyAccess(username, fn)`, not `doesUserHaveAccess(fn)`.**
  - `doesUserHaveAccess` reads `getUserName()`, which falls back to the JWT `sub` when `preferred_username` is absent.
  - `FunctionGuardInterceptor.currentUsername()` returns `authentication.getName()`. The `completed_by` stamp (`final String operator = SecurityContextUtils.getAuthorizedName();`) uses the same accessor.
  - Using it means the gate, the class gate and the audit stamp all judge the same principal. This follows the javadoc on `getAuthorizedName` (SBDEV-3381 security review F4/N2).

- **F7 (containers): accept one new unit load per position.**
  - Consolidating would need `isTransferToExistingContainer=true` plus a target label. That risks merging into a club batch's own unit load on a busy lane (13 of 20 lanes are in use), and mobile sends one POST per position, so there is no per-submission container to reuse.
  - Lanes already hold up to 204 unit loads (DB-1), and demand is 3 events per fortnight.
  - Revisit only if a follow-up observes proliferation.

- **F5 (inventory): no change to on-hand totals.**
  - `stock_view` (V2.2.00, `CREATE OR REPLACE VIEW public.stock_view`) buckets by `su.entity_lock` and `ul.entity_lock` only. It joins `stockunit` and `unitload` and has **no location or `staginglane` predicate**.
  - Method: read the view DDL, and confirmed V2.2.07, V2.2.08 and V2.2.33 do not redefine it. Blind spot: onboarding `V1.2.04__utc_recreate_views.sql` (the v1→v2 path) was not read.
  - The OMS inventory-sync treatment of lane stock was **not verified**, so it is manual row M6.

### 3.3 Function provisioning (D3, A10–A12): three touches
1. Add the constant `MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION` next to `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL`. The `ACTION_` prefix keeps it out of audit SET 3's `LIKE 'MOBILE_UI_VIEW_%'`.
2. Flyway `V2.2.38__rts_choose_destination.sql`: insert the function row and grant it to `role_outbound_manager` and `role_super_admin`, using V2.2.34's `WHERE NOT EXISTS` idempotent pattern.
3. Add an `initDB` `grantFunction(...RTS_CHOOSE_DESTINATION, role_outbound_manager, role_super_admin)` line next to the waive line. The comment there reads: "updateFunctionList has NO caller … Both are required".

Plain RTS keeps `MOBILE_UI_VIEW_CANCELLATION` (46 WineCo PRD holders, DB-5).

### 3.4 Recording the destination (D5, A21)
- In the same `V2.2.38`: `ALTER TABLE customerorder_cancellation_log ADD COLUMN IF NOT EXISTS reversal_destination_location character varying(255);` The type matches `location.name` and `pickfromlocationname`.
- Map it on `CustomerorderCancellationLog`. Expose it as `CancellationLogEntryDto.reversalDestinationLocation` (null when not used).
- Write it **only** when the operator supplied a destination, even if that destination equals the source.
- `reversal_notes` handling is unchanged: the `if (notes != null)` write stays as it is. This avoids the R1 risk that `initiateReversal` erases a note token.

### 3.5 Mobile (A24, A25)
- Add `rtsDestination: ''` to `initialState()`.
- `complete()` builds the payload as `{ notes, positionIds }` and adds `destinationLocationName` **only when it is non-blank**. It never sends `null` or `''`.
- The same destination goes on every per-position POST.
- The existing loop already stops on 401, 403 or no response (§B3). A 403 surfaces through the existing error path.
- `cancellationAction.vue`:
  - computed `canChooseDestination = functions.includes('MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION')`, the same pattern as `canWaive`;
  - an optional scan field shown only when the user has that function;
  - the confirmation text reads "returned to staging lane X" when a destination is set, and keeps "returned to its source location" otherwise.
- **This visibility check is also the version-skew mitigation.** The function row exists only after the API migration has run. Under `FAIL_ON_UNKNOWN_PROPERTIES=false` (settled), an old API would silently drop the field.

## 4. File change summary

| Repo | File | Change |
|---|---|---|
| api | `json/CancellationCompleteRequest.java` | Modify: add the field |
| api | `controller/mobile/OrderCancellationController.java` | Modify: pass the field through (1 line) |
| api | `service/CancellationReversalService.java` | Modify: add the overload, `validateOperatorDestination`, `resolveDestinationName`, the column write; new constructor deps `AccessService`, `LocationRepository`, `ScannedCodeResolver` (if not already present) |
| api | `WmsConstants.java` | Modify: add the FunctionEnum constant |
| api | `model/CustomerorderCancellationLog.java`, `json/CancellationLogEntryDto.java` (+ its mapper) | Modify: add the column field and the DTO field |
| api | `resources/db/migration/V2.2.38__rts_choose_destination.sql` | Add |
| api | `controller/rest/UtilRestController.java` (`initDB`) | Modify: add the grant line |
| api | `audit-access-invariants.sql` SET 9 | Modify (optional): `step6` row |
| api | tests listed in §7 | Add / modify |
| mobile | `store/cancellation.js`, `components/cancellation/cancellationAction.vue` | Modify |
| mobile | `test/store/cancellationRtsDestination.spec.js`, `test/components/cancellation-rts-destination.spec.js` | Add |

## 5. Phased plan

### 5.1 Prerequisites

| # | Prerequisite | Action | Notes |
|---|---|---|---|
| 1 | Database state | Re-run the DB-1 lane query on the other five tenant DBs (census = six) | If any tenant has a flow-bin or locked lane, the refusals handle it; record what is found |
| 2 | Feature flags / sysprops | N/A | Gated by function, not by a toggle |
| 3 | Config / env | N/A | `FAIL_ON_UNKNOWN_PROPERTIES=false` is existing behaviour (settled) |
| 4 | Deploy order | **API (with V2.2.38) before mobile, on every environment** | §8 |
| 5 | Data migration | `V2.2.38` only. **Re-sweep all remote branches for V2.2.38 at gate time** (422 refs were clean on 2026-10-12, control V2.2.35–37 found) | Runs on every boot (SBDEV-2801) |
| 6 | External systems | N/A | The OMS payload is unchanged |
| 7 | Access | New function granted to outbound-manager and super-admin via Flyway and initDB | Group membership decides who gets the scan field |
| 8 | Monitoring | One INFO log line per destination-completion: `customerOrderId`, `positionId`, `destination`, `operator` | No new metric; low frequency (§7 constraint 5) |

### 5.2 Phase 1: wms2-api
- **Branch:** `feature/SBDEV-3741-rts-choose-destination`. Worktree `.claude/worktrees/wms2-api/SBDEV-3741` off a freshly fetched `origin/develop`.
- **Goal:** §3.1–§3.4 plus the tests in §7.1.
- **Order of work:** failing tests first (`wms-tdd-gate`), then the migration and constant, the service, the controller, and initDB.
- **Risk:** Medium. It adds an authz surface and a schema change. The default path is byte-identical.
- **Effort:** about 1.5 days.

### 5.3 Phase 2: wms2-mobile-ui
- **Branch:** same name. Worktree `.claude/worktrees/wms2-mobile-ui/SBDEV-3741`.
- **Goal:** §3.5 plus the tests in §7.2.
- **Risk:** Low.
- **Effort:** about 0.5 day.
- Merge only after Phase 1 is on the target environment.

## 6. Backward compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| `/complete` body without the field | moves to source bin | identical code path (`resolveDestinationName` returns the source) | none; the 47 existing call sites still use the 3-arg form |
| Who can do plain RTS | VIEW_CANCELLATION | unchanged; GOLDEN_MAP unchanged | none |
| Old mobile on new API | works | works; field absent means null | none |
| New mobile on old API | n/a | scan hidden, because the function row does not exist yet | mitigated by §3.5; risk exists only if the migration ran but the code was rolled back (§8) |
| Schema | — | one nullable column | additive; `hibernate validate` only checks mapped columns |
| Error shapes | 422 `BusinessException` | adds 403 `AccessDeniedException` on the destination path only | the mobile loop already stops on 403 |

**What does NOT change:**
- the OMS reversal-completed payload, and the fact that it fires on every call that finds the order closed;
- the residue re-lock condition, which compares against `pickToUnitloadId`, never the destination;
- the 3316, 3326 and 3353 pre-validation;
- `waiveReversal`;
- the refusal of a lock-100 hand move under SBDEV-3547;
- the `reversal_notes` write;
- web-ui;
- `pages/cancellation.vue`.

## 7. Testing

### 7.1 API: acceptance criteria mapped to tests
`CRSUT` = `CancellationReversalServiceUnitTest`. `CRDIT` = new `CancellationReversalDestinationIntegrationTest` (Testcontainers PG, sibling of `CancellationReversalLockClearIntegrationTest`). The existing reversal tests are not edited; they are the default-path safety net.

| AC | Observable criterion | Test |
|---|---|---|
| 1 | No destination: `transferStock` receives `pickfromlocationname`, notes are written as sent, column stays null | `CRSUT.completeReversal_noDestination_usesSourceBin_andLeavesDestinationColumnNull` (argument captor) |
| 2 | Lane destination: stock is on a unit load at the lane, the tote is at EmptyTotes, the row is closed | `CRDIT.toLane_fullMove_landsOnLane_toteDrained_rowClosed` |
| 3 | Lock 0 at the destination in both the full-move and split cases, with `reservedamount` 0 on split | `CRDIT.toLane_fullMove_lockZero`, `CRDIT.toLane_split_lockZero_reservedZero` |
| 4 | On-hand per SKU is unchanged | `CRDIT.toLane_onHandPerSkuUnchanged` |
| 5 | OMS notice once, on the last position only | `CRDIT.toLane_twoPositions_oneReversalCompletedOutboxRow` + `CRSUT.completeReversal_destination_enqueueOnlyWhenClosed` |
| 6 | Non-staging destination refused: no move, no closed row, recovery save rolled back | `CRSUT.destinationNotStagingLane_refused_noTransfer` + `CRDIT.toNonStagingLocation_refused_nothingCommitted` |
| 7 | Unknown, blank, locked lane (including null lock) and flow-bin each refused; (7b) null source with a destination still refused | `CRSUT.destinationUnknown_refused`, `…Blank_refused`, `…LockedLane_refused`, `…NullLock_refused`, `…FlowBin_refused`, `…NullPickfrom_withDestination_stillRefused` |
| 8 | Gate applies only with a destination. Without the function: `AccessDeniedException`, and the FOR UPDATE finder is `never()` called. Without a destination: `accessService` is never called | `CRSUT.destinationWithoutFunction_accessDenied_beforeForUpdateRead`, `CRSUT.noDestination_neverChecksFunction` |
| 8b | Gate judges `getAuthorizedName()`. Fixture: a JWT whose `authentication.getName()` is "alice" and which has no `preferred_username` (`sub` = UUID) | `CRSUT.gate_usesAuthorizedName_notSub` |
| 8c | Holding the waive function does not grant the destination | `CRSUT.holdsWaiveOnly_withDestination_accessDenied` (vary the fixture) |
| 9 | `AccessDeniedException` propagates out of the handler (not mapped to 422/500); the destination binds; an absent field binds as null | `OrderCancellationControllerUnitTest.complete_bindsDestination`, `…_absentDestination_isNull`, `…_accessDenied_propagates` + the existing `MobileEndpointExceptionHandlerUnitTest` rethrow; the literal 403 is checked by manual row M3 |
| 10 | Plain RTS keeps its gate: a VIEW-only user reaches `/complete`; no method-level `@RequiresFunction` on `completeReversal`; GOLDEN_MAP unchanged | existing `FunctionGuardMockMvcUnitTest` T11 + new `…T11b_completeHasNoMethodLevelGate`; `FunctionGuardArchTest` unchanged and green |
| 11 | Function provisioned three ways: constant; V2.2.38 grants exactly {outbound-manager, super-admin} and is safe to run twice; initDB grants the same set and resolves by name; column exists and is nullable | `CancellationRtsDestinationMigrationIT` (copy of `CancellationWaiveMigrationIT`), `UtilRestControllerSeedUnitTest` new T, `UtilRestControllerUnitTest` new grant row |
| 12 | SBDEV-3547 still holds: Move Stock of a lock-100 unit to a lane is refused | `CRDIT.moveStock_lock100ToStagingLane_stillRefused` |
| 13 | SBDEV-3353 still holds: a pick-to SU inside a Package, with a destination, is refused and nothing commits | `CancellationReversalParcelSourceIntegrationTest.withDestination_parcelSource_refused` |
| 14 | Shared SU: completing one of two positions to a lane re-locks only the tote residue at 100; the lane stock is lock 0 | `CRDIT.sharedStockunit_residueRelocked100_laneStockZero` |
| 15 | Column written only when a destination is supplied, including when it equals the source; read back on the DTO | `CRDIT.toLane_recordsDestinationColumn` + `CancellationLogEntryDtoSerializationTest.reversalDestinationLocation_serialised` |

**Mutation checks (floor; each must turn the named test red, then revert):**
- **M-a** Delete the gate call → AC-8 red.
- **M-b** Swap the constant to `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL` → AC-8c red.
- **M-c** Invert the null guard (gate when `== null`) → `noDestination_neverChecksFunction` red.
- **M-d** Move validation after the FOR UPDATE read → AC-8 `never()` red.
- **M-e** Swap `getAuthorizedName` for `getUserName` / `doesUserHaveAccess` → AC-8b red.
- **M-f** Drop the `staginglane` check → AC-6 red.
- **M-g** Pass `log.getPickfromlocationname()` unconditionally → AC-2 and AC-15 red.
- **M-h** Write the column unconditionally → AC-1 red.

**Blind spots:**
- `ActionGuardAnnotationContractUnitTest` and `FunctionGuardArchTest` see annotations only. The programmatic gate is invisible to them, so AC-8 is its only guard.
- `standaloneSetup` lacks `ExceptionTranslationFilter`, so no unit test sees the literal HTTP 403 (manual row M3).

**Verify script: none.** Every invariant above is JUnit- or Jest-observable. The one cross-repo invariant (the scan is shown only when the function exists, so deploy the API first) is pinned by AC-16 plus §8 ordering. A grep row would add nothing a test does not already mutation-check.

### 7.2 Mobile: Jest

| AC | Criterion | Test |
|---|---|---|
| 16 | Without the function: scan field hidden, and the payload deep-equals `{ notes, positionIds }` (no `destinationLocationName` key) | `cancellation-rts-destination.spec.js` "hides scan without function"; `cancellationRtsDestination.spec.js` "omits key when blank" |
| 17 | With the function: every per-position request carries the same destination; a 403 on request 1 stops the loop with no further POSTs | `cancellationRtsDestination.spec.js` "sends destination on every position", "stops on 403" |
| 18 | `resetState` clears `rtsDestination` | `cancellationRtsDestination.spec.js` "resetState clears destination" |

Existing `cancellationPartialReversal`, `cancellationWaive` and `cancellationErrorSurface` specs stay green and unchanged. Mutation check: always send the key → AC-16 red; read `canWaive` instead → AC-16 red.

### 7.3 Manual test plan

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| M1 | Happy path | wineco dev | outbound-manager: cancel a picked order, open RTS, scan `StagingLane0x`, Complete | Stock on a new UL at the lane, lock 0; tote at EmptyTotes; `reversal_destination_location` set; one OMS notice | |
| M2 | Plain RTS by a VIEW-only user | dev | User without the new function: Complete | No scan field; stock to source bin; column null | |
| M3 | 403 on the wire | dev | curl `/complete` with `destinationLocationName` as a VIEW-only user | HTTP 403 (not 422/500); nothing moved | |
| M4 | Non-lane / locked lane | dev | Scan `PutAwayLane`; lock a lane and scan it | 422 with the staging-lane / locked message; row still pending | |
| M5 | Lane consumed by club packing | dev | Complete to a lane with an open batch for the same SKU | Lane stock available to the batch (accepted, D1) | |
| M6 | Inventory reporting (F5) | dev + OMS dev | Compare `stock_view` totals and the OMS inventory for the SKU before and after M1 | Totals unchanged; OMS shows no delta. **Unverified in code; this row is the check** | |
| M7 | Migration | dev DB | `SELECT … FROM function WHERE name='MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION'` + role grants; `\d customerorder_cancellation_log` | 1 function, exactly 2 roles; nullable varchar(255) column | |

### 7.4 Horizontal scalability

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | No | No new caches or static state; the uncached repo read is deliberate (F9) |
| 2 | Connection pool | No | Adds one `getAllRoles` and one location read in the existing transaction |
| 3 | Scheduled jobs | No | — |
| 4 | Long transactions | No | Two extra indexed reads before the lock |
| 5 | Request affinity | No | Stateless |
| 6 | Retry / idempotency | Yes, unchanged | Completed rows are skipped by the FOR UPDATE finder; a replay re-sends the OMS notice by design |
| 7 | Tenant context | No | Synchronous, tenant-scoped |
| 8 | Locks | Yes | The lane location becomes a lock target, taken last in the standard order (§B4.5), so no new cycle; complete and waive still serialise on the order |
| 9 | Cache invalidation | No | Location is read uncached and not written |
| 10 | External notifications | Unchanged | Outbox, after commit |

### 7.5 v2 constraints

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV off | Yes: all reads are inside the existing `@Transactional` |
| 2 | `tenantTransactionManager` | Yes: the existing annotation on `completeReversal` covers the overload, which must carry the same annotation or be the annotated method |
| 3 | readOnly | N/A: write path |
| 4 | Cache eviction | N/A: Location is not written (F9) |
| 5 | Metrics | No: low-frequency path; one INFO line instead (§5.1 row 8) |
| 6 | Jakarta | Yes: `org.springframework.security.access.AccessDeniedException`; no `javax` |
| 7 | H2 vs PG | Yes: migration and the CRDIT tests run on Testcontainers PG |
| 8 | Controller test | Yes: `OrderCancellationControllerUnitTest` (a `BaseControllerUnitTest` subclass) |

## 8. Rollout
1. Phase 1 PR into `develop`. Merging deploys to dev and runs V2.2.38.
2. Confirm M7 on dev, then run M1–M6.
3. Phase 2 PR into `develop` only after the dev API carries the build. Check `actuator/info` build time; beware the `:develop` tag race.
4. Release, UAT and PRD promotion is done by devops; the same order applies on every environment: **API first, mobile second.**

**Rollback:**
- Revert **mobile first**. If the API alone is reverted, the function row and grants remain, so a new mobile build would show the scan and the old API would silently drop the field. Stock would go to the source bin while the operator believes it went to the lane.
- If the API must be reverted while mobile stays, delete the role grants for the new function on that tenant first.
- The column is harmless if left in place.

## 9. Alternatives

| Option | Why rejected |
|---|---|
| Let Move Stock take lock-100 stock and close the rows | Breaks SBDEV-3547's two-exit rule and puts the customer-order lock into the move path (PO→SU deadlock-avoidance rule) |
| Separate `/complete-to-location` with method `@RequiresFunction` (G3) | Contradicts D1's request shape; a method gate replaces the class gate, so VIEW would have to be re-listed; duplicates the flow. Kept as a fallback |
| Gate in the controller (G2) | Leaves the service open to a future 3733 caller |
| Gate via `BusinessException` (G4) | Returns 422; the mobile loop does not stop and marks rows waivable |
| Any location as destination | Opens flow-bin assignment, rack constraints, Damaged (with an OMS message), Nirwana and Shipped |
| Record in `reversal_notes` (R1) | `initiateReversal` rewrites notes on every row, so the token can be erased; D5 chose a column |

## 10. Resolved decisions and open questions

**Resolved (Nam, 2026-10-12; do not reopen):**
- **D1:** optional destination on Complete. Stock lands at lock 0, **not** reserved to the re-created order. Club packing may consume it for any order (accepted).
- **D2:** staging lanes only. Locked lanes and flow-bin types are refused.
- **D3:** new function `MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION` granted to outbound-manager and super-admin. Plain RTS keeps the class gate. In-service programmatic check, 403, only with a destination, before the FOR UPDATE read. Three touches.
- **D4:** one destination per submission.
- **D5:** new nullable column `reversal_destination_location` in the same migration, mapped and on the DTO, written only when supplied. Not in notes.
- **Out of scope:** re-create detection and reservation; SBDEV-3733. The seam (`resolveDestinationName`, `validateOperatorDestination`) is kept for it.
- **Settled:** unknown JSON fields are ignored. Mitigation is function-gated UI visibility plus API-first deploy, pinned by AC-16.

**Planner positions (§3.2):**
- F3: keep refusing.
- F7: accept one UL per position.
- F9: use the uncached repository.
- F10: use `getAuthorizedName` + `doesUserHaveAnyAccess`.
- F5: totals unchanged by `stock_view` DDL; OMS sync goes to M6.
- F6: this feature does not help the 23 rows at lock 2 / 405; SBDEV-3740 does.

**Open:**
- [ ] Final Flyway number: re-sweep all remote branches at gate time.
- [ ] P1: lane shape on the other five tenant DBs.
- [ ] M6 outcome: if OMS inventory treats lane stock differently, escalate (mid-flight trigger 1).
- [ ] Optional A13 `step6` audit row: include or not (default include).
