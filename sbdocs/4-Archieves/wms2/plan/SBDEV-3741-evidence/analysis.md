# SBDEV-3741 — analysis (full content)

Code claims come from `origin/develop` in each sub-repo (wms2-api `60ddb320`, wms2-mobile-ui `b03b96a`, both fetched 2026-10-12). Line numbers are approximate; quoted snippets are exact.

**Docs read:**
- `wms2-function-to-docs-map.md` §9 "Order cancellation" points to `wms2-cancel-cascade-workflow.md` §11a. I read §11a in full; it says it does not cover RTS end to end.
- Reports `261012-wineco-cancelled-orders-stock-shipped.md` (where 3741 comes from: §5.3, §8 row 3) and `261012-c1wh-pending-reversals-waive.md`.
- The six memory notes you listed.

**Plans:** only SBDEV-3381 and SBDEV-3547 have plan files. 3313, 3316, 3326, 3353 and 3733 decisions live only in code comments and memory. 3733 appears only as a triage reference.

## §A Affected-sites table (plan §0)

| # | Repo · site | Change | Notes |
|---|---|---|---|
| A1 | api `json/CancellationCompleteRequest` | CHANGE | Add a nullable `String destinationLocationName`. It is a plain object with no validation, so old bodies bind it as null. |
| A2 | api `OrderCancellationController.completeReversal` | CHANGE (1 line) | Pass the new field through. Keep only the class gate `@RequiresFunction(MOBILE_UI_VIEW_CANCELLATION)`. A method-level gate "REPLACES the class default" (waive javadoc), so it would change who can do plain RTS. |
| A3 | api `CancellationReversalService.completeReversal` | CHANGE | Add a 4-argument overload and keep the 3-argument one as a delegate passing null. The 3-argument form has 47 test call sites (unit 29, IT 14+2+1, StockunitServiceParcelSourceRefusalUnitTest 1). Inside: the gate, destination checks before the FOR UPDATE read, the `transferStock` location argument, and the notes write. |
| A4 | Other production callers | NONE | `git grep "completeReversal(" -- src/main` finds only the controller plus comments. |
| A5 | `StockunitService.transferStock` | No change (§B4) | For a lane destination it takes the new-container branch. The flow-bin branch and the Damaged (D5) branch can't be reached. |
| A6 | `StockunitBusinessService.transferStockToUnitLoad` | No change | Full move: the same row is re-parented and keeps lock 0. Split: `createStockUnit` sets lock 0 and `reservedamount` 0. It refuses a locked destination location. |
| A7 | Residue re-lock block | No change, verified | It compares against `pickToUnitloadId`, never the destination (§B5). |
| A8 | `SourceContainerGuard` (3353) | No change | It judges the source container, at both layers. |
| A9 | `waiveReversal` | No change | Waive and complete both take the same FOR UPDATE lock. The waived-share logic doesn't look at the destination. |
| A10 | `WmsConstants.FunctionEnum` | CHANGE | Add `MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION`. The `ACTION_` name keeps it out of audit SET 3's `LIKE 'MOBILE_UI_VIEW_%'`. |
| A11 | Flyway V2.2.38 | CHANGE | Function row plus grants to outbound-manager and super-admin, using the V2.2.34 `WHERE NOT EXISTS` pattern. V2.2.38 is free on all 422 remote refs: the sweep found only V2.2.35–37 (that is the control). Re-sweep at gate time. |
| A12 | `UtilRestController.initDB` | CHANGE | Add `grantFunction(…RTS_CHOOSE_DESTINATION, role_outbound_manager, role_super_admin)` next to the waive line (~:432). This is the third of the three required touches. |
| A13 | `audit-access-invariants.sql` SET 9 | Optional | Add a `step6` row so the deploy report lists the new holders. |
| A14–15 | `UtilRestControllerSeedUnitTest` / `UtilRestControllerUnitTest` | New tests | Migration and initDB grant the same roles; initDB resolves the function by name. |
| A16 | `FunctionGuardArchTest` GOLDEN_MAP | Must stay unchanged | A red here means someone added an annotation to `/complete`. |
| A17 | `FunctionGuardMockMvcUnitTest` T11 | Unchanged, plus one pin | The existing check that a VIEW-only user reaches `/complete` is the "plain RTS keeps its gate" criterion. Add a row asserting no method-level gate. |
| A18 | `ActionGuardAnnotationContractUnitTest` | No change | It can't see a check written in code. Say so in the plan. |
| A19 | `OrderCancellationControllerUnitTest` | New | Body binding with and without the destination. |
| A20 | `CancellationReversalServiceUnitTest`, `CancellationReversalLockClearIntegrationTest` | New tests | See §E. Existing tests stay untouched as the default-path safety net. |
| A21 | `CancellationLogEntryDto` | Decision (§C3) | It exposes nothing from `reversal_notes` today. |
| A22 | `CancellationLogService`, pending job, finders | Exclude | They record and list pending rows; the destination only matters at completion. |
| A23 | Club-line code (`validateStockOnStagingLane`) | Exclude | It sums `getAvailableamount()` per lane, so lock-0 RTS stock is consumable by the lane's batch. You accepted that. |
| A24 | mobile `store/cancellation.js` | CHANGE | Pass the destination on every per-position request. With no destination the payload must stay exactly `{ notes, positionIds }`: leave the key out, never send null. |
| A25 | mobile `cancellationAction.vue` | CHANGE | Scan field shown when `functions.includes(...)`, same pattern as `canWaive`. Fix the "returned to its source location" wording when a destination is set. |
| A26 | mobile `pages/cancellation.vue` | No change | `resetState` rebuilds from `initialState()`, so a new store field is reset automatically. |
| A27 | mobile Jest specs | New cases | `cancellationPartialReversal`, `cancellationWaive`, the component specs, `resetState`. |
| A28 | web-ui | None | `git grep -i "reversalNotes\|reversal_notes\|cancellation/"` returns 0 hits. |

