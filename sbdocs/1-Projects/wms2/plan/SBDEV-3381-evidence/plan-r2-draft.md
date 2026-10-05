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
**Status:** pending approval (ralplan round 2; revised after `architect-review.md` + `critic-review-r1.md`)
**Date:** 2026-09-26
**Evidence:** `SBDEV-3381-evidence/analysis.md`. Its "Addendum — Q7 CLOSED", "Resolved decisions", "Defaults taken" and "Round-1 review decisions" sections are settled.

---

## 0. Affected Sites

Derivation: the analysis §0.1 greps over the whole wms2-api tree at `origin/develop` d9be4188. Rows marked † were re-checked with `git show/grep origin/develop`.

**Blind spots:**
- A text grep misses native SQL spelled differently.
- wms2-web-ui was not swept. It has no cancellation screen that I know of, but that is not measured.

| # | Site | Disposition | Anchor |
|---|---|---|---|
| 1† | `OrderCancellationController`: class-level `@RequiresFunction(MOBILE_UI_VIEW_CANCELLATION)` | new `/waive` handler | §3.1 |
| 2† | `CancellationReversalService.completeReversal`: its outbox block | moved to a shared method; complete stays level-triggered and gains suppression | §3.3.1 |
| 2a† | `completeReversal` residue restore `if (arrivedLocked) { … residue.setEntityLock(PICKED_FOR_GOODSOUT)` | **change**: made waive-aware | §3.3.2 |
| 2b† | `completeReversal` SBDEV-3316 SU-id recovery (`resolvePicktoStockunitId`, `findFirst`) | extracted and reused by waive | §3.2 |
| 3† | `toDetailDto` → `entry.setReversalCompletedAt(...)` | map the waive fields | §3.4 |
| 4† | `CustomerorderCancellationLog` (`@Version`; `amount_picked` nullable :97) | 3 columns | §3.4 |
| 5 | `CancellationLogEntryDto` | additive fields | §3.4 |
| 6† | `CancellationCompleteRequest` (pattern) | new `CancellationWaiveRequest` | §3.1 |
| 7–9† | `findPendingReversals`, `findPendingReversalsOlderThan`, `@Lock(PESSIMISTIC_WRITE) findPendingReversalsForUpdateByCustomerorderId` | read-only; #9 is the lock point | §3.2, §3.7 |
| 10 | `scanTote` filter `isReversalRequired() && getReversalCompletedAt()==null` | no change: a stamped waive drops out | §3.2 |
| 11† | `PendingReversalReconciliationJob` `"Complete or waive them on the mobile Cancellation screen."` | wording | §3.7 |
| 12 | V2.2.00 partial index `… WHERE reversal_required AND reversal_completed_at IS NULL` | no change | §3.6 |
| 13† | `WmsConstants.FunctionEnum` | add a constant | §3.5 |
| 14† | `UtilRestController` initDB `grantFunction(MOBILE_UI_VIEW_CANCELLATION, …)` | add a grant line | §3.5 |
| 15 | new `V2.2.34__cancellation_reversal_waive.sql` | new | §3.6 |
| 16–17 | `AccessAuditService.GATED_WORKFLOWS` / audit SET 4 | **excluded**: they list menu tiles, and a waive is an action inside a tile | §6 |
| 18† | audit SET 9 `steps(...)`, `db/audit-access-invariants.sql:281` | add a row; mind the run timing | §3.5, §5.1 #7 |
| 19 | audit SET 3 `LIKE 'MOBILE_UI_VIEW_%'` | naming constraint | §3.5 |
| 20 | `FunctionGuardInterceptor.GUARDED` already lists the controller | no change | — |
| 21† | `FunctionGuardArchTest.REVIEWED_METHOD_LEVEL_OVERRIDES` (AC-4b, exact equality) | **by-design red → update** | §7.3 |
| 22† | `UserControllerPublicHandlerUnitTest:420` `.hasSize(3)` ("three mobile entries") | **by-design red → 4** | §7.3 |
| 23 | Arch AC-2 golden map / AC-3 / AC-24 | no change (the Architect checked: no test compares FunctionEnum to a seed list) | — |
| 24 | `FunctionGuardMockMvcUnitTest.SURFACE` | new test method | T11 |
| 25 | `UtilRestControllerUnitTest` C2 | extended separately | T13 |
| 26 | `UtilRestControllerSeedUnitTest` C-8d | pattern | T14 |
| 27 | `PendingReversalReconciliationJobUnitTest` | extend | T16 |
| 28 | `PendingReversalOlderThanIntegrationTest` | extend | T15 |
| 29 | `PickingorderBusinessService:622` comment | stays true | — |
| 31 | `05-verify-bridge.sh` | excluded: onboarding only | — |
| 32† | mobile `store/cancellation.js` (`SET_REFUSALS` :51; `completeReversal` `applied` :326) | Phase 2 | §3.8 |
| 33 | `wms2-cancel-cascade-workflow.md` (0 mentions of waive) | doc drift | §4 |
| 35† | `CancellationReversalLockClearIntegrationTest` (H2 `BaseRollbackIntegrationTest`) | fixture base for T18/T22 | §7 |

Row 34, the `SurfaceInventoryContextTest` "eyeball", was **deleted**. It is a generator with no assertion, so a re-run proves nothing. Gate coverage for `/waive` comes from T11 (MockMvc through the real interceptor) and T12 (AC-4b).

---

## 1. Problem

**A live PRD order cannot be closed today.** On **c1wh-shipitez-prd**, order 121691091 (tote C1-0063) has 4 `customerorder_cancellation_log` rows, ids 1–4, all with `reversal_required=true` and `reversal_completed_at IS NULL`. I re-queried them on 2026-09-26. Each row's pick-to SU (121691900 / 930 / 950 / 975) sits at `amount=0, entity_lock=2` (GOING_TO_DELETE) on the Nirwana unit load. The tenant's Flyway head is 2.2.33. `completeReversal` refuses every row at its pre-validate step:

```java
if (sourceLock != null
        && sourceLock != WmsConstants.BusinessObjectLockState.NOT_LOCKED
        && sourceLock != WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT) {
    throw new BusinessException("Reversal for position " + ... + " — manual intervention required");
```

**How the case arose.** This is the item-2 mechanism. The order-cancel `cleanUpCancelledOrder` cleared the pick lock. Then, on 2026-09-21 between 21:54:21 and 21:55:51, `rfernandez` drained each SU off Clearing/C1-0063 with MANUAL_SPLIT (STOCK_REMOVED) back to its bin: A301C5 (3), A301C4 (3), AT01-15 (1), AC01-84 (1). Those match the logs' back-to-bin locations one for one (stockrecord, queried). The drained SUs were then sent to Nirvana.

So the warehouse holds exactly the state a successful complete leaves behind. Hydra PRD's 7 required rows reached that state through `completeReversal` and were cleared on 2026-09-23; all 7 point at lock-2 SUs. The c1wh rows are missing only the log stamp and the OMS audit notice.

