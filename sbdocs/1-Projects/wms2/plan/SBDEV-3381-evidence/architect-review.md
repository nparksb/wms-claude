**Verdict: SOUND-WITH-CHANGES.** The overall design holds up against the code. But the `onTote` predicate the planner refinements rest on is wrong on every row, and there is a second way for stock to be stranded that the "already waived" term doesn't cover. Both must be fixed before the TDD gate. Everything below was checked against wms2-api `origin/develop` d9be4188, wms2-mobile-ui `origin/develop` 5e99732, and read-only queries on c1wh-shipitez-prd and nywh-hydra-prd.

## Summary
Option 1 is the right shape: stamp `reversal_completed_at`, gate the handler at method level, and share one enqueue method between complete and waive. Two plan problems break the stock-effect logic:
- **F1:** `onTote = su.unitloadId == log.picktounitloadId` compares ids from two different tables, so it is always false. That silently disables row (ii), makes (ii″) catch everything, and turns `waiveLockRetained` into a constant `false`.
- **F2:** `completeReversal`'s residue-restore puts PICKED_FOR_GOODSOUT back on stock that belongs to an already-waived row, and nothing ever releases it.

There are also two Medium design and verification problems (the edge trigger and the SET 9 timing) and some Low test and robustness fixes.

## Antithesis (steelman against Option 1 as drafted)
Waive becomes a second place that releases lock 100, next to complete's clear/restore, and it decides with an amount heuristic. This is the same kind of lock and ownership logic that produced SBDEV-3316, 3326 and 3353. F1 and F2 below show that bugs are already hiding in it.

A narrower Option 1′ would only close records in cases where no stock is left on the tote: (i), (i′), (iii-a), and any SU at amount 0. It would never write a stock unit. Any row with stock still on the tote would be refused.

The argument for it:
- It fixes the live c1wh case completely. All 4 rows are amount 0, lock 2, on Nirwana (queried).
- It cannot mis-release a lock.
- Case (ii) has **zero** live rows on both PRD tenants I queried. It becomes the main input only after SBDEV-3381 item 2, which is already sequenced after this plan. The case (ii) lock release could be designed then, against real rows.

What Option 1′ costs: it leaves case (ii) stranded until item 2, and it contradicts the plan's §1 motive ("Case (ii) is worse").

## Tradeoff tension
Two goals pull against each other: inventory truth ("never release a lock you can't prove you own") and operability ("never strand stock with no operator path out"). `OPERATOR_REMOVABLE = {QUALITY_FAULT, ON_HOLD}`, so whenever the ownership rule declines, the plan closes the row and leaves a lock of 100 that nobody can clear. The stricter the rule, the more permanent strandings it creates.

**Synthesis:**
- Keep the plan's (ii) release, but base it on a correct on-tote test (F1).
- Make complete's restore aware of waived rows (F2), so the only rows left at "retained" are ones where the SU really holds more than this order owns.
- `waiveLockRetained` is then a true signal. Record it (in the response and the `LOG.info`) as the input to a follow-up item: a supervisor-only release of lock 100 behind the new waive function. Don't build that here.

## Findings

**1. HIGH: `onTote` compares a `pickingorder_unitload` id with a `unitload` id, so it is always false.**
- **Claim:** `log.picktounitloadId` is a `pickingorder_unitload.id`, not a unit load id. The one-hop fix (`pickingorder_unitload.unitload_id`) is also unusable, because that link is cleared by the time a reversal runs.
- **Evidence:**
  - `CancellationLogService.java:73`: `log.setPicktounitloadId(pickingPosition.getPicktounitloadId());`
  - The javadoc at `:94`: "`picktounitload_id` is an FK to `pickingorder_unitload`, **not** to `unitload`". At `:108`: "⚠ The hop only resolves while `pickingorder_unitload.unitload_id` is still populated … 0 of 153 at state 700 do".
  - Live c1wh, order 121691091, all 4 rows: `picktounitload_id=121691896`, `pul.unitload_id=NULL`, `pul.state=800`, `su.unitload_id=5069679` (label `Nirwana`), `tote_label_id='C1-0063'`.
- **Effect:**
  - Row (ii) can never match, so every lock-100 SU with stock falls into (ii″) and its lock is never cleared. Case (ii) stays stranded, which is the plan's own headline problem.
  - (iii-b)/(iii-d) "allowed if … not onTote" lets `stockReturned=true` through for QUALITY_FAULT/ON_HOLD stock that is still on the tote.
  - `waiveLockRetained` is always `false`, so the plan's "say so in the response" channel never fires.