## §B Current architecture

**B1 — endpoint and gate.**
- Class gate is `MOBILE_UI_VIEW_CANCELLATION`. `/complete` has no method annotation:
  ```java
  completeReversal(customerOrderId, request.getNotes(), request.getPositionIds())
  ```
- `/waive` has a method-level gate on `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL`.

**B2 — `completeReversal`, in order.**
1. Transaction: `@Transactional("tenantTransactionManager", rollbackFor = {BusinessException, FacadeException})`.
2. Input checks: `positionIds required` and max 200.
3. Lock: `findPendingReversalsForUpdateByCustomerorderId`.
4. Pre-validate each row:
   - the SBDEV-3316 recovery save (rolled back if anything later refuses);
   - refuse a null stock unit;
   - refuse a null `pickfromlocationname` ("no source location was recorded at cancellation time") — this happens even when a destination is supplied (§F3);
   - refuse a stock unit not found;
   - 3326: refuse any lock outside {0, 100};
   - 3353 `assertStockNotInParcel`.
5. Read the waived share once.
6. Movement loop:
   - clear 100 or null to 0, then flush (the flush is load-bearing);
   - `stockunitService.transferStock(stockUnit, log.getAmountPicked(), false, log.getPickfromlocationname(), null, null, false)`;
   - residue re-lock;
   - stamp completed-at and completed-by;
   - `if (notes != null) log.setReversalNotes(notes)`.
7. `enqueueReversalCompletedIfClosed`. This fires on every call that finds the order closed, so a retry re-sends the OMS notice.

**B3 — how this codebase does conditional function checks.**
- `AccessService.doesUserHaveAccess(fn)` calls `getAllRoles(SecurityContextUtils.getUserName())` and checks membership.
- `PutawayConfigService.setSkuDestination` (~:142) throws `AccessDeniedException("Missing function …")`. Its ~:400 comment says a gate there "must be PROGRAMMATIC … never annotation-based".
- `StockunitService.transferStock` (~:592) gates on the request content (Damaged destination), but throws `BusinessException("No permission to alter damaged stock")`, i.e. 422. `MobileMoveUnitloadService` (~:383, ~:388) does the same.
- `UserController.denyUnlessUserManagementAllowed` (~:165) does the check in the controller.
- `MobileEndpointExceptionHandler` re-throws `AccessDeniedException` ("Deliberate rethrow … ExceptionTranslationFilter renders the 403"), so a mobile handler returns 403.
- The mobile loop stops on 401, 403 or no response.