**The system tells the operator to do something that doesn't exist.** `PendingReversalReconciliationJob` alerts `"Complete or waive them on the mobile Cancellation screen."` There is no waive endpoint, UI or function. The rows would alert forever. The only way out is hand SQL on PRD, which leaves no audit trail.

**Case (ii) is worse.** When a PICKED_FOR_GOODSOUT (100) SU still holds stock on the tote and complete can't run, the lock has **no operator path out**. `OPERATOR_REMOVABLE = { QUALITY_FAULT, ON_HOLD }`, so `removeLock` refuses 100.

**Found while reading; kept by decision.** `completeReversal` notifies OMS on a *level* test: nothing is pending after the call. So a retry whose ids match only closed rows enqueues another `ORDER_BATCH_REVERSAL_COMPLETED`. OMS absorbs it, because it is idempotent on `parcel.reversal_completed_at`.

Nam settled (Round-1 F3) that this **stays**. It is the only re-send path, for example after a blank-sysprop close or a lost outbox row. That path is reachable only by calling the API directly: `list()` and `scanTote` hide closed orders.

---

## 2. Current Architecture

**Controller.** Five handlers carry only the class gate. `@RequiresFunction` is ANY-of, and a method-level annotation **replaces** the class default. `FunctionGuardInterceptor:237` reads the method annotation, and `:265-267` falls back to the class only when it is null.

The precedent is `ReplenishController`: its class is `MOBILE_UI_VIEW_REPLENISHMENT`, overridden to `MOBILE_UI_VIEW_REPLENISH_REQUEST` on two handlers. Errors from `controller.mobile` go through `MobileEndpointExceptionHandler`.

```java
@PostMapping("/{customerOrderId}/complete")
public ResponseEntity<CancellationDetailDto> completeReversal(@PathVariable Long customerOrderId,
        @RequestBody CancellationCompleteRequest request) throws BusinessException, FacadeException {
```

**Lock and filter.** `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`:

```java
List<CustomerorderCancellationLog> logs = logRepository.findPendingReversalsForUpdateByCustomerorderId(coId);
...
for (CustomerorderCancellationLog log : logs) {
    if (!positionIds.contains(log.getCustomerorderPositionId())) continue;
```

The finder locks only **pending** rows, and an unknown id is silently skipped. Pre-validation runs the SBDEV-3316 recovery, whose `logRepository.save(log)` comes *before* the refusals, and relies on rollback. The method then clears 100→0 and flushes, calls `transferStock`, and restores 100 on residue:

```java
if (arrivedLocked) {
    Stockunit residue = stockunitRepository.findById(log.getPicktostockunitId()).orElse(null);
    if (residue != null && Objects.equals(residue.getUnitloadId(), pickToUnitloadId)
            && residue.getAmount().compareTo(amountBeforeTransfer) < 0
            && residue.getAmount().compareTo(BigDecimal.ZERO) > 0) {
        residue.setEntityLock(WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT);
```

Last, it stamps `setReversalCompletedAt(OffsetDateTime.now())` / `setReversalCompletedBy(SecurityContextUtils.getUserName())`.

**Outbox (level-triggered):**

```java
// Enqueue outbox when ALL positions on this CO are complete
List<CustomerorderCancellationLog> remaining = logRepository.findPendingReversals().stream()
    .filter(l -> l.getCustomerorderId().equals(coId)).collect(Collectors.toList());
if (remaining.isEmpty()) {
    ... if (urlPath == null || urlPath.isBlank()) { LOG.warn(...); return detail(coId); }
    ... outboxService.enqueue(OutboxMessage.builder().aggregateType("CUSTOMER_ORDER").aggregateId(coId)
        .processType(ORDER_BATCH_REVERSAL_COMPLETED).destinationUrl(urlPath).payload(MAPPER.writeValueAsString(batchDto)).build());
```

`OutboxService.enqueue` generates a random-UUID idempotency key, so it has no hidden dedup (Critic F8). On the OMS side the handler is audit only ("MUST NOT touch product_inventory").

**Log columns that are NOT what they look like** (Architect F1 / Critic F1):
- `picktounitload_id` is an FK to **`pickingorder_unitload`**, not `unitload` (`CancellationLogService:73`, javadoc :94). Its `unitload_id` hop is NULL by the time a reversal runs: c1wh `pul` 121691896 is at state 800 with `unitload_id` NULL.
- `tote_label_id` comes from `customerOrder.getHistorytote()` (:78). On CLUB orders, `ManageOrderService:284-286` overwrites it with a UUID at FINISHED (c1wh prd: 18,668 of 18,668 CLUB orders, 0 matching a unit load). On multi-tote orders it holds only the last tote.
- Tote `unitload` rows are reused as **the same row** across orders (c1wh C1-0063 = id 2887773 across 1,257 orders). The pick-to **SU id** is unique per pick.

**"Pending" means `reversal_completed_at IS NULL`** in every reader the analysis §2.3 grep found: the three finders, `scanTote`, the partial index, and mobile `stillPending`.

**Authz seed:**

```java
grantFunction(WmsConstants.FunctionEnum.MOBILE_UI_VIEW_CANCELLATION,
        role_inventory_manager, role_outbound_manager, role_outbound_worker, role_super_admin);
```

`UtilRestController` is a `@Service`, so this runs only on a fresh DB, and live tenants get their rows from Flyway.

**Not SDR-exported (Q7 closed).** Detection strategy is `ANNOTATED`, and the repository has no `@RepositoryRestResource`. Positive control: 68 of them elsewhere under `repo/`.

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

`CancellationWaiveRequest { List<Long> positionIds; String reason; Boolean stockReturned; }` uses the boxed `Boolean` so that an omitted field reads as null.

Validation throws `BusinessException` in the service, so the error shape stays consistent:
- `positionIds` null or empty → `"positionIds required"`
- `reason` null or `isBlank()` → `"reason required"`
- `reason.trim().length() > 500` → `"reason too long (max 500)"`
- `stockReturned == null` → `"stockReturned required"`

The method-level gate replaces the class gate. That exposure is controlled through the grant set, not an in-service AND (see §9 F).

### 3.2 `CancellationReversalService.waiveReversal`

`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class}) CancellationDetailDto waiveReversal(Long coId, List<Long> positionIds, String reason, Boolean stockReturned)`

1. **Validate** as in §3.1.
2. **Lock:** `pending = findPendingReversalsForUpdateByCustomerorderId(coId)`. This is the same lock point as complete.
   - Under READ COMMITTED, a waive blocked behind a complete re-checks the predicate after the wait and does not see the row that transaction stamped, and the reverse holds too.
   - The wait is bounded by the tenant `lock_timeout` per acquisition. `@Version` is a second layer.
3. **Resolve ids.** Load `all = findByCustomerorderId(coId)` after the lock (unlocked).
   - An id on no row of this CO → `BusinessException("position X is not on order Y")`.
   - An id on a non-pending row → no-op.
   - `targets = pending ∩ positionIds`. **If `targets` is empty, return `detail(coId)` with no writes and no enqueue.** This early return is what makes waive edge-triggered.