- **Fix to §3.2 and §3.4:** Define `onTote` as: the SU's current unit load has `labelid = log.toteLabelId` **and** its type is not `UNIT_LOAD_TYPE_PACKAGE`.
  - Read both from `unitloadRepository.findParcelGuardViewById(su.getUnitloadId())`. It returns scalars (`labelid`, `typeId`), and `SourceContainerGuard.judge` already uses it for the parcel test.
  - `tote_label_id` is populated on 7/7 required rows on Hydra PRD and 4/4 on c1wh PRD (queried).
  - If `toteLabelId` or the view is null, treat on-tote as **unknown**: refuse `stockReturned=true` when amount > 0, and do not clear the lock. That is conservative in both directions.
- **Test fix:** T3, T5 and T21 fixtures must use **different** numeric values for `picktounitloadId` and the SU's `unitloadId`. If they share one `Long`, the wrong comparison passes. Add a mutant that restores the id comparison and confirm it goes red.

**2. HIGH: complete-after-waive on a merged SU strands the waived row's stock at lock 100.**
- **Claim:** The "already waived" term only covers waive-then-waive, not waive-then-complete.
- **Scenario:** Rows A (1 unit) and B (2 units) share one SU (amount 3, lock 100). Waive A with `stockReturned=false`: 3 > 1, so the rule declines, the lock stays and A is closed. Then complete B: `arrivedLocked=true`, it clears, moves 2, and the residue of 1 is re-locked. A is closed, so nothing will ever clear that lock.
- **Evidence:** `CancellationReversalService.completeReversal` residue block: `if (arrivedLocked) { … residue.getAmount().compareTo(amountBeforeTransfer) < 0 && residue.getAmount().compareTo(BigDecimal.ZERO) > 0) { … residue.setEntityLock(PICKED_FOR_GOODSOUT);`. The plan's §6 "What does NOT change" explicitly keeps "the lock clear/restore logic in complete".
- **Fix:**
  - Change complete's restore so it only puts the lock back when stock reserved for still-pending rows remains. Restore only if `residue.amount > Σ amountPicked` over **waived** rows of this order that resolve to the same `picktostockunitId`.
  - Remove that line from §6 "What does NOT change".
  - Add T22 for the scenario above: the residue must end at lock 0. Mutant: the old restore predicate.

**3. MEDIUM: the edge trigger removes complete's only re-send path, to fix a defect the plan rates Low.**
- **Claim:** Today, any later `/complete` call on a fully-closed order re-enqueues the notice. That is the only recovery if the closing call skipped it or the outbox row was lost. The edge trigger (§3.3 condition 1, T19) takes that away permanently.
- **Loss cases:**
  - The sysprop was blank at the closing call. Today's code does `LOG.warn(...); return detail(coId);` and a later retry recovers.
  - Outbox delivery loss. The memory file records the dispatcher as status-blind; I did not re-verify that here.
- **Evidence:** In `completeReversal`, `remaining.isEmpty()` is evaluated even when the loop closed nothing. `OutboxMessageRepository` has only `reclaimStaleInFlight` and `deleteSentOlderThan`, so there is no finder to rebuild "was it ever sent?", and sent rows are purged anyway. §1 itself says OMS "absorbs it, because it is idempotent", so today's behaviour does no harm.
- **Fix (synthesis):**
  - Keep complete **level-triggered**, and add only the suppression predicate (§3.3 condition 3).
  - Waive is edge-triggered by construction, because step 3 returns early when `targets` is empty, so condition 1 adds nothing there.
  - Drop T19 or invert it: "a retry after a blank-sysprop close re-enqueues".
  - Update the §3.3 ⚠ bullets, the ADR "Consequences" and the §1 "Found while reading" paragraph to match.
  - If the edge trigger is kept anyway, state in §3.3 that a blank sysprop at closing time loses the notice permanently.

**4. MEDIUM (design tension; not arguing D-a): suppression covers the whole order and is permanent.**
- **Claim:** One `stockReturned=false` waive suppresses the OMS notice for the order for good. That includes:
  - rows closed later by a real stock movement through complete;
  - rows added by a later partial cancel.
- **Evidence:** §3.3 condition 3 reads every row of `findByCustomerorderId` with no time or episode scope.
- **Why it's open:** D-a (settled) says "notify only when true". Applying it to **complete** is Q4+Q8, which the plan marks overridable.
- **Fix:** Write down in §10 which reading Nam confirmed: "one false waive = OMS is never told this order's reversal finished". UNVERIFIED: whether OMS alerts or reports on parcels whose reversal is still open. If it does, suppression becomes an alert that fires forever on the OMS side.

