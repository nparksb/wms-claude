**Verdict: SOUND-WITH-CHANGES.** 12 of the Critic's 14 items landed correctly. Item 4 (the waive-aware restore) is right in intent but its wording can be implemented so that it silently changes nothing. Item 8 (mobile) claims an operator message that the code never shows. The new three-state `toteState` rests on real code, but its OFF state lets `stockReturned=true` through for stock sitting in a parcel. The planned T18/T22 fixtures can't produce either the ON state or an outbox row. Everything was checked against wms2-api `origin/develop` d9be4188, wms2-mobile-ui `origin/develop` 5e99732, and read-only queries on c1wh-shipitez-prd, nywh-hydra-prd and nywh-shipitez-prd.

**Landed correctly:** 1 (except finding 1), 2, 3, 5, 6 (except findings 2 and 3), 7, 9, 10, 11, 12, 13, 14.
- Item 10: I re-ran the stockrecord query. It returns 4 STOCK_REMOVED rows and exactly `A301C4 3, A301C5 3, AC01-84 1, AT01-15 1`.
- The §8c positions 121691092–95 match the log rows.

## Answers to the four questions

**(a) Is `toteState` real? Yes.**
- `UnitloadRepository.java:44` has `Optional<UnitloadParcelGuardView> findParcelGuardViewById(...)`.
- `CancellationReversalService.java:78-79` already injects both `unitloadRepository` and `unitloadTypeRepository`.
- The type-name lookup pattern is `SourceContainerGuard.java:135`, `unitloadTypeRepository.findById(typeId)`.
- `WmsConstants.java:872` is `UNIT_LOAD_TYPE_TOTE = "Tote"`.
- Live `unitload_type` rows: c1wh has Tote as id 2 with 230 unit loads, Hydra has 8, nywh-shipitez has 28. Every live `pickingorder_unitload` with a non-null `unitload_id` points at a Tote (1 row each on c1wh and Hydra).
- The c1wh rows 1–4 sit on type `Default` / `Nirwana`, so they are OFF at amount 0. They are allowed.

**(b) Does the §3.3.2 restore change work? Yes, when there are no waived rows, but see finding 4.**
- The existing restore tests stub `findByCustomerorderId(CO_ID)` with a row that is not waived: `CancellationReversalServiceUnitTest:631`, `:668` and `:703`. So the waived sum is 0 and they stay green.
- I hand-traced three cases and all end correctly: A(1)/B(2), A(1)/B(2)/C(1), and complete-then-waive.

**(c) Does the recovered-SU guard block a real case-(ii) waive? No live row is affected.**
- Pending rows with a null `picktostockunit_id`: c1wh 0 of 4 pending; Hydra has 0 pending (10 of its 17 rows are null, all closed); nywh-shipitez has no rows.
- Recovery can only succeed while `pickingorder_unitload.unitload_id` is still set (`CancellationLogService.java:119-127`). The cancel clears that link, so the guard will rarely fire.
- One gap to write down: a row whose SU was recovered is closed and keeps its lock in the same call, so there is never a second attempt. §3.2 step 5 should say this explicitly as an accepted consequence.

**(d) Is `BaseRollbackIntegrationTest` meaningful for T18/T22? Yes.**
- Its javadoc says it "Intentionally omits @Transactional so that service @Transactional boundaries are real". The service transactions really commit or roll back.
- `app.cron=false`, so no dispatcher deletes outbox rows during the test.
- `OutboxMessage.aggregateId` is a `Long`.
- The fixtures, however, need changes (finding 2).

## Findings

**1. MEDIUM: OFF counts `Package` as "off the tote", so `stockReturned=true` can be attested for stock that is in a parcel.**
- **Claim:** §3.2 defines OFF as "the type name is known and is not Tote (Package, …)". Rows (ii′) and (iii-b)/(iii-d) allow `stockReturned=true` with amount > 0 when OFF. A pick-to SU that packing has moved into a parcel (the SBDEV-3353 case) is on a Package. The goods are going out, and the waive would tell PRD OMS the stock was returned. Complete refuses exactly this case.
- **Evidence:**
  - `CancellationReversalService` pre-validate: `SourceContainerGuard.assertStockNotInParcel(sourceStockunit, …)`.
  - c1wh: 106,868 Package unit loads, and 28 SUs at lock 100 on Package (7,525 units).
- **Second blind spot:** `MobilePickingService.java:520-557` accepts any existing unit load found by `findByLabelid(toteName)`. It checks location and emptiness but not type, so a pick-to container can in principle be a Case, Pallet or Cart, which reads as OFF. That is 0 live rows.
- **Fix to §3.2:** Add a fourth state, `PARCEL` (type name `UNIT_LOAD_TYPE_PACKAGE`). `stockReturned=true` with amount > 0 is refused for PARCEL, like ON/UNKNOWN. Extend rows (ii′), (iii-b) and (iii-d) with "PARCEL refuse".
- **Fix to §3.4:** `waiveLockRetained` stays `≠ OFF`, which includes PARCEL.
- **Tests:** add a T4 case "(ii′-PARCEL) refused", with the mutant "Package treated as OFF". Add to §0's blind spots: "a pick-to container that is not a Tote reads as OFF (MobilePickingService:520 has no type check; 0 live)".