**B4 — `transferStock` with a lane destination, starting from a tote at Clearing.**
1. Top of the method: the to-delete refusal, then `assertUnitloadNotParcel`. It takes the new-container path and resolves the name with `canonicalLocationName`.
2. Flow-bin branch is not taken: all lanes are `cases and pallets`. If a lane were a flow bin, this branch would call `createFixedLocationAssignment`, so §C1 refuses flow bins explicitly.
3. Whole-unit-load branch needs `restsInStorageLocation`, and the allowed set is `Set.of(BOX, PICKLOCATION, DEFAULT)` ("A Tote … never rests in a rack"). Tote and Case containers always take the new-container branch. A Default container would be moved whole, which is also true today.
4. New-container branch:
   - The D5 Damaged check can't be reached.
   - The shadow-mode container-type check finds 0 constraint rows on lanes, so it lets everything through.
   - `createUnitload(dest, defaultType, client, CODE_MANUAL_SPLIT, boxtype)` mints one new unit load per call, at lock 0 (`insertUnitload` sets `setEntityLock(0)`).
   - Then `transferStockToUnitLoad(..., ignoreLock=false, removeUnitLoadIfEmpty=true)`.
5. `transferStockToUnitLoad`:
   - `CODE_MANUAL_SPLIT` doesn't lock picking orders.
   - Lock order: source stock unit, source unit load, source location, destination unit load, destination stock unit, destination location.
   - It refuses `"Destination location=… is locked="`.
   - Full move: re-parents the row (lock stays 0). Split: `createStockUnit` with lock 0 and `reservedamount` 0.
   - A drained tote goes to Nirvana / EmptyTotes.
6. No replenishment is triggered (SBDEV-2033). A non-Damaged move sends no OMS stock message, and on-hand per SKU doesn't change.
7. N positions produce N new unit loads on the lane.

**B5 — residue re-lock.**
- Condition: `Objects.equals(residue.getUnitloadId(), pickToUnitloadId) && amount < before && > 0 && > waivedShare`. The destination never enters it.
- On WineCo the 11 tote rows arrive at lock 0, so `arrivedLocked` is false and the block does nothing there.

**B6 — SBDEV-3547.** Move Stock of a lock-100 stock unit is still refused by `transferStockToUnitLoad` (with `ignoreLock=false`) and, for Damaged, by the D5 pre-check. Neither is touched.

**B7 — adding a function needs three things.**
- The constant, near the waive constant (~:484).
- A Flyway migration like V2.2.34 (insert the row, grant outbound-manager and super-admin).
- An initDB `grantFunction` line (~:432). The comment there says "updateFunctionList has NO caller … Both are required".
- Tests to copy: `CancellationWaiveMigrationIT`, `UtilRestControllerSeedUnitTest` T14, `UtilRestControllerUnitTest` ~:249, `CancellationWaiveContractUnitTest`.

**B8 — staging lanes in code.**
- `Location.staginglane` is `boolean NOT NULL DEFAULT false`.
- `findByStaginglaneTrue` is exposed over Spring Data REST; `getAvailableStagingLanes` is not.
- Lanes belong to club batches (`CustomerorderBatch.staginglaneId`).

**B9 — mobile.**
- `complete()` sends `notes: ''`, so the server overwrites `reversal_notes` with `''` on every complete today.
- One POST per position, sequential.
- `canWaive` reads `home.functions`.
- The whole store is persisted to localStorage (SBDEV-2930).

## §C Design options

**C1 — request shape and validation order.**
- Field: `destinationLocationName`, trimmed; a blank value is refused.
- Order inside `completeReversal`, all before the FOR UPDATE read:
  1. The existing `positionIds` checks, unchanged.
  2. If a destination is given:
     - the gate, which throws `AccessDeniedException`;
     - `canonicalLocationName`, then `findByName`, else `BusinessException(MSG_TRANSFER_DESTINATION_LOCATION_NOT_FOUND)`;
     - refuse if `staginglane` is not true ("is not a staging lane — Return to Stock can only send stock to a staging lane");
     - refuse if `entity_lock` is not 0;
     - refuse a flow-bin location type;
     - optionally refuse a lane with a fixed-location assignment.
  3. Pass the resolved name to `transferStock`.
- New dependencies: `AccessService`, `LocationRepository`, `ScannedCodeResolver` (13 → 16 constructor arguments).

**C2 — gate mechanism.**

