ticket: SBDEV-3381 · scope: item 1 only — `POST /v3/cancellation/{customerOrderId}/waive` · kind: analysis bundle (not the plan)
graded: wms2-api `origin/develop` d9be4188 · wms2-mobile-ui `origin/develop` 5e99732 (fetched for this bundle) · db_verified: c1wh-shipitez-prd, nywh-hydra-prd, nywh-shipitez-prd (read-only, 2026-09-26)
---

All code was read with `git show/grep origin/develop`. One exception: oms-laravel-api is cited from its local `develop` checkout (f61ed952, 2026-09-21), which I did not fetch.

## 0. Affected sites (by enumeration)

### 0.1 Greps run over the whole wms2-api tree (src/test and SQL included)

| Pattern | Files | src/main |
|---|---|---|
| `reversalCompletedAt\|ReversalCompletedAt` | 11 | 4 |
| `reversal_completed_at` | 12 | 8 |
| `findPendingReversals` | 9 | 5 |
| `customerorder_cancellation_log` | 16 | 12 |
| `CustomerorderCancellationLogRepository` | 12 | 5 |
| `MOBILE_UI_VIEW_CANCELLATION` | 16 files / 32 lines | 9 |
| `MOBILE_UI_VIEW_REPLENISH_REQUEST` (recent comparator) | 11 | 7 |
| `WEB_UI_VIEW_PARCEL_PICKING` (second comparator) | 10 | 6 |
| `FunctionEnum\.class` | 5 | 2 (`AccessService.updateFunctionList`, `SdrRuleStartupAssertion`) |
| mobile-ui `cancellation/` call sites | 5, all in `store/cancellation.js` | — |

Blind spots:
- This is a text grep. It misses native SQL spelled differently.
- I did not measure whether this table is reachable through Spring Data REST (SDR); see Q7.
- The web UI was not swept.

### 0.2 Sites

