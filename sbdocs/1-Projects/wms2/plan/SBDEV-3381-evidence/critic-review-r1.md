**VERDICT: ITERATE.** The plan is not ready for the TDD gate. Option 1 is the right shape and I don't dispute it. But the stock-effect logic depends on an `onTote` predicate that is wrong as drafted, and the Architect's replacement is also wrong for a large share of c1wh's orders. Complete-after-waive can strand stock permanently (F2). Several test rows would pass on a broken build. I checked everything against wms2-api `origin/develop` d9be4188, mobile `origin/develop` 5e99732, and read-only queries on c1wh-shipitez-prd and nywh-hydra-prd.

**Mode:** I escalated to adversarial after confirming F1 and F2, which are two High findings.

**Pre-commitment vs actual.** I predicted problems in the stock/lock ownership logic (confirmed, and worse than the Architect found), the test lanes (confirmed), the PRD cleanup step (confirmed), weak mutation pins (confirmed), and authz registration (clean).

---

## Architect findings F1–F11

| # | Verdict | Why (evidence) |
|---|---|---|
| F1 | **CONFIRMED problem, REFINED fix** | The mismatch is real. `CancellationLogService:73` does `log.setPicktounitloadId(pickingPosition.getPicktounitloadId())`, and its javadoc says this column is an FK to `pickingorder_unitload`, "not to unitload". **The Architect's label fix is also unsound**, because `tote_label_id` comes from `customerOrder.getHistorytote()` (:78). For CLUB orders, `ManageOrderService:284-286` overwrites `historytote` with `UUID.randomUUID()` at FINISHED. On c1wh prd, **18,668 of 18,668 CLUB orders have a UUID `historytote`, and 0 of them match any unit load**. For multi-tote orders, `historytote` holds only the last tote assigned (`MobilePickingService:583`). A label mismatch then reads as "not on tote". For (ii) that fails safe (lock kept), but for (iii-b)/(iii-d) it fails open, because "allowed if … not onTote" lets `stockReturned=true` through. Fix: see N1. |
| F2 | **CONFIRMED** | `completeReversal` :419-431: `if (arrivedLocked) { … residue.getAmount().compareTo(amountBeforeTransfer) < 0 && … > 0) { residue.setEntityLock(PICKED_FOR_GOODSOUT)`. Nothing in that restore is aware of waived rows, so A-waived / B-completed re-locks A's share with no way out. The Architect's predicate is correct. Add the F10 null-guard: if any contributing `amountPicked` is null, restore (the conservative choice). |
| F3 | **REFINED** | The "re-send path" is reachable only by calling the API directly. `list()` uses `findPendingReversals` and `scanTote` filters `getReversalCompletedAt()==null` (:172). So once an order is closed, no UI screen can reach it to retry. The path's value is manual ops recovery. Keeping complete level-triggered is still better, because it changes complete least. But it reverses the Q4+Q8 default the main session took, so it has to be flagged to Nam (see PO items). Waive is edge-triggered anyway, because an empty `targets` list returns early. |
| F4 | **CONFIRMED** | §3.3 condition 3 reads every row from `findByCustomerorderId`, with no scope by time or episode. This is a product-owner call (below). |
| F5 | **CONFIRMED + extended** | `audit-access-invariants.sql` SET 9 has `WHERE NOT EXISTS (SELECT 1 FROM holders h …)`, so it only reports anything *before* the grant lands. Extension: merging to develop runs Flyway on dev at boot, so the dev pre-run must happen **before the merge**, and the PRD pre-run before DevOps promotes. |
| F6 | **CONFIRMED** | `WmsConstants:426-430` already has `WEB_UI_ACTION_*`. The size pin at `UserControllerPublicHandlerUnitTest:420` `.hasSize(3)` with "three mobile entries" is verified. |
| F7 | **CONFIRMED** | The seed shape matches V2.2.18. The roles exist on a fresh migrated DB: `V2.2.00:2872` inserts `outbound-manager` (582) and `super-admin` (585), so T17 can measure the grants. (T17's count-only assertion is a separate problem, N3.) |
| F8 | **CONFIRMED** | The FOR UPDATE finder, EvalPlanQual re-check under READ COMMITTED, and AUTO flush before the JPQL all behave as stated. `OutboxService.enqueue` generates a random-UUID idempotency key, so there is no hidden dedup to shift the counts. |
| F9 | **CONFIRMED, lane REFINED** | The recovery `logRepository.save(log)` at :241 runs before the refusals. "A refusal rolls back the recovery save" belongs in an **H2 `BaseRollbackIntegrationTest`**, which has real service transactions and is the lane the existing `CancellationReversalLockClearIntegrationTest` uses. It does not need Testcontainers. |
| F10 | **CONFIRMED** | `amount_picked` is nullable. The rule must also apply in F2's restore predicate. |
| F11 | **CONFIRMED + extended** | The **existing** `completeReversal` primitive (`store/cancellation.js`) has the same flaw. `applied = … p.reversalCompletedAt`, and its comment justifies that with "the stock genuinely is back". After this change, a row waived by another handheld comes back stamped, and Complete toasts "Reversal complete." for stock that never moved. Fix: `&& !p.reversalWaived` in `applied` (Phase 2). |

**Tote label reuse (your question).** Tote unit load rows are **reused as the same row**:
- c1wh `C1-0063` is one `unitload` row (id 2887773, type `Tote`) across 1,257 orders.
- Hydra `T-0002` is one row across 13 orders and `T-0007` one row across 24.

So neither the label nor the unit load id tells one order's use of the tote from the next. What does tell them apart is the SU id (`picktostockunit_id`), because every pick creates a new SU; the stockrecord `STOCK_CREATED` rows show new ids per pick. A stale SU still on the tote blocks reuse through mobile picking: `MobilePickingService:554-557` does `findByUnitloadId(tote.getId())` non-empty → "not empty!", which counts zero-amount SUs too. So for a stale SU with a **known id**, a later order's contents can't satisfy `onTote`.

The residual risk is the SBDEV-3316 **recovery** inside waive. It resolves `(pul.unitload_id, itemdata)` with `findFirst` against whatever is on the tote *now*, so a reused tote could hand back another order's SU (N4).

---

## New findings

**N1 (High): the `onTote` definition must be three-state and must fail closed on refusal.** Evidence is F1 above (CLUB UUID count 18,668/0; multi-tote overwrite). Replace the §3.2 `onTote` line with:
- `ON`: the SU's unit load, read via `findParcelGuardViewById` → `typeId` → type name, is `UNIT_LOAD_TYPE_TOTE` ("Tote", `WmsConstants:872`), **and** its `labelid` equals `log.toteLabelId`.
- `OFF`: the type name is known and is not `Tote` (Package, Default/Nirwana, bin).
- `UNKNOWN`: anything else (null view, null or missing type, a Tote whose label doesn't match, such as a CLUB UUID or multi-tote).
- **Clear 100** only when `ON`. For `stockReturned=true` with amount > 0, allow only when `OFF`; `UNKNOWN` refuses.
- Rewrite table rows (ii″), (iii-b) and (iii-d) in these terms. `waiveLockRetained` = lock 100 && amount > 0 && state ≠ `OFF`.

Test changes:
- Add T5b: CLUB-shaped fixture (UUID `toteLabelId`, SU on a Tote), QUALITY_FAULT, amount 1, `stockReturned=true` → refused. The mutant is the Architect's label-only rule.
- Fixture ids for `picktounitloadId` and `su.unitloadId` must differ (Architect).
- Note: `SourceContainerGuard.judge` treats a null type as "not a Package", which fails open. Do not reuse its default.

**N2 (Medium): T18's lane has no harness.** "Testcontainers IT (tenant tx)" names no base class, and no cancellation service IT runs on Postgres. The service ITs (`CancellationReversalLockClearIntegrationTest`, `…ParcelSourceIntegrationTest`) extend `BaseRollbackIntegrationTest`, which is H2 with `DB_CLOSE_DELAY=-1`, so rows persist across tests. Change T18 to "extend `CancellationReversalLockClearIntegrationTest` fixtures on `BaseRollbackIntegrationTest`". Assert outbox rows `WHERE aggregate_id = <fixture-unique coId>`, never a global count. Add F9's rollback assertion and T22 (F2) there. State that the CHECK constraint is absent in this lane.

**N3 (Medium): the grant assertions count, so a role swap survives.** T17 says "function row + exactly 2 grants" and M6 expects "2 grants". The mutant "`super-admin` → `outbound-worker`" keeps the count at 2. Change T17 and M6 to assert the **set of role names** is `{outbound-manager, super-admin}`, and add that swap to T17's mutation list.

**N4 (Low): a recovered SU on a reused tote.**
- **Evidence:** `resolvePicktoStockunitId` does `findByUnitloadIdAndItemdataId(realUnitloadId, itemdataId).stream().findFirst()`, and tote rows are reused (above).
- **Mitigated by:** `pickingorder_unitload.unitload_id` is cleared on order cancel (`PickingorderBusinessService:793-794`) and at FINISHED. Also, all 4 c1wh rows already carry SU ids.
- **Fix:** add to §3.2 step 5: "never clear a lock on an SU whose id was recovered in this call; close the row and report `waiveLockRetained`". Pin it in T3.

**N5 (Medium): §8's `stockReturned=true` is justified by the rule table, not by evidence.** §8 says "`stockReturned=true` is allowed because this is case (i)". Allowed is not the same as true, and this attestation reaches PRD OMS. The evidence does exist. c1wh stockrecord shows `rfernandez`, MANUAL_SPLIT, 2026-09-21 21:54:21–21:55:51, from Clearing/C1-0063, with STOCK_CREATED of the exact amounts at `A301C5` (3), `A301C4` (3), `AT01-15` (1) and `AC01-84` (1). Those match the logs' back-to-bin locations one for one. Add to §8, as a gating pre-step: the stockrecord query (`fromstockunitidentity IN (…)` plus the paired STOCK_CREATED rows at the same timestamp) with the expected 4 matches, and the sysprop check `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED = https://api-oms.sbo.li/…` (currently the PRD host; the Hydra-to-UAT precedent shows why to check). Also record in §1 that this is the item-2 mechanism: order-cancel `cleanUpCancelledOrder` clears the lock, then Move Stock drains the SU.

**N6 (Low): (i′) clears lock 100 with no position condition.** This contradicts Principle 2 and row (ii″). Make it "clear only if `ON`", or give an explicit rationale for why a zero-amount lock is harmless to clear anywhere.

**N7 (Low): alternatives and principle consistency.**
- §9 omits the Architect's Option 1′ (close records only, write no stock unit). Add it, rejected because it breaks the §1 case-(ii) driver.
- If F3 is adopted, `ralplan-dr.md` Option 1 ("shared edge-triggered enqueue"), its first Pro, and the ADR "Why chosen" and "Consequences" all have to change.

**N8 (Low): M1 and M3 have no fixture recipe.** Add these:
- **M1 (case i):** pick into a tote → order-level cancel → Move Stock each SU from Clearing back to its bin. This is the path c1wh took.
- **M3 (case ii):** a per-position cancel, which leaves lock 100 on the tote (the `cancelOrderPosition` gap cited at `CancellationReversalService:318-321`).

**N9 (Low): `reason` is unbounded TEXT from the operator.** Cap it (for example 500 chars) in the service with a `BusinessException`, and add a boundary case to T8.

**N10 (Low): test hygiene.**
- T21 asserts a *service* computation (`waiveLockRetained`) in a *serialization* test. Move that half to `CancellationReversalServiceUnitTest`.
- §0 #34 "eyeball `SurfaceInventoryContextTest`" is not a verification. Either assert that the `/waive` route carries the waive function in the generated inventory, or delete the row.
- T3 must include an "already-waived sibling" fixture, or the "drop the already-waived term" mutant can't be killed.

---

## Consolidated change list (in order)

1. **§3.2 `onTote`**: replace it with the three-state ON/OFF/UNKNOWN rule (N1), and rewrite rows (i′), (ii), (ii″), (iii-b) and (iii-d) against it (N6). Make the same change in §3.4 for `waiveLockRetained`.
2. **§3.2 step 5**: no lock clear on an SU recovered in this call (N4).
3. **§3.2 ownership rule**: if any contributing `amountPicked` is null, the rule declines (F10).
4. **Complete's residue-restore**: restore only if `residue.amount > Σ amountPicked(waived rows of this CO with the same picktostockunitId)`, and restore when any contributing amount is null. Strike "the lock clear/restore logic in complete" from §6 "What does NOT change" (F2).
5. **§3.3**: keep complete level-triggered and add only condition 3. Waive is edge-triggered by its early return. Update the §3.3 ⚠ bullets, §1 "Found while reading", ADR "Consequences", §6 "Behaviour change", §7.5 #6 and ralplan-dr Option 1. Invert T19 to "a complete retry on a closed CO re-enqueues (the re-send path)". This is pending Nam's acknowledgement (PO item 2).
6. **§7 tests**:
   - T3, T5 and T21 get distinct-id fixtures plus the "id comparison" and "label-only" mutants.
   - Add T5b (CLUB/UUID → refused) (N1).
   - Add T22 (waive A then complete B → residue lock 0; mutant: the old restore) (F2).
   - T4's unit fixtures use a non-null `picktostockunitId` (F9).
   - Move T18 to `BaseRollbackIntegrationTest` (H2), extending the LockClear IT fixtures, with outbox asserted by fixture `aggregate_id`. Add "refusal rolls back the recovery save" there (N2, F9).
   - T17 asserts the role-name set, with the swap mutant (N3).
   - Split T21 (N10).
   - T8 adds the reason length cap (N9).
7. **§3.5**: cite the `WEB_UI_ACTION_*` precedent (`WmsConstants:426-430`) (F6).
8. **§3.8 (mobile)**:
   - `waivePosition` checks `reversalWaived` (F11).
   - The existing `completeReversal` `applied` adds `&& !p.reversalWaived`, with a Jest pin and a mutant.
9. **§5.1 #7 and M7**: run SET 9 before the dev merge and before PRD promotion (expect the new users), then after (expect 0). O2 is reviewed at the PRD pre-run (F5).
10. **§8 step 4**: add the stockrecord evidence query and the sysprop-host check as gating pre-steps. Replace "allowed because this is case (i)" with the measured evidence (N5).
11. **§7.4**: add fixture recipes for M1 and M3 (N8). M6 asserts the role-name set (N3).
12. **§9**: add Option 1′ with its rejection rationale (N7).
13. **§0 #34**: assert it or delete it (N10).
14. **§10**: record Nam's answers to the PO items below.

## Product-owner decisions (only the real ones)

1. **F4, how far suppression reaches.** One `stockReturned=false` waive permanently stops the OMS "reversal completed" notice for the **whole order**. That includes rows later closed by a real stock movement and rows added by a later partial cancel. Is that the intended reading of D-a? It is still unverified whether OMS alerts or reports on parcels with an open reversal.
2. **F3 reverses a stated default.** Keeping `completeReversal` level-triggered drops the "edge trigger in both" part of the Q4+Q8 default. The harmless duplicate-notice defect stays, in exchange for keeping the manual re-send path. Nam should acknowledge this.

---
*Ralplan summary row:*
- **Principle/option consistency: Fail.** Principle 2 is violated by (i′) and by complete's restore (F2, N6). Option 1's "edge-triggered" wording conflicts with the F3 fix.
- **Alternatives depth: Fail (minor).** Option 1′ is missing from §9.
- **Risk/verification rigor: Fail.** The `onTote` predicate is wrong in both drafts. The count-only grant pin, T18 with no harness, and the §8 attestation without evidence all need fixing.
- **Deliberate additions:** N/A (SHORT mode).

Files reviewed: `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3381-cancellation-reversal-waive.md` and `…/SBDEV-3381-evidence/{architect-review,ralplan-dr,analysis}.md`.