| Option | Verdict | Why |
|---|---|---|
| **G1** In-service check, 403 | **Recommended** | Holds for any caller, including a future 3733 one. The class gate stays untouched. Needs its own unit test with mutation checks: drop the check, swap the constant, invert the null guard, move it after the FOR UPDATE. |
| G2 Controller check | Possible | The service stays ungated for later callers. |
| G3 Separate route with `@RequiresFunction` | Fallback | Contradicts the decided request shape, and the method gate replaces the class gate, so VIEW would have to be listed again. |
| G4 `BusinessException` | Reject | Returns 422: the mobile loop doesn't stop and marks rows waivable. |

- Holders on WineCo PRD: 41 users have the waive function, 46 have VIEW. mcervone, who did the manual lane moves, has both.

**C3 — where the destination is recorded.**
- **R1:** append `[RTS destination: X]` to the notes, only when a destination is supplied, plus a DTO field read back from that token. No schema change. Risk: `initiateReversal` rewrites notes on every row of the order, closed rows included, so the token can be erased.
- **R2:** a new nullable column added in V2.2.38. More durable; a migration ships anyway.
- **R3:** rely on `stockrecord` only. Rejected: there's no move id to link it to the row.
- Recommendation: R1 plus a DTO field read back from the notes text; put R2 to Nam as the more durable option.

**C4 — whole tote vs per stock unit.** Decided by code: always per stock unit into a new container (§B4). Moving a tote whole is forbidden by SBDEV-3340.

**C5 — reuse seam for 3733.**
- A private `resolveDestinationName(log, override)`, so 3733 can later add its fallback there.
- A separate `validateOperatorDestination` holding the gate and the staging-lane rule, applied only to operator-supplied input.
- Record the destination whenever the operator supplied it, even if it equals the source.

## §D Compatibility, concurrency, scale

**D1 — backward compatibility.**
- A body without the field takes exactly today's code path; existing tests are the safety net.
- Old mobile builds keep working.
- New UI on an old API: risky (§F1). Deploy the API first.
- The default notes write (`''`) is unchanged, and so are the OMS payload and the GOLDEN_MAP.

**D2 — concurrency.**
- Complete and waive still serialise on the order's FOR UPDATE.
- The lane location row is locked last, in the standard order, so no new lock cycle appears.
- Club packing can take the stock: you accepted that.
- Mobile requests stay sequential.

**D3 — multi-tenant.** Everything is tenant-scoped: location reads, functions, Flyway, initDB. Nothing touches the landlord DB.

**D4 — horizontal scalability.**

| # | Concern | Verdict |
|---|---|---|
| 1 | In-JVM state | No |
| 2 | Connection pool | No |
| 3 | Scheduled jobs | No |
| 4 | Long transactions | No |
| 5 | Request affinity | No |
| 6 | Retry / idempotency | Yes, unchanged: completed rows are skipped; a replay re-sends the OMS notice by design |
| 7 | Tenant context | No |
| 8 | Locks | Yes, unchanged: the lane row becomes a new lock target |
| 9 | Cache invalidation | No (is `Location` cached? open, §F9) |
| 10 | External notifications | Unchanged (outbox) |

**D5 — v2 constraints.**

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV off | Yes |
| 2 | `tenantTransactionManager` | Yes |
| 3 | readOnly reads | N/A |
| 4 | Cache eviction | N/A |
| 5 | Jakarta namespace | Yes |
| 6 | H2 vs Postgres tests | Yes: migration test runs as a Testcontainers IT |
| 7 | BaseControllerTest | Yes |
| 8 | Metrics | No new metric; one log line instead |

## §E Acceptance-criteria candidates