| # | Site (quoted snippet) | In scope | Why |
|---|---|---|---|
| 1 | `OrderCancellationController`: class-level `@RequiresFunction(...MOBILE_UI_VIEW_CANCELLATION)` (:29), `@PostMapping("/{customerOrderId}/complete")` (:61) | **change** | New `/waive` handler with a method-level `@RequiresFunction` |
| 2 | `CancellationReversalService.completeReversal` (:200); outbox block starting `remaining = logRepository.findPendingReversals().stream().filter(...coId)` (:454–490) | **change** | New `waiveReversal`. Move the enqueue into a private method both paths call, so the payload can't drift |
| 3 | `toDetailDto`: `entry.setReversalCompletedAt(...)` (:537) | **change** | Map the new waive fields |
| 4 | `CustomerorderCancellationLog`: `@Column(name="reversal_completed_at")` (:112); has `@Version` (:22) | **change** | 3 new columns (§6) |
| 5 | `CancellationLogEntryDto` (:15–16) | additive | `reversalWaived`, `waiveReason`, `waiveStockReturned` |
| 6 | `CancellationCompleteRequest` | pattern | New `CancellationWaiveRequest{positionIds, reason, stockReturned}` |
| 7–9 | Repo finders: `findPendingReversals` `"...reversalCompletedAt IS NULL"` (:17); `findPendingReversalsOlderThan` (:39–42); `@Lock(PESSIMISTIC_WRITE) findPendingReversalsForUpdateByCustomerorderId` (:44–50) | read; no change if waive stamps `reversal_completed_at` | #9 is the concurrency lock point that waive will reuse |
| 10 | `scanTote` filter `l.isReversalRequired() && l.getReversalCompletedAt()==null` (:172); `detail` uses `findByCustomerorderId`, so it returns every row, waived ones too | read | The DTO has to say "waived" |
| 11 | `PendingReversalReconciliationJob`: `"Complete or waive them on the mobile Cancellation screen."` (:235–236); tail text quotes `WHERE reversal_required AND reversal_completed_at IS NULL` (:229) | **change wording** | Waived rows drop out of its query automatically if waive stamps |
| 12 | V2.2.00 :3869, partial index `idx_cancel_log_reversal_pending ... WHERE reversal_required AND reversal_completed_at IS NULL` | read | A stamped waive leaves the index, which is the right meaning |
| 13 | `WmsConstants.FunctionEnum` (:457) | **add constant** | |
| 14 | `UtilRestController` :430 `grantFunction(...MOBILE_UI_VIEW_CANCELLATION, role_inventory_manager, role_outbound_manager, role_outbound_worker, role_super_admin)`; class is `@Service` (:23) | **add grant** | Only runs on a fresh DB; the migration is what reaches live tenants |
| 15 | New `V2.2.34__*.sql` | **new** | §6 |
| 16–17 | `AccessAuditService` `GATED_WORKFLOWS` (:106, javadoc "mirroring util/menuCatalog.js"); audit SET 4 `gated(...)` (:79–92, :150–163) | **no** | These list menu tiles. A waive is an action inside a tile; adding it would credit a waive-only user with a workflow |
| 18 | audit SET 9 `steps(...)` `('step3_CANCELLATION', ..., ARRAY['outbound-worker','outbound-manager','super-admin'])` (:281) | **add row** | SET 9 exists to report access a deploy *adds* |
| 19 | audit SET 3 `LIKE 'MOBILE_UI_VIEW_%'` (:56, :63) | constrains naming | Rules out a `MOBILE_UI_VIEW_*` name |
| 20 | `FunctionGuardInterceptor.GUARDED` already includes `OrderCancellationController` (:135) | no | |
| 21 | `FunctionGuardArchTest` `REVIEWED_METHOD_LEVEL_OVERRIDES = Set.of("LookupController#locationByLocationName", "ReplenishController#requestLocation", "ReplenishController#requestAmount")` (:686), asserted by exact equality in AC-4b | **will go red; update** | By design |
| 22 | `UserControllerPublicHandlerUnitTest` :414–420: `reviewedOverrides ... .hasSize(3)`, message "must stay at its three mobile entries" | **will go red; change to 4** | Reads #21 by reflection, from another file |
| 23 | Arch AC-2 golden map (class-level only); AC-3 (annotation values are declared constants) | no | |
| 24 | `FunctionGuardMockMvcUnitTest` `SURFACE.put(OrderCancellationController.class, {"/v3/cancellation/list", ...})` (:80) | **extend** | Separate test method (the map holds one entry per class) |
| 25 | `UtilRestControllerUnitTest` C2: 3 functions × 4 personas (:216–236) | **extend separately** | The waive grant covers fewer roles |
| 26 | `UtilRestControllerSeedUnitTest` C-8d, V2.2.21 ↔ initDB parse (:384–430) | pattern | Precedent for a V2.2.34 ↔ initDB parity test |
| 27 | `PendingReversalReconciliationJobUnitTest` (13 tests) | **extend** | Nothing pins the wording today: grep `waive\|Cancellation screen` gives 0 hits there. Control: the same grep does hit `CancellationReversalLockClearIntegrationTest:419` |
| 28 | `PendingReversalOlderThanIntegrationTest` (4 tests) | **extend** | Add a "waived row excluded" case |
| 29 | `PickingorderBusinessService:622` comment "skipping only rows that already carry reversal_completed_at" | read | Stays true |
| 31 | `05-verify-bridge.sh` :9–10 | no | Onboarding bridge only |
| 32 | **wms2-mobile-ui** `store/cancellation.js` :98/111/162/181/315 | **separate repo** | §2.4 |
| 33 | `sbdocs/.../wms2-cancel-cascade-workflow.md` (`last_verified: 2026-05-08`; 0 mentions of waive) | doc drift | |

## 1. DB state (measured 2026-09-26)

**c1wh prd (the live case):** confirmed as briefed.