**5. MEDIUM: M7 and prerequisite 5.1 #7 run audit SET 9 at the wrong time.**
- **Claim:** SET 9 reports users who reach a function through a role but do **not** hold it yet. After V2.2.34 has run, the new step reports 0 rows.
- **Evidence:** `audit-access-invariants.sql:300-305`: `WHERE NOT EXISTS (SELECT 1 FROM holders h WHERE h.user_id = rc.user_id AND h.fn = rc.fn)`.
- **Fix:**
  - M7: run SET 9 on each tenant **before** Phase 1 reaches it, and expect the step to list the newly granted users. Run it again after and expect 0.
  - 5.1 #7: change "SET 9 reports it on deploy" to "run SET 9 before promotion".
  - For PRD, that pre-run is when O2 (`forklift1`) gets reviewed.

**6. LOW: registration completeness; no hidden anti-drift red found.**
- **Evidence:**
  - Method-level replacement is confirmed: `FunctionGuardInterceptor.java:237` `methodLevel = handlerMethod.getMethodAnnotation(RequiresFunction.class)`, then `:265-267` `annotation = methodLevel; if null → AnnotationUtils.findAnnotation(declaring, …)`.
  - AC-4b builds its key as `c.getSimpleName() + "#" + m.getName()` (`FunctionGuardArchTest.java:~960`). That matches `"OrderCancellationController#waiveReversal"`.
  - `declaredFunctionConstants()` is used only by AC-3 (annotation values must be declared constants) and AC-24 (`contains`). No test compares FunctionEnum against a seed list.
  - `ActionGuardAnnotationContractUnitTest` pins 13 handlers on its own two controllers.
  - AC-4 `SHARED_CONTROLLERS` does not apply, because OrderCancellationController is in `GOLDEN_MAP` (`:90`).
  - Mobile `menuCatalog.js:94` lists tiles only.
  - `UserControllerPublicHandlerUnitTest.java:420` `.hasSize(3)` is the pin to change. Its `:440` `hasSize(16)` (the GUARDED count) does not change.
- **Correction:** `MOBILE_UI_ACTION_*` is the first *mobile* action constant, but `WEB_UI_ACTION_*` already exists (V2.2.21, `StockUnitControllerActionGuardUnitTest`). Cite that precedent in §3.5. Blind spot: my search is limited to what grep can see (reflection over `getDeclaredFields`, done at the listed sites).

**7. LOW (verified correct): migration and entity.**
- **Evidence:**
  - The column list `(id, version, client_id, name, number, function)` with `nextval('seqentities'), 0, 0, f.name, f.name, f.name` matches `V2.2.18:22-23`.
  - It also matches base schema `V2.2.00:1442-1451`: `number`, `version`, `function`, `client_id` are NOT NULL, `name` is nullable.
  - The CROSS JOIN grant with `r.name IN (...)` and `NOT EXISTS` matches `V2.2.18:91-99`.
  - H2 risk (a `boolean not null` column with no DB default under create-drop): I found 0 native `INSERT`s into `customerorder_cancellation_log` in src/test or src/main. The positive control is that the table name appears in 3 test files.
  - The CHECK is safe on existing rows.
- **Fix:** none.

**8. LOW (verified correct): §3.2 steps 2–3 and §3.3 flush semantics.**
- **Evidence:**
  - `findPendingReversalsForUpdateByCustomerorderId` is `@Lock(PESSIMISTIC_WRITE)` and filters `reversalRequired = true AND reversalCompletedAt IS NULL`. Under READ COMMITTED, Postgres re-checks locked rows that another transaction updated against the WHERE clause, so a row stamped by a concurrent complete drops out.
  - The unlocked `findByCustomerorderId` runs after the lock is acquired. It returns the already-managed instances for pending rows and the latest committed state for the others.
  - `findPendingReversals` (JPQL) and the derived `findByCustomerorderId` both query the same entity, so FlushMode.AUTO flushes this transaction's stamps before either runs. The plan's claim holds.
- **Fix:** none.

**9. LOW: T4's `never()` on the log save collides with the SBDEV-3316 recovery save in a mock-only unit test.**
- **Evidence:** complete's recovery calls `logRepository.save(log)` **before** the refusal checks. Mocks have no rollback.
- **Fix:** Give T4's unit fixtures a non-null `picktostockunitId`. Move "a refusal rolls back the recovery save" into the Testcontainers lane (T18), asserting the DB value after the 4xx.