4. **Pre-validate every target; write nothing yet except the 3316 recovery.**
   - Per target, run the SBDEV-3316 recovery. It is extracted from complete into a private helper, and both callers use it.
   - Remember whether the SU id was **recovered in this call**.
   - Load the SU (it may be absent) and compute `toteState` (below).
   - If `stockReturned == true` and the table says refuse, throw a `BusinessException` naming the position, SU id, lock text (`getCodeTextOrUnknown`), amount and tote state.
   - `rollbackFor` undoes the recovery save, so **a refused waive commits nothing**. T18b pins this against the DB.
5. **Write.**
   - For each SU the table marks "clear 100 → 0": `setEntityLock(NOT_LOCKED)` and save. **Never** clear the lock on an SU whose id was recovered in this call (N4): a reused tote's `findFirst` can return another order's SU. In that case close the row and report `waiveLockRetained`.
   - No `transferStock` and no stock-change message.
   - For each target row: `reversalCompletedAt = now`, `reversalCompletedBy = SecurityContextUtils.getUserName()`, `reversalWaived = true`, `reversalWaiveReason = reason.trim()`, `reversalWaiveStockReturned = stockReturned`. Then save.
   - Log order is unchanged: log rows first, then the stockunit.
6. **Notify:** `enqueueReversalCompletedIfClosed(coId)` (§3.3.1). Log `LOG.info("waiveReversal order={} positions={} stockReturned={} lockCleared={} lockRetained={} by={}")`.
7. Return `detail(coId)`.

**`toteState(su, log)` — three-state; fails closed (N1).** Read `unitloadRepository.findParcelGuardViewById(su.getUnitloadId())` (scalar `labelid`, `typeId`), then the type name via `unitloadTypeRepository`. Both are already injected.
- **ON:** the type name equals `WmsConstants.UNIT_LOAD_TYPE_TOTE` ("Tote", :872) **and** `labelid.equals(log.getToteLabelId())`.
- **OFF:** the type name is known and is not "Tote" (Package, Default/Nirwana, a bin container).
- **UNKNOWN:** everything else. That covers a null unit load id, a missing view, a null or missing type, a Tote whose label doesn't match (a CLUB UUID or a multi-tote order), and a null `toteLabelId`.
- Do **not** reuse `SourceContainerGuard.judge`'s default. It treats a null type as "not a Package", which fails open.

**Stock-effect table.** The rules:
- never move stock;
- only ever release PICKED_FOR_GOODSOUT (100), and only when `ON`;
- never touch a lock another process owns;
- `stockReturned=true` with amount > 0 is allowed only when `OFF`.

| Case | Pick-to SU | Write to stock | `stockReturned=true` | `false` |
|---|---|---|---|---|
| (i) live c1wh | amount 0, lock 2 (Nirwana → OFF) | none | allowed | allowed |
| (i′) | amount 0, lock 100 | clear 100→0 **only if ON** (and not recovered); otherwise none | allowed (amount 0) | allowed |
| (i″) | amount 0, lock 0 | none | allowed | allowed |
| (ii) | amount > 0, lock 100, **ON** | clear 100→0 **only if the ownership rule holds** and the SU was not recovered; otherwise none + `waiveLockRetained` | **refuse** (Q1) | allowed |
| (ii′) | amount > 0, lock null or 0 | none | allowed only if OFF; ON/UNKNOWN refuse | allowed |
| (ii″) | amount > 0, lock 100, **OFF or UNKNOWN** | **none**: an off-tote or unprovable lock belongs to another process | refuse (lock 100 = still reserved for goods-out) | allowed |
| (iii-a) | SU missing / id unresolvable | none (persist a recovered id) | allowed | allowed |
| (iii-b) | QUALITY_FAULT / ON_HOLD | none (`removeLock` covers these) | allowed if amount 0 or **OFF**; ON/UNKNOWN refuse | allowed |
| (iii-c) | SHIPPED (405) | none | **refuse** | allowed |
| (iii-d) | 403 / 404 / other | none | as (iii-b) | allowed |

**Ownership rule for (ii).** Clear only if **no** contributing row has a null `amountPicked` (F10; null → decline) **and** `su.amount <= Σ amountPicked` over rows of **this CO** that resolve to that SU and are either being waived in this call or already waived. Completed rows are excluded, because their stock already left the SU. When the rule declines: leave the lock, still close the row, and set `waiveLockRetained`.

Blind spot: this is an amount heuristic, not a join to live pick lines (Q3 default). Null `amount_picked` on required rows measured 0 on c1wh prd and 0 on Hydra prd.

### 3.3 Changes to `completeReversal`

#### 3.3.1 Shared OMS enqueue — complete level, waive edge (settled Round-1 F3 + F4)

Extract the outbox block into `private void enqueueReversalCompletedIfClosed(Long coId)`. Both callers use it, so the payload cannot drift. It enqueues when **all** of these hold:

1. No pending rows remain for the CO. This is the existing `findPendingReversals().stream().filter(coId)` query; JPQL AUTO-flushes this transaction's stamps first. **It is level-triggered for complete, unchanged**: a complete retry on a closed CO re-enqueues, which is the manual re-send path. Waive only reaches this method when `targets` was non-empty (§3.2 step 3), so waive is edge-triggered by construction.
2. **Suppression (new, both callers).** No row on the CO has `reversalWaived && Boolean.FALSE.equals(reversalWaiveStockReturned)`, read from `findByCustomerorderId`. Per Nam's F4 ruling, the scope is the **whole order, permanently**: one `stockReturned=false` waive means `ORDER_BATCH_REVERSAL_COMPLETED` is never sent for that CO. That covers rows later closed by a real movement, rows added by a later partial cancel, and complete's re-send path. Log `LOG.info` when suppressing.
3. The sysprop URL is non-blank. Otherwise keep today's `LOG.warn` and skip. For a waive that closes a CO with a blank sysprop, a later `/complete` call re-sends (condition 1).

The payload is byte-identical to today's: `OrderBatchDto{batchId, facilityCode=MULTIWAREHOUSE_IDENTIFIER, positions=[OrderDto{uniqueId=externalnumber, positions=[]}]}`. It is written in the same transaction through the transactional outbox.

**⚠ The only notify-behaviour change to complete is suppression (condition 2).** Its level trigger and retry re-enqueue are kept deliberately (T19).

#### 3.3.2 Residue restore made waive-aware (Architect F2, Critic REFINED)

Without this change, a waive of A (rule declined, lock kept) followed by a complete of B on a merged SU re-locks A's share at 100, and nothing can ever clear it.

Change the restore to fire only when `residue.amount > Σ amountPicked(waived rows of this CO with the same picktostockunitId)`, **or** when any such contributing `amountPicked` is null (the conservative choice).
- With no waived rows the sum is 0, and the existing `residue > 0` term already holds, so **behaviour for orders without a waive is unchanged**. The existing `completeReversalDoesNotInventALockOnARowThatArrivedUnlocked` and the restore tests stay green.
- T22 pins the new case.

### 3.4 Entity / DTO (additive)