| log id | position | pick-to SU | back to bin | amount picked | SU now |
|---|---|---|---|---|---|
| 1 | 121691095 | 121691900 | AT01-15 | 1 | amount 0, lock 2 |
| 2 | 121691094 | 121691930 | AC01-84 | 1 | amount 0, lock 2 |
| 3 | 121691092 | 121691950 | A301C4 | 3 | amount 0, lock 2 |
| 4 | 121691093 | 121691975 | A301C5 | 3 | amount 0, lock 2 |

- All 4 rows: order 121691091, tote C1-0063, pick-to unit load 121691896, `reversal_required=true`, never initiated, never completed. All 4 SUs now sit on the `Nirwana` unit load.
- Tenant totals: 4 rows, all pending.
- `MOBILE_UI_VIEW_CANCELLATION` is held by `outbound-manager`, `outbound-worker`, `super-admin`. **`inventory-manager` does not hold it here**, even though initDB grants it (V2.2.18's "OPEN DIVERGENCE").
- Flyway head is 2.2.33.

**Hydra prd:**
- The 7 `reversal_required=true` rows were closed by `completeReversal`, and all now point at a lock-2 (GOING_TO_DELETE) SU.
- 10 `required=false` rows point at no SU.
- So the live c1wh rows are already in exactly the state a *successful* completeReversal leaves behind (drained SU → `sendStockUnitToNirvana`, service :392–395). The only things missing are the log stamp and the OMS notice.

**nywh-shipitez prd:** 0 rows. UAT, dev and WineCo were not queried.

## 2. Current architecture

**2.1 Controller.**
- Handlers: list, detail, scan-tote, initiate, complete. No method-level gates.
- Errors go through `MobileEndpointExceptionHandler(basePackages="...controller.mobile")`.
- `@RequiresFunction` is ANY-of, and "placed on a method it **replaces** the class default". There is no AND form.
- Precedent for a stricter function on one method: `ReplenishController`, class-level `MOBILE_UI_VIEW_REPLENISHMENT`, overridden to `MOBILE_UI_VIEW_REPLENISH_REQUEST` on `requestLocation`/`requestAmount` (:39, 92, 117).
- Web precedent for an action function: `StockUnitController` `WEB_UI_ACTION_ADJUST_LOCK_RELEASE_LOCK` (:627, :653).

**2.2 `completeReversal` flow** (:199–493). Runs under `tenantTransactionManager` with rollbackFor both exception types.
1. Empty `positionIds` → "positionIds required".
2. Loads the pending rows with the FOR UPDATE finder.
3. Pre-validate loop. It re-tries SU id recovery, persisted as in SBDEV-3316. It refuses, with "... — manual intervention required", when:
   - no SU can be resolved,
   - the pick-from location is null,
   - the SU is missing,
   - the lock is not in {NOT_LOCKED, PICKED_FOR_GOODSOUT} (:270–277). **This is the live-case refusal: lock 2.**
   - or `SourceContainerGuard.assertStockNotInParcel` fails.
4. Movement loop:
   - Clears PICKED_FOR_GOODSOUT/null to NOT_LOCKED **and flushes** (the flush is load-bearing, :324–335).
   - Calls `transferStock(su, amountPicked, false, pickfromlocationname, ...)`.
   - Restores PICKED_FOR_GOODSOUT on any residue left on the tote (:420–445).
   - Stamps `completedAt` / `completedBy` (`SecurityContextUtils.getUserName()`).
5. Outbox (:453–490). If no pending row is left for the CO:
   - Blank sysprop `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` → warn and don't enqueue.
   - Otherwise enqueue `OutboxMessage{aggregateType CUSTOMER_ORDER, aggregateId coId, processType ORDER_BATCH_REVERSAL_COMPLETED, destinationUrl, payload}`. Payload: `OrderBatchDto{batchId, facilityCode=MULTIWAREHOUSE_IDENTIFIER, positions=[OrderDto{uniqueId=co.externalnumber, positions=[]}]}`.

"All positions complete" is a **level test**: no pending rows remain after this call.

**Existing defect found while reading.** A repeat `complete` whose `positionIds` match only rows that are already completed writes nothing, finds nothing pending, and **enqueues a second REVERSAL_COMPLETED**.
- It's reachable: the mobile store sends one position per request, so retrying after a lost 200 hits this path.
- OMS absorbs it: `batchReversalCompleted` is idempotent on `parcel.reversal_completed_at` (:4005–4009).
- The waive must be edge-triggered instead. This is below T3, so it can go on this ticket; low severity.

**What OMS does with the notice** (docblock :3857–3868): "thin audit/status handler and MUST NOT touch product_inventory: inventory was already returned ... when cancelPosition processed". It stamps the parcel and writes a status-history row. So the notice has **no inventory effect** in OMS.

**2.3 Everything that reads "pending" as `reversal_completed_at IS NULL`:**
- the three finders
- `scanTote`
- the partial index
- the mobile store's `stillPending = positions.some(p => p.reversalRequired && !p.reversalCompletedAt)`

**2.4 Mobile UI.**
- Files: `pages/cancellation.vue`, four components (scan, list, detail, action), `store/cancellation.js`.
- It calls list, scan-tote, detail, initiate and complete. There is no waive call and no waive UI; the action bar pin shows `['Main Menu','Back','Complete Reversal']`.
- **A mobile UI change is required before an operator can use this.** It's a separate repo and PR.
- If waive stamps `reversalCompletedAt`, the existing screen already closes a waived order correctly. The UI change is only needed to *start* a waive; the per-position `SET_REFUSALS` state is the natural hook for it.

## 3. What the waive does to stock

Principle: **never move stock, and never touch a lock another process owns.** The only lock it may release is PICKED_FOR_GOODSOUT. completeReversal gives the reason at :306–308: "a completed reversal is exactly the statement that these goods are NOT going out, so clearing it is the truthful write." A waived reversal makes the same statement.

Reference points:
- Lock states: NOT_LOCKED 0, GOING_TO_DELETE 2, PICKED_FOR_GOODSOUT 100, QUALITY_FAULT 103, ON_HOLD 104, NOT_FOUND 403, TRANSFER 404, SHIPPED 405.
- `OPERATOR_REMOVABLE = {QUALITY_FAULT, ON_HOLD}` (:1634).
- `removeLock` (:984–1008) throws for SHIPPED, GOING_TO_DELETE and everything outside that set. **So PICKED_FOR_GOODSOUT has no operator path out anywhere in the product today.**

| Case | Pick-to SU state | Waive writes to stock | Allow `stockReturned=true`? | Why |
|---|---|---|---|---|
| (i) live case | amount 0, lock 2, on Nirwana | nothing | yes | Same end state as a successful complete (Hydra 7/7). Writing to it would fight the delete sink |
| (i′) | amount 0, lock 0 or 100 (tote at a fixed location; service :396–399) | clear 100 → 0 | yes | Nothing is reserved on a zero-amount row |
| (ii) the ticket's case | amount > 0, lock 100, still on the pick-to unit load | **clear 100 → 0, no move**, only if the ownership rule holds | **refuse** (Q1) | Otherwise the stock is stranded for good. Once cleared, Move Stock can take it (`SourceLockGuard.isLocked` = "lock != NOT_LOCKED"). Refuse `true` because the system itself shows N units still on tote X |
| (ii′) | amount > 0, lock null | nothing | refuse, as (ii) | completeReversal normalises null only because the transfer would unbox it; waive does no transfer |
| (iii-a) | SU missing or id unresolvable | nothing (persist a recovered id, as :239–242) | yes | Nothing to reconcile |
| (iii-b) | QUALITY_FAULT / ON_HOLD | nothing | yes if amount 0 or the SU is off the tote, else refuse | Operators can already remove these with `removeLock`, which also sends the stock-change message these two need |
| (iii-c) | SHIPPED | nothing | **refuse** | The goods left the building |
| (iii-d) | 403 / 404 / other | nothing | as (iii-b) | Owned by another process |

**Ownership rule for the case (ii) clear.** Clear only if `su.amount <= Σ amountPicked` over the rows this call waives that resolve to that SU. This mirrors completeReversal's residue logic (:363–376): two picks of one SKU into one tote merge into one SU, so part of it may still belong to a position that isn't being waived. If the rule declines, leave the lock, still close the row, and say so in the response.

No stock-change message is needed for the clear: completeReversal sends none, and OMS already returned that inventory at cancel time.

Interaction with out-of-scope item 2: fencing the cancel lock-clear sites makes case (i) rarer, so (ii) becomes the main waive input. That's why the (ii) clear can't be dropped.

**3.4 Should waive stamp `reversal_completed_at`? Recommended: yes.** Stamp `completedAt` / `completedBy` and set `reversal_waived=true`.
- For: all six consumers in §2.3 become correct with zero change. That includes the reconciliation-job exclusion (pinned by T15) and waive/complete mutual exclusion through the existing FOR UPDATE finder.
- Against: "completed" stops meaning "moved". Today no src/main reader distinguishes the two, and `reversal_waived` is the column for anyone who needs to.
- Rejected alternative: leave the stamp null and filter on `reversal_waived` everywhere. That's 3 JPQL predicates, `scanTote`, a new index and a mobile `stillPending` change, and every future pending query has to remember the extra predicate.

## 4. Transaction and concurrency

- **Locking.** Same transaction manager and rollbackFor as complete, loaded through the same **FOR UPDATE finder**. Under PostgreSQL READ COMMITTED a blocked waive or complete re-checks the WHERE clause on the updated row, so it won't see a row the other one stamped.
  - The wait is bounded by the tenant `lock_timeout`, per lock acquisition (repo :46–49).
  - `@Version` is a second layer.
  - Lock order is unchanged: log rows first, then the stockunit update, as completeReversal already does.
- **Pre-validate everything, then write.** A refused waive commits nothing.
- **Take `positionIds`, required and non-empty.** The mobile store works one position per request, so partial orders come naturally: complete what can be completed, waive the refused rows.
- **Idempotency and bad ids.**
  - Re-waive, waive-then-complete and complete-then-waive are all no-ops.
  - An id that matches **no row on this CO** throws a BusinessException. Complete returns a silent 200 here, which the store had to work around ("A 200 is NOT proof this position moved").
  - An id that matches an already-closed row is a no-op.
- **Outbox.** Enqueue only if this call closed at least one row, no pending rows remain, and `stockReturned` is true. Use the shared builder. The outbox row is written in the same transaction.
- **Q4, mixed close.** Recommend one predicate for both waive and complete: notify only if every row is closed and none is `waived AND NOT stock_returned`.

## 5. Authz

**Constant:** `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL`.
- It follows the `WEB_UI_ACTION_*` family.
- It avoids audit SET 3's `LIKE 'MOBILE_UI_VIEW_%'`.
- No code does prefix matching on these names: `startsWith("MOBILE_UI|WEB_UI")` gives 0 hits in src/main and 0 in mobile-ui.
- It would be the first constant of this family (Q5).

**Annotation and grants:**
- Put a method-level `@RequiresFunction(<new constant>)` on the waive handler, following the ReplenishController pattern.
- Because the method-level annotation *replaces* the class gate, someone holding only the waive function could call it. Control that through the grant set, not an in-service check. An in-code check would be invisible to `SurfaceInventoryContextTest` ("Gate detection is ANNOTATION-ONLY") and to every anti-drift pin.
- Grant to **outbound-manager and super-admin**, the same set in initDB and V2.2.34. Both hold VIEW_CANCELLATION on c1wh.
  - Not outbound-worker: this overrides a system refusal, so it's a supervisor action.
  - Not inventory-manager: it doesn't hold VIEW on c1wh.

**Tests that go red and must be updated in the same commit:**
- `REVIEWED_METHOD_LEVEL_OVERRIDES`: add `"OrderCancellationController#waiveReversal"`.
- `UserControllerPublicHandlerUnitTest`: `hasSize(3)` → 4.
- Optionally add an AC-28-style pin for the waive override.

**Where a new constant must be registered** (derived from how three existing constants are wired):
1. the FunctionEnum constant (a fresh DB creates the row via `updateFunctionList`'s reflection, but grants must be explicit);
2. the initDB `grantFunction` line;
3. the Flyway function row plus grants;
4. the `@RequiresFunction` use;
5. an audit SET 9 row.

Not needed: GATED_WORKFLOWS / SET 4, or `SdrRuleStartupAssertion` (which only validates SDR rule values).

## 6. Flyway V2.2.34

V2.2.33 is the head on `origin/develop` and across all 344 remote branches in the local fetch. That's perishable; re-sweep right before the PR.

```sql
-- Idempotent: ADD COLUMN IF NOT EXISTS (V2.2.31); seeds via WHERE NOT EXISTS, never ON CONFLICT (V2.2.18: PK name drifts / absent)
ALTER TABLE public.customerorder_cancellation_log
  ADD COLUMN IF NOT EXISTS reversal_waived boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS reversal_waive_reason text,
  ADD COLUMN IF NOT EXISTS reversal_waive_stock_returned boolean;
-- waived_by/at = reversal_completed_by/at (§3.4)
-- optional (Q6), wrapped in DO $$ ... IF NOT EXISTS (pg_constraint) $$:
--   CHECK (NOT reversal_waived OR (reversal_completed_at IS NOT NULL AND btrim(reversal_waive_reason) <> '' AND reversal_waive_stock_returned IS NOT NULL))
INSERT INTO mywms_function (id, version, client_id, name, number, function)
SELECT nextval('seqentities'),0,0,f.name,f.name,f.name
FROM (VALUES ('MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL')) f(name)
WHERE NOT EXISTS (SELECT 1 FROM mywms_function e WHERE e.function=f.name OR e.name=f.name);
INSERT INTO mywms_role_mywms_function (rolelist_id, functionlist_id)
SELECT r.id, f.id FROM mywms_role r CROSS JOIN mywms_function f
WHERE f.name='MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL' AND r.name IN ('outbound-manager','super-admin')
  AND NOT EXISTS (SELECT 1 FROM mywms_role_mywms_function x WHERE x.rolelist_id=r.id AND x.functionlist_id=f.id);
```

- `NOT NULL DEFAULT` adds the column without rewriting the table (PG ≥ 11), and the table has ≤ 17 rows on the measured tenants.
- A tenant migration failure freezes that tenant silently, and the CHECK is the riskiest statement.
- V2.2.28 and V2.2.31 already ALTERed this table on the fleet. That's evidence, not proof, that table ownership won't block it.
- **Which lanes see the migration:**
  - The Testcontainers lane uses `ddl-auto=validate`, so a column mapped without a migration fails there.
  - Migration ITs: `CancellationLogPickingorderPositionIdIT` (the watermark pattern) and `StartupFlywayMigratorIntegrationTest`.
  - The H2 lane (`create-drop`, Flyway off) never sees the CHECK.

## 7. Tests to write

**Service unit tests** (in `CancellationReversalServiceUnitTest`):

| # | Test | Mutation it must kill |
|---|---|---|
| T1 | Live case: rows stamped and marked waived; stock is never saved or transferred | Delete the stamp, or write the lock-2 SU |
| T2 | Case (ii): lock 100 → 0 with no transfer | Drop the clear |
| T3 | Ownership rule: lock left alone when the SU holds more than the waived rows picked | `<=` → `<`, or always clear |
| T4 | `stockReturned=true` refused when stock is still on the tote, and when SHIPPED; no row saved | Refuse after the writes |
| T5 | QUALITY_FAULT / ON_HOLD untouched | Clear any lock |
| T6 | Enqueue only when `stockReturned` and the last row closes; payload identical to complete's | Drop either condition |
| T7 | Second waive does not re-enqueue | Level trigger |
| T8 | Blank reason, empty ids, id not on this order → rejected | `isBlank` → `isEmpty` |
| T9 | Uses the FOR UPDATE finder | Swap the finder |

**Controller and gate tests:**

| # | Test | Mutation it must kill |
|---|---|---|
| T10 | New `OrderCancellationControllerUnitTest` on `BaseControllerUnitTest` (there's no `BaseControllerTest` on develop): request body binds and reaches the service | Swap a field name or default |
| T11 | `FunctionGuardMockMvcUnitTest`: 403 for a VIEW-only holder, 200 for a waive holder. `setupMockMvc` installs no interceptor, so this has to be tested here | Delete the method annotation |
| T12 | The two override-count pins from §5 | — |

**Seed and migration tests:**

| # | Test | Mutation it must kill |
|---|---|---|
| T13 | initDB grants the waive function to exactly {outbound-manager, super-admin} | Add outbound-worker |
| T14 | V2.2.34 ↔ initDB parity, comment-stripped, C-8d style | Drop a role on one side |
| T15 | `PendingReversalOlderThanIntegrationTest`: waived row excluded, with an un-waived row in the same test as positive control | Stop stamping |
| T16 | Reconciliation job unit test: new wording | Revert the text |
| T17 | New `CancellationWaiveMigrationIT`: at 2.2.33 absent, at 2.2.34 present; default false; function row + 2 grants; re-run idempotent; CHECK violation asserted by SQLSTATE 23514, not by message | Drop DEFAULT or CHECK |
| T18 | Testcontainers IT: waive↔complete in both orders produces exactly one outbox row | Level trigger |

No thread-race IT is proposed, since two existing concurrency ITs are already known to be timing-flaky. That choice is open to dispute.

## 8. Alternatives, compatibility, checklists

**Alternatives rejected:**
- **(A) Force complete.** There's nothing to move on a Nirvana row.
- **(B) Notes-text marker.** Nam settled on columns, and a notes field is unqueryable and gets overwritten.
- **(C) Don't stamp `reversal_completed_at`.** See §3.4.
- **(D) Reuse the VIEW gate.** Settled against, and it would give the override to every outbound-worker.
- **(E) Whole-order waive.** Would force waiving positions that could still be reversed.
- **(F) In-service AND check.** Invisible to annotation-based gate detection.

**Backward compatibility:**
- The position DTO gets 3 additive fields. The serialization test pins individual keys, not a closed key set.
- The list and detail DTOs need nothing.
- Existing rows default to `waived=false`.
- The OMS payload is byte-identical to complete's.

**Horizontal scalability:**

| # | Concern | Verdict |
|---|---|---|
| 1 | In-JVM state | No |
| 2 | Connection pool | No |
| 3 | Scheduled jobs | No new job (wording change and a free exclusion) |
| 4 | Long transactions | No |
| 5 | Request affinity | No |
| 6 | Retry / idempotency | **Yes** — edge trigger, T7 |
| 7 | Tenant context | No |
| 8 | Distributed lock | **Yes** — FOR UPDATE shared with complete, T9 |
| 9 | Cache | N/A — not measured against `wms2-caching-strategy.md` |
| 10 | External notification | **Yes** — transactional outbox only |

**v2-only constraints:**

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV off | Yes, handled — everything loads in the transaction; `detail` has its own readOnly tx |
| 2 | Tenant tx manager | Yes |
| 3 | readOnly reads | N/A |
| 4 | Caffeine | N/A |
| 5 | Micrometer | No — low-frequency action and nothing scrapes metrics; `LOG.info` is the breadcrumb |
| 6 | Jakarta | Yes |
| 7 | H2-compatible SQL | Yes — the CHECK constraint is covered only by T17 |
| 8 | Controller test base | Yes — `BaseControllerUnitTest`, gate covered by T11 |

## 9. Open questions a reviewer could dispute

- **Q1.** Case (ii) with `stockReturned=true`: refuse (my recommendation) or accept? If refused, a case-(ii) order never produces the OMS notice. The notice is audit-only, so either choice costs little.
- **Q2.** Is it acceptable for `reversal_completed_at` to mean "closed" rather than "moved", with `reversal_waived` as the discriminator?
- **Q3.** The ownership rule is an amount heuristic. The exact alternative would be a join to live pick lines, which I didn't design or measure.
- **Q4.** Mixed close: should `completeReversal` also suppress the notice when an earlier row was waived with `stockReturned=false`? That changes complete's behaviour.
- **Q5.** Constant name (first `MOBILE_UI_ACTION_*`) and the grant set that excludes outbound-worker. SET 9 will list the users newly granted.
- **Q6.** Keep the CHECK constraint? It's the only DDL here that can fail, and H2 never sees it.
- **Q7.** Not measured: whether `CustomerorderCancellationLog` is SDR-exported and writable. If it is, the new columns can be written around the gate. Check before the plan claims the waive is gated.
- **Q8.** Fix the existing level-triggered re-enqueue in complete as part of this ticket (same method, shared builder), or propose it separately?
- **Q9.** The mobile-ui waive affordance is a hard dependency before operators can use this. Confirm it's tracked.

## Addendum (main session, 2026-09-26) — Q7 CLOSED

`CustomerorderCancellationLog` is **not** SDR-exported. `RestConfiguration` (origin/develop d9be4188) sets
`config.setRepositoryDetectionStrategy(RepositoryDetectionStrategy.RepositoryDetectionStrategies.ANNOTATED)`, and
`CustomerorderCancellationLogRepository` carries no `@RepositoryRestResource` / `@RestResource` (grep: 0 hits in the file).
Positive control: the same grep over `src/main/java/net/aim_ai/wms/repo` counts 68 `@RepositoryRestResource` annotations, so the
instrument works. Blind spot: an MVC controller elsewhere writing this entity is not ruled out by this check (§0 enumeration found none).

## Resolved decisions (Nam, 2026-09-26) — do not re-open

| # | Question | Decision |
|---|---|---|
| D-a | OMS notify on waive | Operator flag `stockReturned`; true → enqueue ORDER_BATCH_REVERSAL_COMPLETED (shared builder), false → none |
| D-b | Waive marker | New columns via Flyway V2.2.34 DDL, same migration as the function seed |
| Q5 | Grant set | **outbound-manager + super-admin only**; constant `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL` |
| Q2 | Stamp `reversal_completed_at/by` on waive | **Yes**; `reversal_waived=true` is the discriminator |
| Q9 | Mobile UI | **Same ticket, Phase 2 PR in wms2-mobile-ui** (Waive action on the refusal state). Phase 1 = wms2-api |
| Q1 | Case (ii) (stock on tote @100) with stockReturned=true | **Refuse**; stockReturned=false clears 100→0 with no move, no OMS notice |

Defaults taken by the main session (stated, overridable):
- Q3: amount-based ownership rule for the case-(ii) clear, mirroring completeReversal's residue logic.
- Q4+Q8: edge-trigger the OMS enqueue in BOTH waive and complete (enqueue only if this call closed ≥1 row and none remain pending), and suppress the notice when any row on the CO is waived with stockReturned=false. The complete-side re-enqueue defect is sub-T3 and goes on this ticket.
- Q6: keep the CHECK constraint, pinned by the migration IT with SQLSTATE 23514.

## Round-1 review decisions (Nam, 2026-09-26) — settled
- **F4 suppression scope:** whole order, permanently. One `stockReturned=false` waive on any row of a CO ⇒ `ORDER_BATCH_REVERSAL_COMPLETED` is never sent for that CO (applies to both waive and complete).
- **F3 complete trigger:** keep `completeReversal` LEVEL-triggered (retry re-enqueues — the manual re-send path); add only the suppression predicate. This withdraws the "edge trigger in both" half of the Q4+Q8 default. Waive is edge-triggered by its empty-targets early return.
