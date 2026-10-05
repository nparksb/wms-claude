---
title: "Cancellation reversal WAIVE — POST /v3/cancellation/{customerOrderId}/waive"
ticket: "SBDEV-3381"
ticket_url: "https://app.clickup.com/t/868m61a9t"
type: "feature"
priority: ""
status: "pending approval"
tier: T3
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-26"
updated: "2026-09-26"
db_verified: true
base_commit: "d9be4188 (wms2-api origin/develop) · 5e99732 (wms2-mobile-ui origin/develop)"
related:
  - "[[SBDEV-3313]]"
  - "[[SBDEV-3321]]"
  - "[[SBDEV-3316]]"
  - "[[SBDEV-3326]]"
  - "[[SBDEV-3341]]"
tags:
  - plan
---

# Cancellation reversal WAIVE — `POST /v3/cancellation/{customerOrderId}/waive`

**Ticket:** [SBDEV-3381](https://app.clickup.com/t/868m61a9t) — **item 1 only**
**Project:** wms2 | **Version:** v2 | **Type:** feature | **Tier:** T3 (authz addition + Flyway DDL + data-integrity override of a system refusal + two repos)
**Status:** pending approval
**Date:** 2026-09-26
**Evidence:** `SBDEV-3381-evidence/analysis.md`. Its "Addendum — Q7 CLOSED", "Resolved decisions" and "Defaults taken" sections are settled, and this plan does not re-open them.

---

## 0. Affected Sites

Derivation: the analysis §0.1 greps over the whole wms2-api tree at `origin/develop` d9be4188. I re-checked the rows marked † below with `git show/grep origin/develop`. **Blind spots:** a text grep misses native SQL spelled a different way, and I did not sweep wms2-web-ui. The web UI has no cancellation screen that I know of, but that is not measured.

| # | Site | Disposition | Anchor |
|---|---|---|---|
| 1† | `OrderCancellationController`: class-level `@RequiresFunction(MOBILE_UI_VIEW_CANCELLATION)` | new `/waive` handler | §3.1 |
| 2† | `CancellationReversalService.completeReversal`, including its outbox block | new `waiveReversal`; the outbox block moves into a shared method | §3.2, §3.3 |
| 3† | `toDetailDto` → `entry.setReversalCompletedAt(...)` | map the waive fields | §3.4 |
| 4† | `CustomerorderCancellationLog` (has `@Version`) | 3 columns | §3.4 |
| 5 | `CancellationLogEntryDto` | additive fields | §3.4 |
| 6† | `CancellationCompleteRequest` (pattern only) | new `CancellationWaiveRequest` | §3.1 |
| 7–9† | Repo finders `findPendingReversals`, `findPendingReversalsOlderThan`, `@Lock(PESSIMISTIC_WRITE) findPendingReversalsForUpdateByCustomerorderId` | read-only. #9 is reused as the lock point | §3.2, §3.7 |
| 10 | `scanTote` filter `isReversalRequired() && getReversalCompletedAt()==null` | no change: waived rows drop out because they are stamped | §3.2 |
| 11† | `PendingReversalReconciliationJob` text `"Complete or waive them on the mobile Cancellation screen."` | wording | §3.7 |
| 12 | V2.2.00 partial index `idx_cancel_log_reversal_pending … WHERE reversal_required AND reversal_completed_at IS NULL` | no change. A stamped waive leaves the index, which is the right meaning | §3.6 |
| 13† | `WmsConstants.FunctionEnum` | add a constant | §3.5 |
| 14† | `UtilRestController` initDB `grantFunction(MOBILE_UI_VIEW_CANCELLATION, …)` | add a grant line | §3.5 |
| 15 | new `V2.2.34__cancellation_reversal_waive.sql` | new | §3.6 |
| 16–17 | `AccessAuditService.GATED_WORKFLOWS` and audit SET 4 | **excluded.** They list menu tiles, and a waive is an action inside the tile, so listing it would credit a waive-only user with a whole workflow | §6 |
| 18† | audit SET 9 `steps(...)` in `src/main/resources/db/audit-access-invariants.sql:281` (the SQL file, not `AccessAuditService`) | add a row | §3.5 |
| 19 | audit SET 3 `LIKE 'MOBILE_UI_VIEW_%'` | naming constraint only | §3.5 |
| 20 | `FunctionGuardInterceptor.GUARDED` already contains the controller | no change | — |
| 21† | `FunctionGuardArchTest.REVIEWED_METHOD_LEVEL_OVERRIDES` (AC-4b, exact equality) | **by-design red → update** | §7.3 |
| 22† | `UserControllerPublicHandlerUnitTest` `.hasSize(3)` with the message "three mobile entries" | **by-design red → 4** | §7.3 |
| 23 | Arch AC-2 golden map (class-level) and AC-3 | no change | — |
| 24 | `FunctionGuardMockMvcUnitTest.SURFACE` (one entry per class) | new test method | §7 T11 |
| 25 | `UtilRestControllerUnitTest` C2 | extended separately | §7 T13 |
| 26 | `UtilRestControllerSeedUnitTest` C-8d (migration ↔ initDB parse) | pattern | §7 T14 |
| 27 | `PendingReversalReconciliationJobUnitTest` (0 hits for `waive\|Cancellation screen`, positive-controlled in analysis §0) | extend | §7 T16 |
| 28 | `PendingReversalOlderThanIntegrationTest` | extend | §7 T15 |
| 29 | `PickingorderBusinessService:622` comment "skipping only rows that already carry reversal_completed_at" | stays true | — |
| 31 | `05-verify-bridge.sh` | excluded: it only runs onboarding | — |
| 32† | wms2-mobile-ui `store/cancellation.js` (`SET_REFUSALS` :51; calls :98/111/162/181/315) | Phase 2 | §3.8 |
| 33 | `sbdocs/…/wms2-cancel-cascade-workflow.md` (0 mentions of waive) | doc drift, updated in Phase 1 | §5 |
| 34 | `SurfaceInventoryContextTest`: generated route inventory, **with no count assertion found by grep** | re-run and eyeball it; do not pin it | §7 |

---

## 1. Problem

**A live PRD order cannot be closed today.** On **c1wh-shipitez-prd**, order 121691091 (tote C1-0063) has 4 `customerorder_cancellation_log` rows, ids 1–4, with `reversal_required=true` and `reversal_completed_at IS NULL`. I re-queried them on 2026-09-26. Each row's pick-to stock unit (121691900 / 930 / 950 / 975) is at `amount=0, entity_lock=2` (GOING_TO_DELETE) on the Nirwana unit load. The tenant's Flyway head is 2.2.33. `completeReversal` refuses every row at its pre-validate lock check:

```java
if (sourceLock != null
        && sourceLock != WmsConstants.BusinessObjectLockState.NOT_LOCKED
        && sourceLock != WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT) {
    throw new BusinessException("Reversal for position " + ... + " — manual intervention required");
```

The warehouse already holds exactly the state a successful complete leaves behind, which is a drained SU sent to Nirvana. Hydra PRD's 7 required rows were closed by `completeReversal` on 2026-09-23 and all 7 now point at lock-2 SUs. The c1wh rows are missing only the log stamp and the OMS audit notice.

**The system tells the operator to do something that doesn't exist.** `PendingReversalReconciliationJob` alerts with `"Complete or waive them on the mobile Cancellation screen."` There is no waive endpoint, no waive UI and no function for it. The rows will alert forever. The only way out is hand SQL on PRD, which leaves no audit trail and sends no OMS notice.

**Case (ii) is worse.** When a PICKED_FOR_GOODSOUT (100) SU still has stock on the tote and complete cannot run, the lock has **no operator path out**. `OPERATOR_REMOVABLE = { QUALITY_FAULT, ON_HOLD }`, so `removeLock` refuses 100. That stock is stranded for good.

**Found while reading, sub-T3, on this ticket:** `completeReversal` notifies OMS on a *level* test. It checks that no rows are pending after the call, not that this call closed anything. So a retry whose `positionIds` match only already-completed rows enqueues a second `ORDER_BATCH_REVERSAL_COMPLETED`. OMS absorbs it, because it is idempotent on `parcel.reversal_completed_at`. Severity is low.

---

## 2. Current Architecture

**Controller.** Five handlers carry only the class-level gate. `@RequiresFunction` is ANY-of, and "placed on a method it **replaces** the class default". `ReplenishController` is the precedent: its class is `MOBILE_UI_VIEW_REPLENISHMENT` and `requestLocation`/`requestAmount` override it to `MOBILE_UI_VIEW_REPLENISH_REQUEST`. Errors from `controller.mobile` go through `MobileEndpointExceptionHandler`.

```java
@PostMapping("/{customerOrderId}/complete")
public ResponseEntity<CancellationDetailDto> completeReversal(@PathVariable Long customerOrderId,
        @RequestBody CancellationCompleteRequest request) throws BusinessException, FacadeException {
```

**Lock and filter.** `completeReversal` runs under `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`:

```java
List<CustomerorderCancellationLog> logs = logRepository.findPendingReversalsForUpdateByCustomerorderId(coId);
...
for (CustomerorderCancellationLog log : logs) {
    if (!positionIds.contains(log.getCustomerorderPositionId())) continue;
```

The finder locks only **pending** rows (`reversalRequired = true AND reversalCompletedAt IS NULL`). An id that matches nothing is silently skipped, which is why the mobile store notes "A 200 is NOT proof this position moved". The method pre-validates every row, including the SBDEV-3316 SU-id recovery, which is persisted. It then clears 100→0 and flushes, calls `transferStock`, restores 100 on any residue, and stamps `setReversalCompletedAt(OffsetDateTime.now())` / `setReversalCompletedBy(SecurityContextUtils.getUserName())`.

**Outbox (level-triggered):**

```java
// Enqueue outbox when ALL positions on this CO are complete
List<CustomerorderCancellationLog> remaining = logRepository.findPendingReversals().stream()
    .filter(l -> l.getCustomerorderId().equals(coId)).collect(Collectors.toList());
if (remaining.isEmpty()) {
    ... urlPath = syspropService.getSysvalue(SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED_URL_KEY);
    if (urlPath == null || urlPath.isBlank()) { LOG.warn(...); return detail(coId); }
    ... outboxService.enqueue(OutboxMessage.builder().aggregateType("CUSTOMER_ORDER").aggregateId(coId)
        .processType(ORDER_BATCH_REVERSAL_COMPLETED).destinationUrl(urlPath).payload(MAPPER.writeValueAsString(batchDto)).build());
```

OMS treats the notice as audit only. Its docblock says it "MUST NOT touch product_inventory".

**"Pending" means `reversal_completed_at IS NULL` everywhere I found.** Instrument: the analysis §2.3 grep. The readers are the three finders, `scanTote`, the partial index, and mobile `stillPending = positions.some(p => p.reversalRequired && !p.reversalCompletedAt)`.

**Authz seed today:**

```java
grantFunction(WmsConstants.FunctionEnum.MOBILE_UI_VIEW_CANCELLATION,
        role_inventory_manager, role_outbound_manager, role_outbound_worker, role_super_admin);
```

`UtilRestController` is a `@Service`, so this runs only on a fresh DB, and live tenants get their rows from Flyway. On c1wh, `inventory-manager` does **not** hold VIEW_CANCELLATION (this is the V2.2.18 "OPEN DIVERGENCE").

**Not SDR-exported (Q7 closed).** `RestConfiguration` uses `RepositoryDetectionStrategies.ANNOTATED`, and the repository carries no `@RepositoryRestResource`. Positive control: the same grep finds 68 of those annotations elsewhere under `repo/`. Blind spot: this does not rule out an MVC controller elsewhere writing the entity, but the §0 enumeration found none.

---

## 3. Design

### 3.1 Endpoint and request DTO

```java
@PostMapping("/{customerOrderId}/waive")
@RequiresFunction(WmsConstants.FunctionEnum.MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL)
public ResponseEntity<CancellationDetailDto> waiveReversal(@PathVariable Long customerOrderId,
        @RequestBody CancellationWaiveRequest request) throws BusinessException, FacadeException {
    return ResponseEntity.ok(cancellationReversalService.waiveReversal(customerOrderId,
        request.getPositionIds(), request.getReason(), request.getStockReturned()));
}
```

`CancellationWaiveRequest { List<Long> positionIds; String reason; Boolean stockReturned; }` uses the **boxed** `Boolean` so that an omitted field shows up as null, not a silent `false`.

Validation happens in the service and throws `BusinessException`, so the error shape matches the rest of the controller through `MobileEndpointExceptionHandler`:
- `positionIds` null or empty → `"positionIds required"`
- `reason` null or `isBlank()` → `"reason required"`
- `stockReturned == null` → `"stockReturned required"`

The method-level annotation **replaces** the class gate. That means a holder of only the waive function could call `/waive` without VIEW. This is controlled through the grant set (§3.5), not an in-service AND check. Alternative F in §9 explains why.

### 3.2 `CancellationReversalService.waiveReversal`

Signature: `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class}) CancellationDetailDto waiveReversal(Long coId, List<Long> positionIds, String reason, Boolean stockReturned)`.

1. **Validate** the input as in §3.1.
2. **Lock:** `pending = findPendingReversalsForUpdateByCustomerorderId(coId)`. This is the same finder and lock point as complete. Under READ COMMITTED, a waive that blocks behind a complete re-evaluates the predicate and does not see a row the other transaction stamped, and the reverse holds too. The wait is bounded by the tenant `lock_timeout` per acquisition. `@Version` is a second layer.
3. **Resolve ids.** Load `all = findByCustomerorderId(coId)`, which does not lock.
   - An id that is on no row of this CO → `BusinessException("position X is not on order Y")`. This deliberately differs from complete's silent skip.
   - An id on a row that is not pending (already completed, already waived, or `reversal_required=false`) → no-op.
   - `targets = pending ∩ positionIds`. If `targets` is empty, return `detail(coId)` with no writes and no enqueue.
4. **Pre-validate all targets, and write nothing yet except the 3316 recovery.**
   - For each target, run the SBDEV-3316 SU-id recovery. Extract it from complete into a private helper, `recoverPickToStockunitId(log)`, and have both callers use it.
   - Load the SU. It may be absent.
   - If `stockReturned == true` and the §3.2 table says refuse, throw a `BusinessException` naming the position, SU id, lock text (`getCodeTextOrUnknown`) and amount. `rollbackFor` undoes the recovery save, so **a refused waive commits nothing**.
5. **Write.**
   - For each SU the table marks "clear 100 → 0": `setEntityLock(NOT_LOCKED)`, then save. **No `transferStock`, no stock-change message.** Complete sends none either, and OMS already returned that inventory when the order was cancelled.
   - For each target row: `reversalCompletedAt = now`, `reversalCompletedBy = SecurityContextUtils.getUserName()`, `reversalWaived = true`, `reversalWaiveReason = reason.trim()`, `reversalWaiveStockReturned = stockReturned`. Then save.
   - Log order is unchanged: log rows are locked first, then the stockunit is updated.
6. **Notify:** `enqueueReversalCompletedIfClosed(coId, targets.size())` (§3.3). Log `LOG.info("waiveReversal order={} positions={} stockReturned={} lockCleared={} by={}")`.
7. Return `detail(coId)`.

**Stock-effect table.** Rules: never move stock; only ever release PICKED_FOR_GOODSOUT (100); never touch a lock another process owns. `onTote` = `su.unitloadId == log.picktounitloadId`.

| Case | Pick-to SU | Write to stock | `stockReturned=true` | `stockReturned=false` |
|---|---|---|---|---|
| (i) live c1wh | amount 0, lock 2 (Nirwana) | none | allowed | allowed |
| (i′) | amount 0, lock 0 or 100 | clear 100→0 (nothing is reserved on a zero-amount row) | allowed | allowed |
| (ii) | amount > 0, lock 100, onTote | **clear 100→0 only if the ownership rule holds**; otherwise leave it | **refuse** (Q1) | allowed |
| (ii′) | amount > 0, lock null or 0, onTote | none | refuse | allowed |
| (ii″) | amount > 0, lock 100, **not** onTote (e.g. re-homed into a parcel) | **none** — a lock off the tote belongs to whichever process moved it | refuse | allowed |
| (iii-a) | SU missing or id unresolvable | none (persist the recovered id) | allowed | allowed |
| (iii-b) | QUALITY_FAULT / ON_HOLD | none (`removeLock` already covers these) | allowed if amount 0 or not onTote, else refuse | allowed |
| (iii-c) | SHIPPED (405) | none | **refuse** | allowed |
| (iii-d) | 403 / 404 / other | none | as (iii-b) | allowed |

Row (ii″) and the explicit (ii′) row are planner refinements of analysis §3. They follow its "never touch a lock another process owns" rule, which is settled. The Architect should challenge them.

**Ownership rule for (ii).** Clear only if `su.amount <= Σ amountPicked` over the rows of **this CO** that resolve to that SU **and** are either waived in this call or already waived. Planner refinement: the "already waived" term keeps a two-step waive of a merged SU from stranding it. Completed rows are excluded, because their stock already left the SU. This mirrors complete's residue logic, where two picks of one SKU into one tote merge into one SU. If the rule declines, leave the lock, still close the row, and report it through `waiveLockRetained` (§3.4). Blind spot: this is an amount heuristic, not a join to live pick lines (Q3, default taken).

### 3.3 Shared OMS enqueue (complete and waive) — edge-triggered

Extract the outbox block into `private void enqueueReversalCompletedIfClosed(Long coId, int closedThisCall)`. Both callers use it, so the payload cannot drift. It enqueues only when **all** of these hold:

1. `closedThisCall > 0` (edge trigger);
2. no pending rows remain for the CO. Keep the existing `findPendingReversals().stream().filter(coId)` query: JPQL auto-flushes this transaction's stamps first, and it also catches a pending row that the FOR UPDATE snapshot didn't include;
3. **no** row on the CO has `reversalWaived && Boolean.FALSE.equals(reversalWaiveStockReturned)` (read from `findByCustomerorderId`);
4. the sysprop URL is non-blank. If it is blank, keep today's `LOG.warn` and skip.

The payload is byte-identical to today's: `OrderBatchDto{batchId, facilityCode=MULTIWAREHOUSE_IDENTIFIER, positions=[OrderDto{uniqueId=externalnumber, positions=[]}]}`. It is written in the same transaction through the transactional outbox.

**⚠ This changes `completeReversal`'s behaviour in two ways:**
- A complete call that closes 0 rows no longer re-enqueues. This fixes the retry defect from §1.
- A complete that closes the last pending row sends **no** notice if an earlier row on that CO was waived with `stockReturned=false`.

Both follow the Q4+Q8 default the main session took, and T19/T20 pin them.

### 3.4 Entity / DTO (additive)

- **`CustomerorderCancellationLog`:**
  - `@Column(name="reversal_waived", nullable=false) private boolean reversalWaived = false;`
  - `@Column(name="reversal_waive_reason", columnDefinition="TEXT") String reversalWaiveReason;`
  - `@Column(name="reversal_waive_stock_returned") Boolean reversalWaiveStockReturned;`
  - "Waived by/at" are `reversal_completed_by/at`, per settled Q2.
- **`CancellationLogEntryDto`** gains `reversalWaived`, `waiveReason`, `waiveStockReturned`, and `waiveLockRetained`.
  - `waiveLockRetained` is computed in `toDetailDto` only for waived rows: `su != null && su.entityLock == 100 && su.amount > 0 && onTote`. It adds one `findById` per waived row. Planner refinement: it is the "say so in the response" channel.
- `toDetailDto` maps all four fields.

### 3.5 Authz registration — the five places, derived from how existing constants are wired

1. `FunctionEnum.MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL = "MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL"`. It is the first `MOBILE_UI_ACTION_*` constant and it avoids SET 3's `LIKE 'MOBILE_UI_VIEW_%'`. No code prefix-matches on these names: `startsWith("MOBILE_UI|WEB_UI")` returns 0 hits in src/main and 0 in mobile-ui. Blind spot: prefix matching spelled another way, such as a regex.
2. initDB: `grantFunction(…WAIVE…, role_outbound_manager, role_super_admin);`, with a comment citing SBDEV-3381 Q5.
3. The V2.2.34 function row plus the same two grants (§3.6).
4. `@RequiresFunction` on the handler (§3.1).
5. `audit-access-invariants.sql` SET 9: `('step5_WAIVE_CANCELLATION', 'MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL', ARRAY['outbound-manager','super-admin'])`.

Not added: GATED_WORKFLOWS and SET 4 (§0 #16–17), and `SdrRuleStartupAssertion` (it only validates SDR rules).

Test-side updates in the same commit: `REVIEWED_METHOD_LEVEL_OVERRIDES` += `"OrderCancellationController#waiveReversal"`, and `UserControllerPublicHandlerUnitTest` `hasSize(3)` → `hasSize(4)`, with its message changed to "four mobile entries".

### 3.6 Flyway `V2.2.34__cancellation_reversal_waive.sql`

Conventions: `ADD COLUMN IF NOT EXISTS` (V2.2.31), seeds via `WHERE NOT EXISTS` and never `ON CONFLICT` (V2.2.18: the PK name drifts or is absent), and the CHECK is inside a `pg_constraint`-guarded `DO` block.

```sql
ALTER TABLE public.customerorder_cancellation_log
  ADD COLUMN IF NOT EXISTS reversal_waived boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS reversal_waive_reason text,
  ADD COLUMN IF NOT EXISTS reversal_waive_stock_returned boolean;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_cancel_log_waive_complete') THEN
    ALTER TABLE public.customerorder_cancellation_log ADD CONSTRAINT ck_cancel_log_waive_complete
      CHECK (NOT reversal_waived OR (reversal_completed_at IS NOT NULL
             AND btrim(reversal_waive_reason) <> '' AND reversal_waive_stock_returned IS NOT NULL));
  END IF;
END $$;

INSERT INTO mywms_function (id, version, client_id, name, number, function)
SELECT nextval('seqentities'), 0, 0, f.name, f.name, f.name
FROM (VALUES ('MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL')) f(name)
WHERE NOT EXISTS (SELECT 1 FROM mywms_function e WHERE e.function = f.name OR e.name = f.name);

INSERT INTO mywms_role_mywms_function (rolelist_id, functionlist_id)
SELECT r.id, f.id FROM mywms_role r CROSS JOIN mywms_function f
WHERE f.name = 'MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL' AND r.name IN ('outbound-manager','super-admin')
  AND NOT EXISTS (SELECT 1 FROM mywms_role_mywms_function x WHERE x.rolelist_id = r.id AND x.functionlist_id = f.id);
```

- `NOT NULL DEFAULT false` does not rewrite the table on PG ≥ 11, and the table holds ≤ 17 rows on the measured tenants.
- The CHECK is the riskiest statement, because a failed tenant migration silently freezes that tenant. It cannot fail on the measured tenants: every existing row gets `reversal_waived=false`, which satisfies it.
- V2.2.28 and V2.2.31 already ALTERed this table fleet-wide. That is evidence, not proof, that table ownership won't block this migration.
- The H2 lane (`create-drop`, Flyway off) never sees the CHECK. Only T17 does.

### 3.7 `PendingReversalReconciliationJob` wording

Replace `"Complete or waive them on the mobile Cancellation screen."` with `"Complete them on the mobile Cancellation screen, or have an outbound manager waive them there (Waive)."` Update the tail text, which quotes `WHERE reversal_required AND reversal_completed_at IS NULL`, to append `(waived rows carry reversal_waived=true and are excluded)`.

Waived rows drop out of `findPendingReversalsOlderThan` without any query change, because waive stamps `reversal_completed_at`. T15 pins this.

### 3.8 Phase 2 — wms2-mobile-ui

- `store/cancellation.js`: new action `waivePosition({ coId, positionId, reason, stockReturned })` that calls `POST /cancellation/${coId}/waive` with `{ positionIds: [positionId], reason, stockReturned }`. It works one position per request, like complete.
  - On 200: refresh the detail and clear that position's `SET_REFUSALS` entry. The server's refusal message is surfaced through the existing error path.
  - `stillPending` needs no change, because waive stamps `reversalCompletedAt`.
- `components/cancellation/cancellationDetail.vue` / `cancellationAction.vue`:
  - Show a **Waive** action on a position that is in the refusal state.
  - Show it only when `state.home.functions` includes `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL`. This is a UI affordance; the server gate is authoritative.
  - A prompt collects the reason (required, non-blank) and "Was the stock returned to the bin?" as an explicit yes/no with no default.
  - Waived rows render a "Waived" badge with the reason, plus a warning when `waiveLockRetained`.
- Tests (Jest):
  - The store posts the exact body.
  - The button is hidden without the function.
  - The prompt blocks a blank reason and an unanswered stockReturned.
  - The refusal message is surfaced.
  - Each assertion is mutation-checked.

---

## 4. File Change Summary

| Repo | File | Change |
|---|---|---|
| wms2-api | `controller/mobile/OrderCancellationController.java` | `/waive` handler + method-level gate |
| wms2-api | `json/CancellationWaiveRequest.java` | new |
| wms2-api | `json/CancellationLogEntryDto.java` | +4 fields |
| wms2-api | `model/CustomerorderCancellationLog.java` | +3 columns |
| wms2-api | `service/CancellationReversalService.java` | `waiveReversal`; extract `recoverPickToStockunitId` + `enqueueReversalCompletedIfClosed`; edge trigger in complete; `toDetailDto` mapping |
| wms2-api | `service/WmsConstants.java` | FunctionEnum constant |
| wms2-api | `controller/rest/UtilRestController.java` | initDB grant |
| wms2-api | `schedulejob/PendingReversalReconciliationJob.java` | wording |
| wms2-api | `resources/db/migration/V2.2.34__cancellation_reversal_waive.sql` | new |
| wms2-api | `resources/db/audit-access-invariants.sql` | SET 9 row |
| wms2-api | tests: `CancellationReversalServiceUnitTest`, new `OrderCancellationControllerUnitTest`, `FunctionGuardMockMvcUnitTest`, `FunctionGuardArchTest`, `UserControllerPublicHandlerUnitTest`, `UtilRestControllerUnitTest`, `UtilRestControllerSeedUnitTest`, `PendingReversalReconciliationJobUnitTest`, `PendingReversalOlderThanIntegrationTest`, `CancellationLogEntryDtoSerializationTest`, new `CancellationWaiveMigrationIT`, new/extended Testcontainers cancellation IT | §7 |
| wms2-mobile-ui | `store/cancellation.js`, `components/cancellation/cancellationDetail.vue`, `cancellationAction.vue`, `test/store/cancellationWaive.spec.js` (new), a component spec | §3.8 |
| sbdocs | `3-Resources/workflows/wms2-cancel-cascade-workflow.md`, `wms2-function-to-docs-map.md` §9 | waive section; bump `last_verified` |

---

## 5. Phases

**Scope fence:** this plan is **SBDEV-3381 item 1 only**. Items 2–6 of SBDEV-3381 are **out of scope** and must ship **after** this plan. Item 2, fencing the cancel lock-clear sites, makes case (i) rarer and case (ii) the main waive input, so the waive has to exist first.

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | Tenant Flyway head at 2.2.33, new file V2.2.34. **Sweep (2026-09-26):** `git fetch origin; for r in $(git for-each-ref --format='%(refname)' refs/remotes/); do git ls-tree --name-only "$r" src/main/resources/db/migration/ \| sed -n 's#.*/V\(2\.2\.[0-9]*\)__.*#\1#p'; done \| sort -t. -k3 -n -u \| tail -3` → `2.2.31 2.2.32 2.2.33` over **345** remote refs. A second loop grepping `V2\.2\.34__` on every ref → 0 hits. `origin/develop` = d9be4188. c1wh prd head = 2.2.33 (queried). | executor | Perishable: a branch pushed later is invisible to this sweep. **Re-run it immediately before opening the PR** and renumber if needed |
| 2 | **Feature flags / sysprops** | `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` URL sysprop is already used by complete; no new sysprop | — | A blank value → warn and skip, same as today |
| 3 | **Config / env** | N/A — no property, Keycloak or env change: the gate is a WMS function and the columns come from Flyway | — | |
| 4 | **Deploy order** | Phase 1 (api) merges and deploys **before** Phase 2 (mobile-ui). A mobile build calling `/waive` against an older api gets a 404 | Nam | The mobile button is function-gated, so shipping it early only shows a dead button to holders of the function |
| 5 | **Data migration** | None beyond V2.2.34 (defaults only). The c1wh 4-row cleanup is an **operator waive**, not SQL (§8) | — | |
| 6 | **External systems** | OMS `batchReversalCompleted` is already live and idempotent on `parcel.reversal_completed_at`; no OMS change | — | UAT check in the manual plan |
| 7 | **Access / permissions** | New function granted to `outbound-manager` + `super-admin` via V2.2.34 and initDB. **No Keycloak change.** On c1wh prd this reaches 4 outbound-manager users (`cloverdale-qa1`, `cloverdale-qa2`, `forklift1`, `rlangston`) plus the super-admin holders (queried 2026-09-26; SET 9 reports it on deploy) | Nam | `forklift1` holding outbound-manager is pre-existing, but it is surfaced here (§10) |
| 8 | **Monitoring / alerts** | N/A — no metric (nothing scrapes Prometheus); the reconciliation job's alert is the existing signal and stops firing for waived rows | — | |

### 5.2 Phase 1 — wms2-api (`feature/SBDEV-3381-waive` off freshly fetched `origin/develop`, worktree `.claude/worktrees/wms2-api/SBDEV-3381`)

- [ ] Floor: re-run the c1wh query (§8) and record it.
- [ ] Failing tests first: T1–T21. Confirm each fails for the right reason. Expected reds before the implementation: T21/AC-4b and the size pin go red only once the handler exists, which is by design.
- [ ] Refactors that keep behaviour: `recoverPickToStockunitId`, and `enqueueReversalCompletedIfClosed` with the edge trigger. The existing complete tests must stay green except where T19/T20 intentionally change behaviour.
- [ ] `waiveReversal`, the DTO/entity, the controller.
- [ ] FunctionEnum, initDB, V2.2.34, SET 9, the job wording.
- [ ] Update the arch pins (§7.3).
- [ ] `mvn clean verify` in both lanes vs a baseline taken adjacent in time; PIT or a hand mutant per new assertion.
- [ ] Doc updates (§4). Four independent review lanes (T3), each writing a file. Fix every finding, including Lows.
- [ ] Re-sweep Flyway (5.1 #1), then open a PR into `develop`.

**Acceptance:** T1–T21 green; the two by-design reds updated in the same commit; full suite ≥ baseline; V2.2.34 applies on a Testcontainers tenant and re-applies idempotently.

### 5.3 Phase 2 — wms2-mobile-ui (branch `feature/SBDEV-3381-waive` off fresh `origin/develop`)

- [ ] Jest specs first (§3.8), then the implementation. Mutation-check each assertion.
- [ ] Headless-browser smoke on dev once Phase 1 is on dev (`wms2-web-ui-headless-browser-recipe` pattern).
- [ ] PR into `develop` after Phase 1 is merged and `/api/public/version` on dev shows its SHA.

**Acceptance:** Jest green; the button appears only for a waive holder; the dev smoke (M2) passes.

---

## 6. Backward Compatibility

- **API:** one new route. `CancellationLogEntryDto` gains 4 additive fields. `CancellationLogEntryDtoSerializationTest` pins individual keys, not a closed key set. The list and detail DTOs are otherwise unchanged.
- **DB:** 3 nullable/defaulted columns and a CHECK that every existing row satisfies. Existing rows read `reversal_waived=false`.
- **OMS:** the payload is byte-identical. The only change is **when** it is sent (§3.3).
- **Behaviour change in complete:** no re-enqueue when a call closes 0 rows, and suppression after a `stockReturned=false` waive. Both are deliberate.

### What does NOT change

- `transferStock`, the complete movement loop, and the lock clear/restore logic in complete.
- The finders, the partial index, `scanTote`, `detail`'s query, and mobile `stillPending`. The stamp keeps "pending" meaning the same everywhere found in §2.3.
- The class gate `MOBILE_UI_VIEW_CANCELLATION`, `GUARDED`, `GATED_WORKFLOWS`, and audit SET 4.
- `removeLock` / `OPERATOR_REMOVABLE`. Waive does not widen the operator unlock surface; it releases 100 only inside a waive, under the ownership rule.
- Keycloak roles and groups.

---

## 7. Testing

### 7.1 Tests and the mutation each must kill

| # | Class / lane | Asserts | Mutation it must kill |
|---|---|---|---|
| T1 | `CancellationReversalServiceUnitTest` | Live case (i): rows stamped `completedAt/By`, `waived=true`, reason and stockReturned persisted; `stockunitRepository.save` and `transferStock` never called | delete the stamp; write to the lock-2 SU |
| T2 | same | Case (ii) with `stockReturned=false`: lock 100→0, no `transferStock` | drop the clear |
| T3 | same | Ownership: SU.amount > Σ picked → lock kept, row closed, `waiveLockRetained=true`; `==` → cleared | `<=`→`<`; always clear; drop the already-waived term |
| T4 | same | `stockReturned=true` refused for (ii), (ii′), (ii″) and SHIPPED; **no** row saved and no SU saved (verify `never()`) | refuse after the writes; drop one refusal branch |
| T5 | same | QUALITY_FAULT / ON_HOLD / 403 / 404 locks untouched; (ii″) lock 100 off-tote untouched | clear any non-100 lock; drop the onTote check |
| T6 | same | Last row closed with `stockReturned=true` → exactly one enqueue, payload equal (JSON string) to complete's; `false` → none | drop either condition; payload drift |
| T7 | same | A second waive of the same ids → no writes, no enqueue | level trigger |
| T8 | same | Blank reason (`"  "`), empty ids, null stockReturned, id not on this CO → `BusinessException`, nothing saved | `isBlank`→`isEmpty`; silent skip of an unknown id |
| T9 | same | Uses `findPendingReversalsForUpdateByCustomerorderId` (verify), not `findPendingReversals` for the lock | swap the finder |
| T10 | new `OrderCancellationControllerUnitTest` (`BaseControllerUnitTest`) | JSON body binds `positionIds`/`reason`/`stockReturned` and reaches the service; omitted `stockReturned` arrives as null | rename a field; primitive `boolean` |
| T11 | `FunctionGuardMockMvcUnitTest` (new method) | VIEW-only holder → 403 on `/waive`; waive holder → 200; VIEW holder still 200 on `/complete` | delete the method annotation; wrong constant |
| T12 | `FunctionGuardArchTest` AC-4b + `UserControllerPublicHandlerUnitTest` | override set = the 4 entries; size 4 | — (pins; §7.3) |
| T13 | `UtilRestControllerUnitTest` (new block) | initDB grants waive to exactly {outbound-manager, super-admin} | add outbound-worker |
| T14 | `UtilRestControllerSeedUnitTest` (C-8d style) | V2.2.34's role set == the initDB role set, comment-stripped | drop a role on one side |
| T15 | `PendingReversalOlderThanIntegrationTest` | waived+stamped row excluded; an un-waived row in the same test is returned (positive control) | stop stamping on waive |
| T16 | `PendingReversalReconciliationJobUnitTest` | new wording contains "waive" and "outbound manager" | revert the text |
| T17 | new `CancellationWaiveMigrationIT` (watermark pattern of `CancellationLogPickingorderPositionIdIT`) | at 2.2.33 the columns are absent; at 2.2.34 present with default false; function row + exactly 2 grants; re-run is idempotent; CHECK violation asserted by **SQLSTATE 23514**, not by message | drop DEFAULT; drop the CHECK; `ON CONFLICT` seed |
| T18 | Testcontainers IT (tenant tx) | waive→complete and complete→waive on a 2-row CO each produce exactly one outbox row; a waived row cannot then be completed | level trigger; a finder without the stamp predicate |
| T19 | `CancellationReversalServiceUnitTest` | **complete** retry whose ids match only completed rows → no enqueue | restore the level trigger in complete |
| T20 | same | complete closing the last row after a `stockReturned=false` waive → no enqueue | drop the suppression predicate |
| T21 | `CancellationLogEntryDtoSerializationTest` | the 4 new keys serialize; `waiveLockRetained` is computed only for waived rows | drop a mapping in `toDetailDto` |

No thread-race IT: two existing concurrency ITs are known to be timing-flaky. T18 plus the shared FOR UPDATE finder (T9) cover ordering deterministically. A reviewer may dispute this.

### 7.2 Mutation discipline

Break each new assertion's target and confirm it goes red. Use PIT scoped to `CancellationReversalService` where it applies, and hand mutants otherwise. Record the kill per row.

### 7.3 Known by-design reds (update in the same commit)

- `FunctionGuardArchTest.REVIEWED_METHOD_LEVEL_OVERRIDES` (AC-4b, exact equality) → add `"OrderCancellationController#waiveReversal"`.
- `UserControllerPublicHandlerUnitTest` `.hasSize(3)` → `.hasSize(4)`, with the message changed to "four mobile entries".
- Any other red is a real finding, not a pin to re-baseline.

### 7.4 Manual Test Plan

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| M1 | Replay of the c1wh case | DEV/UAT fixture | Build a CO with 2 reversal rows whose pick-to SUs are amount 0 / lock 2; `POST /complete` → refused; `POST /waive` with `stockReturned=true` as an outbound-manager | complete 4xx "manual intervention required"; waive 200; both rows stamped, `reversal_waived=true`; 1 outbox row | |
| M2 | Mobile happy path | dev | Scan tote → position refused → Waive → reason + "yes" | the badge shows; the order leaves the list | |
| M3 | Case (ii) | UAT fixture | SU amount 2 lock 100 on the tote; waive `stockReturned=true` → refused; retry with `false` | refused and nothing written; then lock 0, amount unchanged; Move Stock can move it | |
| M4 | Gate | dev | outbound-worker calls `/waive` | 403; the button is hidden | |
| M5 | OMS UAT | UAT OMS | After M1 on UAT, check the OMS parcel for the CO | `parcel.reversal_completed_at` stamped and a status-history row written; product_inventory unchanged | |
| M6 | Migration SQL | UAT tenant DB | `SELECT column_name FROM information_schema.columns WHERE table_name='customerorder_cancellation_log' AND column_name LIKE 'reversal_waive%'`; `SELECT count(*) FROM mywms_role_mywms_function rf JOIN mywms_function f ON f.id=rf.functionlist_id WHERE f.name='MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL'` | 2 columns (+ `reversal_waived`); 2 grants | |
| M7 | Audit SET 9 | UAT | run `audit-access-invariants.sql` | `step5_WAIVE_CANCELLATION` lists the newly granted users | |

### 7.5 Horizontal Scalability

| # | Concern | Verdict | Rationale / evidence |
|---|---|---|---|
| 1 | In-JVM state | No | stateless service method |
| 2 | Connection pool | No | one tenant tx per request, same as complete |
| 3 | Scheduled jobs | No | wording change only; the exclusion comes free (T15) |
| 4 | Long transactions | No | no transfer and no external I/O; fewer writes than complete |
| 5 | Request affinity | No | stateless |
| 6 | Retry / idempotency | **Yes** | a re-waive is a no-op; the edge trigger stops a re-enqueue (T7, T19) |
| 7 | Tenant context | No | request thread only, no async |
| 8 | Distributed lock | **Yes** | the same `PESSIMISTIC_WRITE` finder as complete, inside `tenantTransactionManager`; `lock_timeout` bounded; `@Version` (T9, T18) |
| 9 | Cache | N/A | not measured against `wms2-caching-strategy.md`; the log entity and stockunit are not known to be Caffeine-cached — the executor confirms by grep |
| 10 | External notification | **Yes** | transactional outbox row in the same tx; dispatch is async (T6, T18) |

### 7.6 v2-only constraints

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV off | handled — everything is loaded inside the service tx; `detail` has its own readOnly tx |
| 2 | Tenant tx manager | yes — `value="tenantTransactionManager"` + rollbackFor for both exception types |
| 3 | readOnly reads | N/A — a write path |
| 4 | Caffeine | N/A (§7.5 #9) |
| 5 | Micrometer | No — low-frequency, and nothing scrapes metrics; `LOG.info` is the breadcrumb |
| 6 | Jakarta | yes |
| 7 | H2-compatible SQL | yes — the JPQL is unchanged; the CHECK is covered only by T17 (Testcontainers) |
| 8 | Controller test base | `BaseControllerUnitTest` (T10); the gate is covered by T11 because `setupMockMvc` installs no interceptor |

---

## 8. Rollout

1. Phase 1 PR into **`develop` only**. Release and main belong to DevOps. **Merging to develop is a dev deploy plus a Flyway run** on every dev tenant at boot. Afterwards, confirm `/api/public/version` shows the merge SHA and that `flyway_schema_history` on a dev tenant is at 2.2.34.
2. Phase 2 PR into mobile-ui `develop` after step 1 is verified on dev. Beware the back-to-back `:develop` tag race.
3. UAT: M1, M3, M5, M6, M7.
4. **After PRD promotion (DevOps), close the c1wh case.**
   - **Who:** a c1wh outbound-manager waives rows 1–4 of order 121691091 through the mobile screen, with `stockReturned=true` and a reason citing SBDEV-3381. I propose `rlangston`, who holds both outbound-manager and super-admin on c1wh prd; Nam confirms the operator. `stockReturned=true` is allowed because this is case (i): amount 0, lock 2.
   - **Verify by query** on c1wh-shipitez-prd:
     ```sql
     SELECT id, reversal_completed_at IS NOT NULL AS stamped, reversal_completed_by, reversal_waived, reversal_waive_stock_returned
     FROM customerorder_cancellation_log WHERE customerorder_id = 121691091;           -- expect 4 × (t, <user>, t, t)
     SELECT count(*) FROM outbox_message WHERE aggregate_id = 121691091
       AND process_type = 'ORDER_BATCH_REVERSAL_COMPLETED';                             -- expect 1, then status SENT
     ```
   - Then check that the PRD OMS parcel shows `reversal_completed_at`. An outbox status of SENT is not proof of delivery. Finally, confirm the next reconciliation-job run no longer lists c1wh.
5. Items 2–6 of SBDEV-3381 are planned only after step 4 is done.

---

## 9. Alternatives

| # | Alternative | Verdict |
|---|---|---|
| A | Force complete (skip the lock check) | Rejected — there is nothing to move on a Nirvana row, and case (ii) would move stock the system can't vouch for |
| B | A marker in the `reversal_notes` text | Rejected (D-b) — unqueryable, and overwritten by the next note |
| C | Don't stamp `reversal_completed_at`; filter on `reversal_waived` everywhere | Rejected (Q2) — 3 JPQL predicates, `scanTote`, a new index and mobile `stillPending`, and every future pending query must remember the extra predicate |
| D | Reuse the VIEW gate | Rejected (Q5) — hands a supervisor override to every outbound-worker |
| E | Whole-order waive (no `positionIds`) | Rejected — it would force waiving positions that could still be reversed |
| F | Class gate plus an in-service AND check | Rejected — invisible to `SurfaceInventoryContextTest` ("Gate detection is ANNOTATION-ONLY") and to every anti-drift pin |

---

## 10. Open Questions / Resolved Decisions

**Resolved (Nam, 2026-09-26; settled):** D-a (`stockReturned` flag → notify only when true); D-b (columns via V2.2.34); Q5 (outbound-manager + super-admin; `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL`); Q2 (stamp `reversal_completed_at/by`, with `reversal_waived` as the discriminator); Q9 (mobile Phase 2 on this ticket); Q1 (case (ii) with `stockReturned=true` → refuse); Q7 (not SDR-exported).

**Defaults taken (stated, overridable):** Q3 (amount-based ownership rule); Q4+Q8 (edge trigger and suppression in both complete and waive; the complete defect goes on this ticket); Q6 (keep the CHECK, pinned by SQLSTATE 23514).

**Still open:**
- **O1.** Planner refinements for the Architect to challenge:
  - (ii″) — never clear 100 off the tote;
  - the already-waived term in the ownership sum;
  - the computed `waiveLockRetained` field.
- **O2.** `forklift1`, a shared-looking account name, holds outbound-manager on c1wh prd, so it gains the waive override. This is a pre-existing grant, and SET 9 will list it. Does Nam want it reviewed before PRD promotion?
- **O3.** Mobile prompt wording for `stockReturned`, which is operator-facing. The draft is "Was the stock returned to its bin?".

---

## Layer-2 Completeness Checklist

| # | Item | Status |
|---|---|---|
| 1 | Every §0 site mapped or excluded | ✓ §0 |
| 2 | Sibling sweep (other readers of "pending") | ✓ §2, §6 "does not change" |
| 3 | Transaction manager + rollbackFor | ✓ §3.2 |
| 4 | Concurrency / lock point | ✓ §3.2 step 2, T9, T18 |
| 5 | Flyway version swept on all refs | ✓ §5.1 #1 |
| 6 | Migration idempotent + lane coverage | ✓ §3.6, T17 |
| 7 | Authz — five registration points + pins | ✓ §3.5, T11–T14 |
| 8 | OMS / outbox effect | ✓ §3.3, T6, T19, T20, M5 |
| 9 | Mobile/UI dependency | ✓ §3.8, Phase 2 |
| 10 | Verify script | no — T3 opt-in declined; every assertion is a JUnit/IT/Jest test |
| 11 | Docs drift | ✓ §4 (cancel-cascade workflow, function-to-docs map) |

---

## ADR

- **Decision:** Add `POST /v3/cancellation/{coId}/waive`, gated at method level by `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL` (outbound-manager, super-admin).
  - It closes the selected pending reversal rows by stamping `reversal_completed_at/by` plus `reversal_waived`, the reason and `stock_returned`.
  - It never moves stock.
  - It only releases PICKED_FOR_GOODSOUT on the tote under an ownership rule.
  - It refuses `stockReturned=true` when stock is still on the tote or SHIPPED.
  - It notifies OMS through a shared, edge-triggered outbox method that `completeReversal` now uses too.
- **Drivers:** (1) a live PRD order (c1wh) that cannot be closed, and an alert telling operators to use a function that doesn't exist; (2) inventory truth — never fabricate a stock movement, and never steal a lock another process owns; (3) the authz surface stays visible to the annotation-based gate rails.
- **Alternatives considered:** A–F in §9.
- **Why chosen:** Stamping the existing column makes all six readers of "pending" correct without change. The FOR UPDATE finder gives waive and complete mutual exclusion for free. A method-level annotation is the pattern the gate rails already understand (ReplenishController).
- **Consequences:**
  - `reversal_completed_at` now means "closed", not "moved"; `reversal_waived` is the discriminator.
  - `completeReversal` stops re-enqueueing on a retry and is suppressed after a `stockReturned=false` waive.
  - Two arch pins change by design.
  - A case-(ii) order never produces the OMS audit notice. That is accepted, because the notice has no inventory effect.
- **Follow-ups:**
  - the Phase 2 wms2-mobile-ui PR (a hard dependency before operators can use this);
  - SBDEV-3381 items 2–6, after this plan;
  - the post-promotion c1wh waive and its verification query (§8);
  - O2 (the `forklift1` grant review);
  - updating `wms2-cancel-cascade-workflow.md`.