**2. MEDIUM: the LockClear fixtures that T18/T22 "reuse" can't produce ON, break the distinct-id rule, and never enqueue.**
- **Evidence** (`CancellationReversalLockClearIntegrationTest`):
  - `:216` `tote.setTypeId(caseType.getId())`, where `caseType` is `UNIT_LOAD_TYPE_BOX` = "Case". So `toteState` is OFF, and T22's "lock 100, ON" premise can't hold.
  - `saveLog` has `log.setPicktounitloadId(tote.getId())`, which is equal to `su.unitloadId`. That breaks the §7.1 fixture rule.
  - `:238` `co.setOrderbatchId(1L)`, and no `CustomerorderBatch` is seeded.
  - `:243-245`: "A sibling position left pending … so the OMS outbox enqueue … stays out of this test's way".
- **Fix to §7.1 T18/T22 text:** "a new fixture builder in this class, not the `@BeforeEach` seed". It must:
  - take the Tote type via `unitloadTypeRepository.findByName(UNIT_LOAD_TYPE_TOTE).orElseGet(...)`, created once per context (the NonUniqueResult trap described at `:179-183`; the precedent is `:647`);
  - set `picktounitloadId` to a real `PickingorderUnitload` id that differs from the tote id;
  - seed a `CustomerorderBatch`;
  - stub `SyspropService.getSysvalue(REVERSAL_COMPLETED_URL_KEY)` with `@MockitoSpyBean` (the base sets `spring.cache.type=none` for exactly this);
  - use a CO with no leftover pending sibling.
- **T18 control:** add a positive control that the complete-only path on the same fixture produces 1 outbox row.

**3. MEDIUM: T18 contradicts the settled level trigger.**
- **Claim:** "outbox rows = 1 in both orders" and "a waived row cannot then be completed" can't both be asserted after the last call.
- **Evidence:** calling `/complete` on a CO that is already closed silently skips the waived row (the finder returns only pending rows), but it then runs `remaining.isEmpty()`, which re-enqueues. With a `stockReturned=true` waive, that makes 2 rows. §3.3.1 and T19 require exactly this.
- **Fix:** Assert the count of 1 before the extra complete call. Then state that the extra complete leaves the row `reversal_waived=true` with `reversal_completed_by` unchanged and the stock untouched, and raises the outbox count to 2 (the re-send path). If the waive was `stockReturned=false`, the count stays at 1 (suppression).

**4. LOW-MEDIUM: §3.3.2 must say where the waived sum is read from, and how it combines with the existing conditions.**
- **Claim:** In complete, the natural source is `logs`. That comes from `findPendingReversalsForUpdateByCustomerorderId`, which filters `reversalCompletedAt IS NULL`, so it never contains a waived row. The sum would always be 0, F2 would stay unfixed, and every unit test would stay green.
- **Second claim:** "fire only when … or when any … null" reads as a standalone OR, which would bypass the `residue < amountBeforeTransfer && residue > 0` conditions.
- **Fix text:** "Before the movement loop, compute `waivedShare[suId]` once from `findByCustomerorderId(coId)`, filtered to `reversalWaived`, grouped by `picktostockunitId`, and tracking whether any amount is null. Restore iff `arrivedLocked && residue != null && sameUL && residue < before && residue > 0 && (anyNull(suId) || residue > waivedShare(suId))`."
- **Why before the loop:** the read inside the loop is a JPQL query, which would AUTO-flush the residue save that the code comment says is "Deliberately NOT flushed".
- **Mutant:** the sum taken from `logs` must go red in T22.

**5. LOW: mobile "waived by another operator" never reaches the operator.**
- **Evidence:** with `applied` false and `message: null`, the loop at `store/cancellation.js:250-253` records the position as refused with no message (`if (outcome.message) …`). The summary then says nothing ("Nothing succeeded -> say nothing").
- **Fix to §3.8:** when a requested row comes back with `reversalWaived`, the primitive returns `{ok:false, message:'Position was waived by another operator'}` and calls `toastError`. A Jest test asserts the message and the `SET_REFUSALS` entry.

**6. LOW: say the pre-3316 recovery-strand case out loud in §3.2 and the ADR.**
- A row whose SU id was recovered in the call is closed with its lock kept, permanently (answer c).
- Add the measured count (0 live rows across the 3 PRD tenants) to §3.2 step 5 as its evidence, so a later reader doesn't take this for an oversight.

## References
- `v2/wms2-api` `src/main/java/net/aim_ai/wms/service/CancellationReversalService.java:78-79, :206-297` (pre-validate, recovery save, parcel guard), the restore block around `:419-431`, and the level-triggered enqueue after the loop
- `.../repo/jpa/UnitloadRepository.java:44`; `.../util/SourceContainerGuard.java:105-144`; `.../service/WmsConstants.java:426-433, :870-876`
- `.../service/CancellationLogService.java:114-138` (recovery needs `pul.unitload_id`)
- `.../service/mobile/MobilePickingService.java:520-557` (no type check on a reused pick-to container)
- `src/test/java/net/aim_ai/wms/common/base/BaseRollbackIntegrationTest.java` (no `@Transactional`, H2 with `DB_CLOSE_DELAY=-1`)
- `src/test/java/net/aim_ai/wms/integration/service/CancellationReversalLockClearIntegrationTest.java:179-183, :216, :238, :243-245, :647`, and `saveLog`
- `src/test/java/net/aim_ai/wms/unit/service/CancellationReversalServiceUnitTest.java:631, :668, :703`
- `pom.xml:588` / `:753` (`*IntegrationTest` runs in failsafe)
- `v2/wms2-mobile-ui` `store/cancellation.js:245-285, :325-327`
- DB, read-only, 2026-09-26: `unitload_type` counts on the 3 PRD tenants; lock-100 SUs by type; pending rows with null SU (0/0/0); c1wh rows 1–4 on Default/Nirwana; the stockrecord evidence re-run