1. **Default unchanged.** `transferStock` gets `pickfromlocationname` as its location argument, and the notes are written as sent. Unit test with an argument captor; existing tests stay green.
2. **Lane destination works.** Stock lands on a unit load at the lane, the tote goes to EmptyTotes, and the row closes. IT.
3. **Lock 0 at the destination,** in both the full-move and split cases (two fixtures). IT.
4. **On-hand per SKU unchanged.** IT.
5. **OMS notice sent exactly once,** on the last position only. IT counting outbox rows, plus a unit test.
6. **Non-staging destination refused** with no move, no closed row, and no committed recovery save. Unit + IT.
7. **Bad destination input refused:** unknown location, blank value, locked lane. Unit.
8. **Gate applies only with a destination.** Without the function and with a destination: `AccessDeniedException`, and the FOR UPDATE finder is never called. Without a destination: the function is never checked. Unit test with mutation checks.
9. **403 on the wire,** not 500 or 422. Controller test.
10. **Plain RTS keeps its gate.** A VIEW-only user reaches `/complete`; GOLDEN_MAP unchanged; a pin asserting no method-level gate.
11. **Function provisioned three ways.** The constant, V2.2.38 granting exactly {outbound-manager, super-admin}, initDB granting the same set, and the migration safe to run twice.
12. **SBDEV-3547 still holds:** Move Stock of a lock-100 unit to a lane or to Damaged is refused.
13. **SBDEV-3353 still holds:** a pick-to stock unit inside a Package, with a destination, is refused and nothing commits.
14. **Shared-SU residue:** two positions on one stock unit; completing one to a lane re-locks only the tote residue at 100, and the lane stock is at 0.
15. **Notes token and DTO field** are written and read back.
16. **Jest, no function:** the scan field is hidden and the payload deep-equals `{ notes, positionIds }`.
17. **Jest, with function:** every request carries the same destination, and a 403 stops the loop.
18. **Jest, reset:** the destination is cleared by `resetState`.

## §F Risks and open questions

1. **Unknown JSON fields.** Check whether `@RequestBody` ignores them under the skewed deploy (new UI, old API). If it does, stock silently returns to the source bin while the operator scanned a lane.
2. **Notes token erased.** `initiateReversal` can wipe the destination text on closed rows.
3. **Null source bin with a destination given.** Keep refusing it in 3741, or allow it? I recommend keeping the refusal and leaving it to 3733.
4. **Lanes in use.** 13 of 20 WineCo lanes hold an unfinished club batch, so RTS stock dropped there can feed another customer's run (accepted).
5. **Inventory reporting.** Not checked whether `stock_view` or OMS inventory sync treats lane stock differently.
6. **First live completes on WineCo.** RTS has never completed there. Of the 37 pending rows, 23 are refused regardless: 13 in Nirwana at lock 2, 10 in shipped Packages at lock 405.
7. **Container proliferation.** One new unit load per position on the lane.
8. **Migration number.** V2.2.38 is free today; re-sweep at gate time.
9. **Is `Location` cached?** Not verified.
10. **Which user name the gate reads.** `doesUserHaveAccess` uses `getUserName`, while the completion stamp uses `getAuthorizedName`.

## §G Alternatives (rejected)

1. **Let Move Stock take cancelled stock and close the rows.** It breaks the 3547 rule that lock 100 has exactly two exits (complete and waive), and it puts the customer-order lock into the move path, which the PO→SU deadlock-avoidance rule forbids.
2. **A separate `/complete-to-location` endpoint** (G3). Contradicts the decided request shape and duplicates the flow. Kept as a fallback.
3. **Any location as destination.** Opens flow-bin assignment, rack container constraints, Damaged (with an OMS message), and Nirwana or Shipped.
4. **Move the whole tote.** Forbidden by SBDEV-3340.
5. **Gate with `BusinessException`.** The 422 is mishandled by the mobile loop.

## DB evidence (WineCo PRD, read-only, 2026-10-12)

**DB-1 — staging lanes.** 20 lanes, StagingLane01–20.
- All: lock 0, `transferlane` false, type `cases and pallets`, area Outbound, no fixed-location assignment, no container-constraint rows.
- Unit loads per lane: 126, 35, 23, 204, 126, 76, 5, 0, 3, 1, 0, 0, 0, 0, 0, 1, 0, 0, 2, 8.

**DB-2 — lanes with an unfinished club batch.** 13 of 20, batch states 520 and 525.

**DB-3 — pending rows by where the pick-to stock is now.** 37 rows:

| Container type | Location | Lock | Rows |
|---|---|---|---|
| Default | Nirwana | 2 | 13 |
| Tote | Clearing | 0 | 11 |
| Package | Shipped | 405 | 10 |
| Case | PutAwayLane | 0 | 2 |
| Case | StagingLane05 | 0 | 1 |

**DB-4 — log totals.** 60 rows: 37 pending, 0 completed, 0 waived. `reversal_notes` is null on all 60.

**DB-5 — function holders.** Waive function 41 users, VIEW_CANCELLATION 46. Both target roles exist. mcervone holds both.

**Blind spot:** only WineCo PRD was queried. Run the DB-1 query on the other five tenant DBs before claiming lanes look the same everywhere.