- **`CustomerorderCancellationLog`:**
  - `@Column(name="reversal_waived", nullable=false) private boolean reversalWaived = false;`
  - `@Column(name="reversal_waive_reason", columnDefinition="TEXT") String reversalWaiveReason;`
  - `@Column(name="reversal_waive_stock_returned") Boolean reversalWaiveStockReturned;`
  - Waived by/at = `reversal_completed_by/at` (settled Q2).
- **`CancellationLogEntryDto`** gains `reversalWaived`, `waiveReason`, `waiveStockReturned`, `waiveLockRetained`.
  - `waiveLockRetained` is computed in `toDetailDto` only for waived rows: `su != null && su.entityLock == 100 && su.amount > 0 && toteState(su, log) != OFF`.
  - It uses the same helper as §3.2. The cost is one SU read plus one unit-load view read per waived row.
  - It is also the input to a possible follow-up (a supervisor release of 100, not built here).

### 3.5 Authz registration — the five places

1. `FunctionEnum.MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL`.
   - It is the first **mobile** action constant. The `*_ACTION_*` family already exists as `WEB_UI_ACTION_*` (`WmsConstants:426-433`, e.g. `WEB_UI_ACTION_ADJUST_LOCK_RELEASE_LOCK`, seeded by V2.2.21).
   - The name avoids SET 3's `LIKE 'MOBILE_UI_VIEW_%'`.
   - No code prefix-matches these names: `startsWith("MOBILE_UI|WEB_UI")` gives 0 hits in src/main and in mobile-ui. Blind spot: a regex spelled another way.
2. initDB: `grantFunction(…WAIVE…, role_outbound_manager, role_super_admin);` with a comment citing SBDEV-3381 Q5.
3. The V2.2.34 function row plus the same two grants (§3.6).
4. `@RequiresFunction` on the handler (§3.1).
5. `audit-access-invariants.sql` SET 9: `('step5_WAIVE_CANCELLATION', 'MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL', ARRAY['outbound-manager','super-admin'])`.
   - SET 9 reports users who reach the function but **don't hold it yet** (`WHERE NOT EXISTS (SELECT 1 FROM holders h …)`, :300-305). So it is useful only **before** V2.2.34 lands (§5.1 #7).

Not added: GATED_WORKFLOWS / SET 4, and `SdrRuleStartupAssertion`.

In the same commit: `REVIEWED_METHOD_LEVEL_OVERRIDES` += `"OrderCancellationController#waiveReversal"` (the AC-4b key is `getSimpleName() + "#" + m.getName()`), and `UserControllerPublicHandlerUnitTest:420` `hasSize(3)` → `hasSize(4)` with the message "four mobile entries". Its `:440` `hasSize(16)` (the GUARDED count) does not change.

### 3.6 Flyway `V2.2.34__cancellation_reversal_waive.sql`

Conventions:
- `ADD COLUMN IF NOT EXISTS` (V2.2.31);
- seeds via `WHERE NOT EXISTS`, never `ON CONFLICT` (V2.2.18);
- the column list matches `V2.2.18:22-23` and `V2.2.00:1442-1451` (Architect F7);
- the CHECK sits in a `pg_constraint`-guarded `DO` block.

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

- `NOT NULL DEFAULT false` does not rewrite the table on PG ≥ 11. The table holds ≤ 17 rows on the measured tenants.
- The CHECK is the riskiest statement, because a failed tenant migration silently freezes that tenant. Every existing row satisfies it (`reversal_waived=false`).
- V2.2.28 and V2.2.31 already ALTERed this table fleet-wide. That is evidence, not proof, about table ownership.
- The H2 lane (`create-drop`, Flyway off) never sees the CHECK or the DEFAULT. The Architect found 0 native INSERTs into this table in src/main or src/test (positive control: the table name appears in 3 test files), so the missing DB default is harmless there.

### 3.7 `PendingReversalReconciliationJob` wording

- Replace the alert sentence with `"Complete them on the mobile Cancellation screen, or have an outbound manager waive them there (Waive)."`
- Append `(waived rows carry reversal_waived=true and are excluded)` to the tail text that quotes the query.
- Waived rows drop out of `findPendingReversalsOlderThan` because waive stamps `reversal_completed_at` (T15).

### 3.8 Phase 2 — wms2-mobile-ui

- **`store/cancellation.js`, new action `waivePosition({ coId, positionId, reason, stockReturned })`.**
  - It calls `POST /cancellation/${coId}/waive` with `{ positionIds: [positionId], reason, stockReturned }`, one position per request like complete.
  - Success is `order.positions.some(p => p.customerorderPositionId === positionId && p.reversalWaived)`. It checks `reversalWaived`, not just `reversalCompletedAt`, so a row another handheld *completed* is not reported as waived (F11).
  - On success it refreshes the detail and clears that position's `SET_REFUSALS` entry. Server refusals go through the existing `apiErrorMessage` path.
- **Existing `completeReversal` action (:326):** `applied` gains `&& !p.reversalWaived`. A row that another handheld waived now reports "waived by another operator", not "Reversal complete." Stock that never moved is no longer claimed as moved. Update the comment that justifies "the stock genuinely is back".
- **`cancellationDetail.vue` / `cancellationAction.vue`:**
  - The **Waive** action appears on a position in the refusal state, and only when `state.home.functions` (`store/home.js:60`) includes `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL`. This is a UI affordance; the server gate is authoritative.
  - The prompt has a reason (required, non-blank, ≤ 500 chars) and an explicit yes/no "Was the stock returned to its bin?" with no default.
  - Waived rows show a "Waived" badge with the reason, plus a warning when `waiveLockRetained`.
- `stillPending` needs no change.
- **Jest:**
  - the exact POST body;
  - `waivePosition` success requires `reversalWaived` (mutant: drop the check);
  - `completeReversal` `applied` is false for a waived row (mutant: drop `&& !p.reversalWaived`);
  - the button is hidden without the function;
  - the prompt blocks a blank reason and an unanswered `stockReturned`;
  - refusal messages are surfaced.

---

## 4. File Change Summary

| Repo | File | Change |
|---|---|---|
| wms2-api | `controller/mobile/OrderCancellationController.java` | `/waive` handler + method gate |
| wms2-api | `json/CancellationWaiveRequest.java` | new |
| wms2-api | `json/CancellationLogEntryDto.java` | +4 fields |
| wms2-api | `model/CustomerorderCancellationLog.java` | +3 columns |
| wms2-api | `service/CancellationReversalService.java` | `waiveReversal`, `toteState`, extracted recovery helper, `enqueueReversalCompletedIfClosed` (+ suppression), waive-aware residue restore, `toDetailDto` mapping |
| wms2-api | `service/WmsConstants.java` | FunctionEnum constant |
| wms2-api | `controller/rest/UtilRestController.java` | initDB grant |
| wms2-api | `schedulejob/PendingReversalReconciliationJob.java` | wording |
| wms2-api | `resources/db/migration/V2.2.34__cancellation_reversal_waive.sql` | new |
| wms2-api | `resources/db/audit-access-invariants.sql` | SET 9 row |
| wms2-api | tests (§7.1) | `CancellationReversalServiceUnitTest`, new `OrderCancellationControllerUnitTest`, `FunctionGuardMockMvcUnitTest`, `FunctionGuardArchTest`, `UserControllerPublicHandlerUnitTest`, `UtilRestControllerUnitTest`, `UtilRestControllerSeedUnitTest`, `PendingReversalReconciliationJobUnitTest`, `PendingReversalOlderThanIntegrationTest`, `CancellationLogEntryDtoSerializationTest`, new `CancellationWaiveMigrationIT`, `CancellationReversalLockClearIntegrationTest` (extended) |
| wms2-mobile-ui | `store/cancellation.js`, `components/cancellation/cancellationDetail.vue`, `cancellationAction.vue`, `test/store/cancellationWaive.spec.js` (new), `test/store/cancellationPartialReversal.spec.js` (extend), a component spec | §3.8 |
| sbdocs | `3-Resources/workflows/wms2-cancel-cascade-workflow.md`, `wms2-function-to-docs-map.md` §9 | waive section; bump `last_verified` |