**10. LOW: `amountPicked` is nullable, so the ownership sum needs a null guard.**
- **Evidence:** `CustomerorderCancellationLog.java:97` has `@Column(name = "amount_picked", precision = 17, scale = 4)` with no `nullable=false`. Null count on required rows: 0 on Hydra PRD, 0 on c1wh PRD (queried).
- **Fix:** In §3.2, if any contributing row has a null amount, the rule **declines** (lock kept). Pin it in T3.

**11. LOW (mobile): how "completed" is detected.**
- **Evidence:** `store/cancellation.js:326` finds completed rows with `positionIds.indexOf(...) !== -1 && p.reversalCompletedAt`. A waived row satisfies that. Complete is one position per request (`:245-246`, `positionIds: [positionId]`), and refusals are reset at `:227`.
- **Fix:** In §3.8, `waivePosition` must check for `reversalWaived` in the refreshed detail, not only `reversalCompletedAt`. Otherwise a row that another handheld completed at the same moment is reported to the operator as waived. `state.home.functions` exists (`store/home.js:60`), so the function-gated button is feasible as written.

## Recommendations (priority order)
1. Replace the `onTote` definition in §3.2 and §3.4 with the label + not-parcel test from F1, with distinct-id fixtures and the id-comparison mutant. Small effort; it restores all of case (ii).
2. Make complete's residue-restore waive-aware, strike the §6 "does not change" line, and add T22 (F2). Small effort; removes a permanent stranding.
3. Keep complete level-triggered and add suppression only; update T19, §3.3 and the ADR (F3). Small effort; keeps the re-send path.
4. Get Nam's explicit reading of suppression covering the whole order (F4), and move the SET 9 runs to before promotion (F5). Trivial effort.
5. Apply the Low fixes F9–F11 to the §7 test rows and §3.8.

## Trade-offs
| Option | Pros | Cons |
|---|---|---|
| Plan as drafted | Complete fix for (i)–(iii) on paper | The `onTote` bug makes (ii) dead code; F2 strands stock; the re-send path is lost |
| Plan + F1/F2/F3 fixes (recommended) | Case (ii) really works; no new stranding; complete's notify behaviour changes only by suppression | Touches complete's restore logic, which the plan wanted to leave frozen; one extra unit-load view read per SU |
| Option 1′ (close records only, never write a stock unit) | Fixes c1wh; no chance of a wrong lock release | Case (ii) stays stranded until item 2; contradicts §1's case-(ii) motive |

## References
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/service/CancellationLogService.java:73, :94-124` — `picktounitloadId` is a `pickingorder_unitload` id; the hop is cleared at FINISHED
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/service/CancellationReversalService.java` (`completeReversal`) — pre-validate, the clear+flush, the `arrivedLocked` residue restore, and the level-triggered `remaining.isEmpty()` enqueue
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/util/SourceContainerGuard.java` — `findParcelGuardViewById` gives `labelid`/`typeId` as scalars
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/CustomerorderCancellationLogRepository.java` — the FOR UPDATE finder filters to pending rows only
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:237, :265-267` — a method-level annotation replaces the class gate
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/test/java/net/aim_ai/wms/unit/config/FunctionGuardArchTest.java:90, :194, :686-689, :~960` — golden map, declared constants, overrides set, AC-4b key format
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/test/java/net/aim_ai/wms/unit/controller/UserControllerPublicHandlerUnitTest.java:420` — the `hasSize(3)` pin
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/resources/db/migration/V2.2.18__seed_mobile_workflow_functions.sql:22-41, :91-99` and `V2.2.00__base_v2_schema.sql:1442-1451` — seed shape and columns match
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/resources/db/audit-access-invariants.sql:281-305` — SET 9 `NOT EXISTS holders`, so it is only useful before the deploy
- `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java/net/aim_ai/wms/model/CustomerorderCancellationLog.java:97` — `amount_picked` is nullable
- `/Users/np1076/dev/spk/owl/v2/wms2-mobile-ui/store/cancellation.js:227, :245-246, :326`; `store/home.js:60` — refusal reset, one position per request, completion detection, `functions`
- DB (read-only, 2026-09-26): c1wh-shipitez-prd order 121691091 rows 1–4 (pickingorder_unitload 121691896 at state 800 with `unitload_id` NULL; SUs on Nirwana 5069679, amount 0, lock 2). `tote_label_id` and `amount_picked` populated on every required row on c1wh (4/4) and Hydra PRD (7/7).