---

## 5. Phases

**Scope fence:** **SBDEV-3381 item 1 only.** Items 2–6 are **out of scope** and ship **after** this plan. Item 2, fencing the cancel lock-clear sites, makes case (i) rarer and case (ii) the main waive input, so the waive has to exist first.

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | Tenant head 2.2.33 → new V2.2.34. **Sweep (2026-09-26):** `git fetch origin; for r in $(git for-each-ref --format='%(refname)' refs/remotes/); do git ls-tree --name-only "$r" src/main/resources/db/migration/ \| sed -n 's#.*/V\(2\.2\.[0-9]*\)__.*#\1#p'; done \| sort -t. -k3 -n -u \| tail -3` → `2.2.31 2.2.32 2.2.33` over **345** remote refs. A second loop grepping `V2\.2\.34__` on every ref → 0 hits. `origin/develop` = d9be4188. c1wh prd head = 2.2.33 (queried). | executor | Perishable: a later push is invisible to this sweep. **Re-run immediately before the PR**; renumber if needed |
| 2 | **Feature flags / sysprops** | `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` is the existing complete sysprop; no new one. c1wh prd = `https://api-oms.sbo.li/services/call/batchReversalCompleted` (queried) | — | Blank → warn and skip (§3.3.1 #3) |
| 3 | **Config / env** | N/A — the gate is a WMS function and the columns come from Flyway, so no property, Keycloak or env change | — | |
| 4 | **Deploy order** | Phase 1 (api) is deployed and verified on dev before Phase 2 (mobile) merges; an older api answers 404 on `/waive` | Nam | The button is function-gated, so shipping it early shows a dead button to holders only |
| 5 | **Data migration** | None beyond V2.2.34 defaults. The c1wh cleanup is an operator waive, not SQL (§8) | — | |
| 6 | **External systems** | OMS `batchReversalCompleted` is live and idempotent; no OMS change | — | M5. **UNVERIFIED:** whether OMS alerts or reports on parcels with an open reversal (matters under permanent suppression; §10 O4) |
| 7 | **Access / permissions** | New function to `outbound-manager` + `super-admin` via V2.2.34 and initDB. No Keycloak change. **Run SET 9 BEFORE the dev merge** (merging runs Flyway at boot) and **before DevOps promotes to PRD**; expect `step5_WAIVE_CANCELLATION` to list the new users. Re-run after each; expect 0. On c1wh prd the pre-run should list the 4 outbound-manager users (`cloverdale-qa1`, `cloverdale-qa2`, `forklift1`, `rlangston`) plus the super-admin holders (queried 2026-09-26) | Nam | **O2 (`forklift1`) is reviewed at the PRD pre-run** |
| 8 | **Monitoring / alerts** | N/A — nothing scrapes Prometheus; the reconciliation job's existing alert is the signal, and it stops for waived rows | — | |

### 5.2 Phase 1 — wms2-api (`feature/SBDEV-3381-waive` off freshly fetched `origin/develop`, worktree `.claude/worktrees/wms2-api/SBDEV-3381`)

- [ ] Floor: re-run the c1wh query (§8 step 4a) and record it.
- [ ] Failing tests first: T1–T22. Confirm each fails for the right reason. The AC-4b/size pins go red once the handler exists, by design.
- [ ] Refactors that keep behaviour: the recovery helper, and `enqueueReversalCompletedIfClosed` (level for complete). The existing complete tests stay green.
- [ ] `toteState`, `waiveReversal`, the waive-aware residue restore, the DTO/entity, the controller.
- [ ] FunctionEnum, initDB, V2.2.34, SET 9, the job wording. Update the arch pins (§7.3).
- [ ] `mvn clean verify` in both lanes vs a baseline taken adjacent in time. Mutation-check every new assertion (§7.2).
- [ ] Update the docs (§4). Four independent review lanes (T3), each writing a file. Fix every finding, including Lows.
- [ ] Run the dev SET 9 pre-run (5.1 #7). Re-sweep Flyway (5.1 #1). PR into `develop`.

**Acceptance:** T1–T22 green; the two by-design reds updated in the same commit; full suite ≥ baseline; V2.2.34 applies and re-applies idempotently on Testcontainers.

### 5.3 Phase 2 — wms2-mobile-ui (branch `feature/SBDEV-3381-waive` off fresh `origin/develop`)

- [ ] Jest specs first (§3.8), then the implementation. Mutation-check each assertion.
- [ ] Headless-browser smoke on dev once Phase 1 is live there (`/api/public/version` shows its SHA).
- [ ] PR into `develop`.

**Acceptance:** Jest green; the button shows only for a waive holder; M2 passes on dev.

---

## 6. Backward Compatibility

- **API:** one new route. `CancellationLogEntryDto` gains 4 additive fields. The serialization test pins keys individually, not as a closed set.
- **DB:** 3 defaulted/nullable columns and a CHECK that every existing row satisfies.
- **OMS:** the payload is byte-identical. **Behaviour change:** after a `stockReturned=false` waive, the order's notice is permanently suppressed, from both waive and complete (settled F4). Otherwise complete's level trigger, including the retry re-enqueue, is unchanged (settled F3).
- **Complete's residue restore:** it now skips the re-lock when the residue is ≤ the waived rows' share. That is a behaviour change **only** for orders with a waived row on the same SU.

### What does NOT change

- `transferStock`, complete's movement loop, and its 100→0 clear + flush.
- Complete's residue restore for any order with **no** waived row (the sum is 0, §3.3.2).
- Complete's level-triggered enqueue and its retry re-send.
- The finders, the partial index, `scanTote`, `detail`'s query, and mobile `stillPending`.
- The class gate `MOBILE_UI_VIEW_CANCELLATION`, `GUARDED`, `GATED_WORKFLOWS`, SET 4.
- `removeLock` / `OPERATOR_REMOVABLE`. Waive releases 100 only when `ON`, not recovered, and under the ownership rule.
- Keycloak roles and groups.

---

## 7. Testing

### 7.1 Tests and the mutation each must kill

**Fixture rules:**
- `picktounitloadId` (a `pickingorder_unitload` id) and `su.unitloadId` always carry **different** numeric values.
- `toteLabelId` and the unit load's `labelid` are set explicitly.
- Unit fixtures have a non-null `picktostockunitId` unless the test is about recovery (F9).

| # | Class / lane | Asserts | Mutation it must kill |
|---|---|---|---|
| T1 | `CancellationReversalServiceUnitTest` | Live case (i) (Nirwana → OFF): rows stamped, `waived=true`, reason/stockReturned persisted; `stockunitRepository.save` and `transferStock` never called | delete the stamp; write to the lock-2 SU |
| T2 | same | Case (ii), ON, `stockReturned=false`: lock 100→0, no `transferStock` | drop the clear |
| T3 | same | Ownership: SU.amount > Σ → kept + `waiveLockRetained`; `==` → cleared; **already-waived sibling** fixture (A waived earlier, B now, A+B == amount) → cleared; null `amountPicked` → kept; **recovered-in-this-call** SU → kept | `<=`→`<`; always clear; drop the already-waived term; drop the null guard; drop the recovered guard; **id-comparison `onTote`** (restores `su.unitloadId == picktounitloadId`) |
| T4 | same | `stockReturned=true` refused for (ii), (ii′-ON), (ii′-UNKNOWN), (ii″) and SHIPPED; `stockunitRepository.save` and `logRepository.save` never called | refuse after the writes; drop one refusal branch |
| T5 | same | QUALITY_FAULT / ON_HOLD / 403 / 404 untouched; (ii″) lock 100 OFF and UNKNOWN untouched; (i′) lock 100 UNKNOWN → untouched | clear any non-100 lock; clear on UNKNOWN; **label-only** `onTote` (ignore type); id-comparison `onTote` |
| T5b | same | CLUB-shaped: UUID `toteLabelId`, SU on a "Tote" with label `C1-0063`, QUALITY_FAULT, amount 1, `stockReturned=true` → **refused** (UNKNOWN) | the Architect's label rule with "not onTote ⇒ allow" (UNKNOWN treated as OFF) |
| T6 | same | Waive closing the last row with `stockReturned=true` → exactly one enqueue, payload JSON equal to complete's; `false` → none | drop the suppression; payload drift |
| T7 | same | A second waive of the same ids → no writes, no enqueue | remove the empty-targets early return |
| T8 | same | Blank reason (`"  "`), 501-char reason (500 accepted), empty ids, null stockReturned, id not on this CO → `BusinessException`, nothing saved | `isBlank`→`isEmpty`; `>`→`>=` on the cap; silent skip of an unknown id |
| T9 | same | Locks via `findPendingReversalsForUpdateByCustomerorderId` (verify) | swap the finder |
| T10 | new `OrderCancellationControllerUnitTest` (`BaseControllerUnitTest`) | Body binds `positionIds`/`reason`/`stockReturned`; an omitted `stockReturned` arrives as null | rename a field; primitive `boolean` |
| T11 | `FunctionGuardMockMvcUnitTest` (new method) | VIEW-only → 403 on `/waive`; waive holder → 200; VIEW holder still 200 on `/complete` | delete the method annotation; wrong constant |
| T12 | `FunctionGuardArchTest` AC-4b + `UserControllerPublicHandlerUnitTest` | override set = the 4 entries; size 4 | — (pins, §7.3) |
| T13 | `UtilRestControllerUnitTest` (new block) | initDB grants waive to exactly the **set** {outbound-manager, super-admin} | add outbound-worker; swap super-admin → outbound-worker |
| T14 | `UtilRestControllerSeedUnitTest` (C-8d style) | V2.2.34 role-name set == the initDB role-name set, comment-stripped | drop or swap a role on one side |
| T15 | `PendingReversalOlderThanIntegrationTest` | waived+stamped row excluded; an un-waived row in the same test is returned (positive control) | stop stamping on waive |
| T16 | `PendingReversalReconciliationJobUnitTest` | new wording contains "waive" and "outbound manager" | revert the text |
| T17 | new `CancellationWaiveMigrationIT` (watermark pattern of `CancellationLogPickingorderPositionIdIT`) | at 2.2.33 the columns are absent; at 2.2.34 present with default false; function row present; granted **role-name set == {outbound-manager, super-admin}**; re-run idempotent; CHECK violation asserted by **SQLSTATE 23514** | drop DEFAULT; drop the CHECK; `ON CONFLICT` seed; **super-admin → outbound-worker** (count-preserving swap) |
| T18 | `CancellationReversalLockClearIntegrationTest` (H2 `BaseRollbackIntegrationTest`, reusing its fixtures) | waive→complete and complete→waive on a 2-row CO: outbox rows `WHERE aggregate_id = <fixture-unique coId>` = 1 in both orders (never a global count); a waived row cannot then be completed. **This lane has no CHECK constraint** (H2 create-drop) | a finder without the stamp predicate; suppression in the wrong place |
| T18b | same | A waive refused in pre-validate after an SBDEV-3316 recovery → the DB still shows `picktostockunit_id` NULL and the row pending (read back after the 4xx) | commit the recovery before validating (drop `rollbackFor`) |
| T19 | `CancellationReversalServiceUnitTest` | **A complete retry on a closed CO re-enqueues** (the re-send path; level trigger kept); with a `stockReturned=false` waived row on the CO → no enqueue | add an edge trigger to complete; drop the suppression on the re-send path |
| T20 | same | Complete closing the last row after a `stockReturned=false` waive → no enqueue; after a `true` waive → one enqueue | drop the suppression predicate; suppress on any waive |
| T21a | `CancellationLogEntryDtoSerializationTest` | the 4 new keys serialize | drop a field or its getter |
| T21b | `CancellationReversalServiceUnitTest` | `toDetailDto` sets `waiveLockRetained` only for waived rows with lock 100, amount > 0, state ≠ OFF; false when OFF; false for non-waived rows | drop a mapping; `!= OFF` → `== ON`; the id-comparison `onTote` |
| T22 | `CancellationReversalLockClearIntegrationTest` (H2) | Rows A(1) and B(2) on one SU (amount 3, lock 100, ON). Waive A `false` (rule declines, lock kept); then complete B → residue amount 1 ends at **lock 0** | the old restore predicate (ignoring waived rows); drop the null → restore guard (a variant with null `amountPicked` on A must end at lock 100) |

No thread-race IT: two existing concurrency ITs are known to be timing-flaky. T9 and T18 cover ordering deterministically.

### 7.2 Mutation discipline

Break each assertion's target and confirm it goes red. Use PIT scoped to `CancellationReversalService` where it applies, and hand mutants for SQL, the arch pins and Jest. Record the kill per row. The named "id-comparison" and "label-only" `onTote` mutants are mandatory.

### 7.3 Known by-design reds (update in the same commit)

- `FunctionGuardArchTest.REVIEWED_METHOD_LEVEL_OVERRIDES` (AC-4b, exact equality) → add `"OrderCancellationController#waiveReversal"`.
- `UserControllerPublicHandlerUnitTest:420` `.hasSize(3)` → `.hasSize(4)`, message "four mobile entries".
- Any other red is a real finding, not a pin to re-baseline.

### 7.4 Manual Test Plan

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| M1 | Replay of the c1wh case (i) | DEV/UAT | **Fixture:** pick 2 lines into a tote → **order-level** cancel (`cleanUpCancelledOrder` clears the lock) → Move Stock each SU from Clearing back to its bin (the SUs drain to lock 2 / Nirwana). Then `POST /complete` → refused; `POST /waive` with `stockReturned=true` as an outbound-manager | complete 4xx "manual intervention required"; waive 200; both rows stamped, `reversal_waived=true`; 1 outbox row for the coId | |
| M2 | Mobile happy path | dev | Scan tote → refused position → Waive → reason + "yes" | the badge shows; the order leaves the list | |
| M3 | Case (ii) | UAT | **Fixture:** pick 2 units into a tote → **per-position** cancel (`cancelOrderPosition` leaves lock 100 on the tote, the gap cited at `CancellationReversalService:318-321`). Waive `stockReturned=true` → refused; retry `false` | refused, nothing written; then lock 0, amount unchanged; Move Stock can take it | |
| M4 | Gate | dev | outbound-worker calls `/waive` | 403; button hidden | |
| M5 | OMS | UAT OMS | After M1 on UAT, check the parcel | `parcel.reversal_completed_at` stamped + a status-history row; product_inventory unchanged | |
| M6 | Migration SQL | UAT tenant DB | `SELECT column_name FROM information_schema.columns WHERE table_name='customerorder_cancellation_log' AND column_name LIKE 'reversal_waive%'`; `SELECT array_agg(r.name ORDER BY r.name) FROM mywms_role_mywms_function rf JOIN mywms_role r ON r.id=rf.rolelist_id JOIN mywms_function f ON f.id=rf.functionlist_id WHERE f.name='MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL'` | 3 waive columns; role set **= {outbound-manager, super-admin}** | |
| M7 | Audit SET 9 | UAT, then PRD | Run `audit-access-invariants.sql` **before** Phase 1 reaches the tenant, then again after | before: `step5_WAIVE_CANCELLATION` lists the newly granted users; after: 0 | |

### 7.5 Horizontal Scalability

| # | Concern | Verdict | Rationale / evidence |
|---|---|---|---|
| 1 | In-JVM state | No | stateless service method |
| 2 | Connection pool | No | one tenant tx per request, as complete |
| 3 | Scheduled jobs | No | wording change only; the exclusion comes free (T15) |
| 4 | Long transactions | No | no transfer, no external I/O |
| 5 | Request affinity | No | stateless |
| 6 | Retry / idempotency | **Yes** | a re-waive is a no-op through the empty-targets early return (T7). Complete stays level-triggered by decision, so a retry re-enqueues, and OMS is idempotent on `parcel.reversal_completed_at` (T19) |
| 7 | Tenant context | No | request thread only |
| 8 | Distributed lock | **Yes** | the same `PESSIMISTIC_WRITE` finder as complete in `tenantTransactionManager`; `lock_timeout` bounded; `@Version` (T9, T18) |
| 9 | Cache | N/A | not measured against `wms2-caching-strategy.md`; the executor confirms by grep that neither entity is Caffeine-cached |
| 10 | External notification | **Yes** | transactional outbox row in the same tx; async dispatch (T6, T18) |

### 7.6 v2-only constraints

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV off | handled: everything loads inside the service tx; `detail` has its own readOnly tx |
| 2 | Tenant tx manager | yes, with rollbackFor both exception types |
| 3 | readOnly reads | N/A (write path) |
| 4 | Caffeine | N/A (§7.5 #9) |
| 5 | Micrometer | No: low-frequency, nothing scrapes; `LOG.info` is the breadcrumb |
| 6 | Jakarta | yes |
| 7 | H2-compatible SQL | yes: JPQL unchanged; the CHECK/DEFAULT are only in T17 (Testcontainers) |
| 8 | Controller test base | `BaseControllerUnitTest` (T10); the gate in T11 (`setupMockMvc` installs no interceptor) |

---

## 8. Rollout

1. Run the dev SET 9 pre-run (M7), then the Phase 1 PR into **`develop` only**. Release and main belong to DevOps. **Merging to develop is a dev deploy plus a Flyway run** at boot. Afterwards, confirm `/api/public/version` shows the merge SHA and that a dev tenant's `flyway_schema_history` is at 2.2.34. Then run the SET 9 post-run (expect 0).
2. Phase 2 PR into mobile `develop` after step 1 is verified. Beware the back-to-back `:develop` tag race.
3. UAT: M1, M3, M5, M6, M7.
4. **Before DevOps promotes to PRD:** run the c1wh SET 9 pre-run and review O2 there.
5. **After PRD promotion, close the c1wh case.** Steps a and b are gating pre-steps; do not waive if either fails.
   - **a. Stock-return evidence.** On c1wh-shipitez-prd:
     ```sql
     SELECT created, operator, type, activitycode, amount, fromstockunitidentity FROM stockrecord
     WHERE fromstockunitidentity IN ('121691900','121691930','121691950','121691975')
       AND type = 'STOCK_REMOVED' AND activitycode = 'MANUAL_SPLIT';            -- expect 4 (rfernandez, 2026-09-21 21:54–21:55)
     SELECT created, amount, tostoragelocation FROM stockrecord
     WHERE operator = 'rfernandez' AND activitycode = 'MANUAL_SPLIT' AND type = 'STOCK_CREATED'
       AND created BETWEEN '2026-09-21 21:54:00+00' AND '2026-09-21 21:56:00+00';
       -- expect exactly A301C5 3, A301C4 3, AT01-15 1, AC01-84 1 = the logs' back-to-bin locations
     ```
     Both were measured on 2026-09-26 with exactly those results. This evidence, not the rule table, is what justifies attesting `stockReturned=true` to PRD OMS.
   - **b. Notice destination.** `SELECT sysvalue FROM los_sysprop WHERE syskey='WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED'` must be the **PRD** OMS host, `https://api-oms.sbo.li/services/call/batchReversalCompleted` (measured). The Hydra PRD → UAT OMS precedent is why this is checked.
   - **c. Waive.** A c1wh outbound-manager waives positions 121691092–121691095 of order 121691091 on the mobile screen, with `stockReturned=true` and a reason citing SBDEV-3381 and the 2026-09-21 MANUAL_SPLIT. I propose `rlangston` (outbound-manager + super-admin on c1wh prd); Nam confirms the operator.
   - **d. Verify by query:**
     ```sql
     SELECT id, reversal_completed_at IS NOT NULL AS stamped, reversal_completed_by, reversal_waived, reversal_waive_stock_returned
     FROM customerorder_cancellation_log WHERE customerorder_id = 121691091;         -- expect 4 × (t, <user>, t, t)
     SELECT count(*) FROM outbox_message WHERE aggregate_id = 121691091
       AND process_type = 'ORDER_BATCH_REVERSAL_COMPLETED';                           -- expect 1, then status SENT
     ```
     SENT is not proof of delivery. Check that the PRD OMS parcel shows `reversal_completed_at`, and that the next reconciliation run no longer lists c1wh.
   - Run the PRD SET 9 post-run (expect 0).
6. Items 2–6 are planned only after step 5.

---

## 9. Alternatives

| # | Alternative | Verdict |
|---|---|---|
| A | Force complete (skip the lock check) | Rejected: there is nothing to move on a Nirvana row, and case (ii) would move stock the system can't vouch for |
| B | A marker in `reversal_notes` text | Rejected (D-b): unqueryable, and overwritten |
| C | Don't stamp; filter on `reversal_waived` everywhere | Rejected (Q2): 3 JPQL predicates, `scanTote`, a new index, mobile `stillPending`, and a standing drift hazard |
| D | Reuse the VIEW gate | Rejected (Q5): gives a supervisor override to every outbound-worker |
| E | Whole-order waive (no `positionIds`) | Rejected: forces waiving positions that could still be reversed |
| F | Class gate + an in-service AND check | Rejected: invisible to annotation-only gate detection and the anti-drift pins |
| 1′ | **Close records only; never write a stock unit** (Architect antithesis): accept (i), (i′), (iii-a) and any amount-0 SU; refuse anything with stock on the tote | Rejected. It fixes c1wh and can't mis-release a lock, but it leaves case (ii) stranded with no operator path, and §1 names that as a driver. Item 2 makes (ii) the main waive input. The three-state `toteState` (fails closed) plus the waive-aware restore remove the mis-release risk that motivated 1′ |

---

## 10. Open Questions / Resolved Decisions

**Resolved (Nam, 2026-09-26; settled):**
- **D-a:** `stockReturned` flag → notify only when true.
- **D-b:** columns via V2.2.34.
- **Q5:** grant to outbound-manager + super-admin; constant `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL`.
- **Q2:** stamp `reversal_completed_at/by`, with `reversal_waived` as the discriminator.
- **Q9:** mobile Phase 2 goes on this ticket.
- **Q1:** case (ii) with `stockReturned=true` → refuse.
- **Q7:** not SDR-exported.
- **F4 (Round-1): suppression covers the whole order, permanently.** One `stockReturned=false` waive on any row of a CO ⇒ `ORDER_BATCH_REVERSAL_COMPLETED` is never sent for that CO, by waive or by complete, including complete's re-send path.
- **F3 (Round-1): `completeReversal` stays level-triggered.** A retry re-enqueues, which is the manual re-send path; complete only gains the suppression predicate. This withdraws the "edge trigger in both" half of the Q4+Q8 default. Waive is edge-triggered by its empty-targets early return.

**Defaults still in force (stated, overridable):**
- **Q3:** the amount-based ownership rule, now with a null → decline guard and a recovered-SU → decline guard.
- **Q6:** keep the CHECK, pinned by SQLSTATE 23514.

**Still open:**
- **O1.** Planner/reviewer refinements for the Round-2 review to confirm:
  - the three-state `toteState` (N1);
  - (i′) clears only when ON;
  - the already-waived term in the ownership sum;
  - the computed `waiveLockRetained`;
  - the 500-character reason cap.
- **O2.** `forklift1`, a shared-looking account, holds outbound-manager on c1wh prd and gains the waive override. It is reviewed at the PRD SET 9 pre-run (§8 step 4).
- **O3.** The operator-facing `stockReturned` prompt wording (draft: "Was the stock returned to its bin?").
- **O4.** UNVERIFIED: whether OMS alerts or reports on parcels whose reversal stays open. Under permanent suppression (F4) such an alert would never clear. Check oms-laravel-api before PRD promotion; this does not block Phase 1.

---

## Layer-2 Completeness Checklist

| # | Item | Status |
|---|---|---|
| 1 | Every §0 site mapped or excluded | ✓ §0 |
| 2 | Sibling sweep (readers of "pending"; complete's restore) | ✓ §2, §3.3.2, §6 |
| 3 | Transaction manager + rollbackFor | ✓ §3.2, T18b |
| 4 | Concurrency / lock point | ✓ §3.2 step 2, T9, T18 |
| 5 | Flyway version swept on all refs | ✓ §5.1 #1 |
| 6 | Migration idempotent + lane coverage | ✓ §3.6, T17 |
| 7 | Authz: five registration points + pins + SET 9 timing | ✓ §3.5, §5.1 #7, T11–T14, M7 |
| 8 | OMS / outbox effect | ✓ §3.3.1, T6, T19, T20, M5, §8 5b |
| 9 | Mobile/UI dependency | ✓ §3.8, Phase 2 |
| 10 | Verify script | no — T3 opt-in declined; every assertion is JUnit/IT/Jest |
| 11 | Docs drift | ✓ §4 |

---

## ADR

- **Decision.** Add `POST /v3/cancellation/{coId}/waive`, gated at method level by `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL` (outbound-manager, super-admin).
  - It closes the selected pending rows by stamping `reversal_completed_at/by` plus `reversal_waived`, the reason and `stock_returned`.
  - It never moves stock. It releases PICKED_FOR_GOODSOUT only when a three-state tote check proves the SU is on this order's tote, the SU was not recovered in this call, and the ownership rule holds.
  - It refuses `stockReturned=true` unless the stock is provably off the tote (or the amount is 0), and always when SHIPPED.
  - It notifies OMS through a shared enqueue method: complete stays level-triggered, waive is edge-triggered by its early return, and both are permanently suppressed per order after a `stockReturned=false` waive.
  - Complete's residue restore becomes waive-aware.
- **Drivers.**
  1. A live PRD order (c1wh) that cannot be closed, and an alert telling operators to use a function that doesn't exist.
  2. Inventory truth: never fabricate a movement, and never release a lock you can't prove you own.
  3. Authz stays visible to the annotation-based gate rails.
- **Alternatives considered.** A–F and 1′ (§9).
- **Why chosen.**
  - Stamping the existing column keeps every "pending" reader correct unchanged.
  - The FOR UPDATE finder gives waive↔complete exclusion.
  - A method-level annotation is the pattern the rails understand (ReplenishController).
  - The fail-closed `toteState` and the waive-aware restore let case (ii) work without the mis-release risk that Option 1′ avoids by giving it up.
- **Consequences.**
  - `reversal_completed_at` now means "closed", not "moved"; `reversal_waived` is the discriminator.
  - One `stockReturned=false` waive permanently silences the OMS notice for that order, including complete's re-send path.
  - Complete keeps its harmless retry re-enqueue.
  - Complete's restore changes only for orders with a waived row on the same SU.
  - `waiveLockRetained` rows keep a lock of 100 that no operator can clear.
  - Two arch pins change by design.
- **Follow-ups.**
  - The Phase 2 wms2-mobile-ui PR, a hard dependency before operators can use this.
  - SBDEV-3381 items 2–6, after this plan.
  - The post-promotion c1wh waive with its gating evidence and verification queries (§8 step 5).
  - O2 (`forklift1`) at the PRD SET 9 pre-run.
  - O4 (OMS open-reversal alerting).
  - A possible supervisor release of lock 100 for `waiveLockRetained` rows. Not built here; propose it only if real rows appear.
  - Update `wms2-cancel-cascade-workflow.md`.

