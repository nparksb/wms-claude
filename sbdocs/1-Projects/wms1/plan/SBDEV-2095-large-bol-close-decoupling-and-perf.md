---
title: "SBDEV-2095 — Decouple OMS Notification from closeBOL Transaction + Large-BOL Performance Hardening"
ticket: "SBDEV-2095"
ticket_url: "https://app.clickup.com/t/868j6682t"
type: "bugfix + performance"
priority: "High"
status: "implemented"
project: [wms1]
version: "v1/wms-api"
requester: "David Oppenheim"
created: "2026-04-25"
updated: "2026-04-25 (implemented)"
related:
  - "[[260424-oms-notification-rollback-risk-remediation]]"
  - "[[SBDEV-2102-putaway-unit-load-not-found-stuck]]"
  - "[[SBDEV-2099-outbound-parcel-report-clears-after-palletize]]"
tags:
  - plan
  - billoflading
  - close-bol
  - oms-integration
  - after-commit-defer
  - performance
scope: wms1-shipping
---

# SBDEV-2095 — Decouple OMS Notification from closeBOL Transaction + Large-BOL Performance Hardening

**Ticket:** [SBDEV-2095](https://app.clickup.com/t/868j6682t)
**Project:** wms1 | **Version:** v1/wms-api | **Type:** bugfix + performance
**Priority:** High
**Status:** draft — awaiting review
**Date:** 2026-04-25

> ## Coordination with `260424-oms-notification-rollback-risk-remediation.md` (Plan A)
>
> The OMS-decoupling root cause behind SBDEV-2095 is shared with the broader cross-service program in **[Plan A](260424-oms-notification-rollback-risk-remediation.md)** (audit-driven, 14+ sites). To avoid two competing decoupling mechanisms in v1, ownership is split:
>
> - **Plan A owns the OMS-decoupling at `BillofladingService.closeBOL:584` (its `S3` row, §3.3).** It uses the program-wide helper `OmsNotificationHelper.deferToCommit(...)` and ships as part of Plan A rollout item 11.
> - **This plan (SBDEV-2095) ships immediately after Plan A item 11** as the rollout's item 12, narrowed to the closeBOL-specific concerns Plan A does not address: §3.3 (`bolToClose` correctness), §3.4 (Phase 9 N+1 → bulk `finalizeBatchesByIds`), §3.5 (IN-clause chunking helper), §3.6 (bulk carrier unlink in `UnitloadBusinessService.transferPalletTreesToLocation`).
> - **§3.1 (F1 — `BolClosedEvent` / `BolClosedEventListener`) and §3.2 (F2 — `MessageService.createMessageInNewTransaction`) below are SUPERSEDED by Plan A.** F1's responsibility moves to Plan A's helper invocation at §3.3 of that plan; F2's `REQUIRES_NEW` method moves into Plan A's §3.0.a as a prerequisite of the helper. Both sections are kept here for traceability with the SBDEV-2095 ticket's Fix Notes but **no longer have an implementation checklist** in this plan.
>
> **Net effect:** by the time this plan's checklist is executed, `closeBOL` is already OMS-decoupled (via Plan A's helper) and the `Message` row is already correctly persisted via `createMessageInNewTransaction(...)`. This plan only delivers F3–F6.

---

## 1. Problem Statement

When a very large outbound BOL (~900+ parcels observed in production) is closed via `BillofladingService.closeBOL`, the call **hangs and then fails**, but **OMS still receives the `ORDER_BATCH_SHIPPED` notification**. WMS rolls the transaction back, leaving the BOL in `OPEN` state. The two systems diverge — OMS thinks the BOL shipped, WMS does not — and the only recovery today is the manual SQL runbook attached to the ticket.

The OMS-decoupling structural fix is delivered by **Plan A's S3** (see Coordination box above). This plan additionally fixes:
- closeBOL-specific bugs that Plan A does not address (`bolToClose` `List<Long>` leak / race / inverted guard).
- large-BOL performance issues exposed by the same 900-parcel scenario (Phase 9 N+1, IN-clause cliffs at scale, per-pallet `save()` loop in the bulk pallet-tree transfer).

**User-visible symptoms:**
- Web UI "Close BOL" button spins, then errors out (timeout or 5xx).
- OMS shows the BOL/orders as `SHIPPED`; WMS Order Monitor shows them still in pre-ship state.
- Subsequent close attempts fail with `"BOL is currently in process."` (the in-memory `bolToClose` guard leaks — see §2.2 below).
- Large pallet trees on the staging lane remain visible in WMS UI even though OMS has already moved on.

**Reproduction:** close a BOL with ~900+ parcels in dev. Anecdotally the failure mode is one of:
- HikariCP `connectionTimeout` (default 30s) — connection held across heavy DML + 15s OMS POST + N+1 batch finalization loop.
- `OutOfMemoryError` accumulating session entities through many `save()` calls.
- DB statement-level timeout on a large `IN (...)` clause.

The contract violation (OMS notified before WMS commits) is the structural root cause; the perf issues are why the post-notification phases run long enough for the commit to fail.

---

## 2. Root Cause Analysis

### 2.1 Class-level transaction wraps the OMS HTTP POST (primary root cause)

`BillofladingService` is annotated `@Transactional` at the class level (`BillofladingService.java:27`), so every public method — including `closeBOL` — runs inside one transaction managed by Spring/Hibernate.

The current `closeBOL` flow has nine phases (the `===== PHASE N =====` markers in the source map directly to the Fix Notes' phase numbering — verified):

| Phase | Location | What it does |
|---|---|---|
| 1 | `BillofladingService.java:326-357` | Load all `BillofladingPosition` rows, build pallet/parcel/stock tree, bulk-delete garbage rows. |
| 2 | `BillofladingService.java:359-420` | Bulk-load all referenced `Unitload`, `Customerorder`, `CustomerorderPosition`, `CustomerorderBatch`, `Client`, `Shipperid`, `Itemdata` into in-memory maps. |
| 3 | `BillofladingService.java:422-500` | Build the `BillOfLadingWebServiceDto` payload (pallet → orders → positions) from in-memory maps — **zero queries**. |
| 4 | `BillofladingService.java:502-506` | `unitloadBusinessService.transferPalletTreesToLocation(...)` — bulk move pallet+parcel storage location to **Shipped**, batch-insert `UnitloadRecord` rows. |
| 5 | `BillofladingService.java:508-520` | Bulk update BOL position state, customer order state → `FINISHED` (700), customer order position state → `FINISHED`. |
| 6 | `BillofladingService.java:522-549` | Bulk update `unitload.entity_lock` and `stockunit.entity_lock` → `SHIPPED` (405). |
| 7 | `BillofladingService.java:551-560` | Save `Billoflading` row (state, shipped); `entityManager.flush()` + `clear()`. |
| 8 | `BillofladingService.java:562-606` | Build DTO; **HTTP POST to OMS** via `httpRestService.post(urlPath, payload)` (`HttpRestService.java` — 5 s connect timeout, 15 s read timeout); persist `Message` row (SENT or FAILED). |
| 9 | `BillofladingService.java:608-620` | Per-batch loop: `customerorderBatchRepository.findById(...)` → `customerorderRepository.findByOrderbatchId(...)` → `save(batch)` if all orders finished. |

The OMS POST in Phase 8 happens **inside** the `@Transactional` boundary. Because Phase 9 follows it, any failure in Phase 9 (timeout, OOM, optimistic-lock failure on a shared batch row, or just slow N+1) rolls back Phase 1-8's work — but OMS has already been notified at Phase 8. **The two systems can therefore never both be guaranteed consistent.**

This is the exact "external notification inside a transaction" anti-pattern flagged in `9-System/templates/wms-plan-template.md:193`.

### 2.2 `bolToClose` re-entrancy guard is broken three ways

`BillofladingService.java:107` declares:

```java
private List<Long> bolToClose = new ArrayList<Long>();
```

Used at `BillofladingService.java:266-272`:

```java
if (bolToClose.contains(billOfLading.getId())) {
    bolToClose.remove(billOfLading.getId());          // <-- removes the OTHER thread's guard
    throw new BusinessException("BOL is currently in process.");
}
bolToClose.add(billOfLading.getId());                 // <-- never paired with a remove on success/failure
```

Three defects:

1. **Leak on exception:** if any phase later throws (a Phase 9 OOM, a Phase 4 `FacadeException`, a network blip during Phase 8), control exits without removing the BOL ID from the list. The next legitimate close attempt for the same BOL ID hits the guard and is rejected forever (until JVM restart).
2. **Inverted guard semantics:** the guard removes the *first* caller's entry instead of leaving it in place. So a concurrent second call doesn't merely fail itself — it un-guards the first caller. After the throw, the first caller's BOL ID is no longer protected.
3. **Not thread-safe:** `ArrayList` is not safe for concurrent mutation. Two callers landing on different BOLs at the same time can corrupt the list (`ConcurrentModificationException`, lost adds). `BillofladingService` is a singleton bean shared across all HTTP threads.

The pessimistic lock at `BillofladingService.java:262` (`billofladingRepository.findByIdForUpdate(bolId)`) already serializes concurrent close attempts at the row level — the `bolToClose` set is redundant for *correctness*, but its current implementation actively *introduces* bugs.

### 2.3 Phase 9 is N+1 over batches and re-loads what was just cleared

`BillofladingService.java:608-620`:

```java
for (CustomerorderBatch staleBatch : orderBatchHashMap.values()) {
    CustomerorderBatch orderBatch = customerorderBatchRepository.findById(staleBatch.getId())...
    List<Customerorder> batchOrders = customerorderRepository.findByOrderbatchId(orderBatch.getId());
    if (batchOrders.stream().anyMatch(o -> o.getState() < WmsConstants.State.FINISHED)) { ... }
    else { orderBatch.setState(...); orderBatch.setStaginglaneId(null); save(orderBatch); }
}
```

For 900-parcel BOLs that span dozens of batches, this is `O(batches × (1 batch query + N orders query + 1 save))` after the persistence context was deliberately cleared at line 560. The orders query in particular is hitting freshly-updated rows immediately after the bulk update in Phase 5 — a NOT EXISTS guard collapses the entire loop into a single DML.

### 2.4 IN-clause sizes at 900+ parcels

Phase 5 / 6 build `Set<Long>` of every order id (~900), every order-position id (~900-1800), every parcel unitload id (~900), every stockunit id (~900-1800), and pass them as JPA parameters to native UPDATEs (`UnitloadRepository.java:208`, `:213`; equivalents on `Stockunit-`, `Customerorder-`, `CustomerorderPosition-` repositories). PostgreSQL JDBC has a hard 32 767 parameter limit per statement; performance also degrades meaningfully past ~1 000 elements as the planner's parameter-rewriting cost grows. This is mostly **defensive** — a single 900-parcel BOL fits — but a single BOL with two parcels per stock unit can push individual sets past 1 800, and any parsing-time hit multiplies across Phase 5/6's multiple bulk statements.

### 2.5 Per-pallet `save()` in `transferPalletTreesToLocation` carrier-unlink

`UnitloadBusinessService.java:316-320` — inside the otherwise-bulk pallet transfer, the carrier-unlink step still runs a per-pallet `save()`:

```java
for (Unitload pallet : pallets) {
    ...
    if (pallet.getCarrierunitloadId() != null) {
        pallet.setCarrierunitloadId(null);
        unitloadRepository.save(pallet);
    }
}
```

For a BOL with 30 pallets each carried on a parent pallet, that's 30 individual UPDATEs that could be one statement. Smaller win than Phase 9 but a free fix on the same touch.

### Affected Locations (this plan only — F3–F6)

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `service/BillofladingService.java` | 107 | `bolToClose` is `private List<Long>` (not Set, not concurrent) — replace with `ConcurrentHashMap.newKeySet()`. |
| 2 | `service/BillofladingService.java` | 266-272 | Inverted re-entrancy guard, no try/finally — rewrite as atomic `add` + outer try/finally. |
| 3 | `service/BillofladingService.java` | 608-620 | Phase 9 — per-batch findById + findByOrderbatchId + save loop → single bulk call. |
| 4 | `service/BillofladingService.java` | 508-549 | Phase 5 / Phase 6 bulk updates — wrap with chunking helper. |
| 5 | `service/UnitloadBusinessService.java` | 316-320 | Per-pallet `save()` for carrier unlink in bulk-transfer method → bulk native UPDATE. |
| 6 | `repo/jpa/CustomerorderBatchRepository.java` | (new method) | Add `finalizeBatchesByIds` bulk native UPDATE with NOT EXISTS guard. |
| 7 | `repo/jpa/UnitloadRepository.java` | (new method) | Add `clearCarrierUnitloadByIds` bulk native UPDATE. |

### Plan A locations (referenced for context, NOT touched by this plan)

| # | File | Line | Owner |
|---|------|------|-------|
| A | `service/BillofladingService.java` | 27 | Class-level `@Transactional`. **Plan A §3.3** verifies it stays in place around the helper invocation. |
| B | `service/BillofladingService.java` | 562-606 | Phase 8 — inline HTTP POST + Message persistence. **Plan A §3.3** moves to `OmsNotificationHelper.deferToCommit(...)`. |
| C | `service/MessageService.java` | 57-89 | `createServiceLog` ambient-tx semantics. **Plan A §3.0.a** adds `createMessageInNewTransaction(...)` (REQUIRES_NEW). |
| D | `service/util/OmsNotificationHelper.java` | (new file) | **Plan A §3 Template 3.** |

---

## 3. Design / Proposed Fix

### Verdict on each Fix Notes proposal

| # | Fix Notes proposal | Verdict | Owner | Notes |
|---|---|---|---|---|
| F1 | Decouple OMS POST via `BolClosedEvent` + `@TransactionalEventListener(AFTER_COMMIT)` | **Superseded — pattern changed** | **Plan A §3.3 (S3)** | Re-implemented using Plan A's `OmsNotificationHelper.deferToCommit(...)` to align with the existing in-production helper-style afterCommit pattern. No work for this plan; verify after Plan A item 11 lands. |
| F2 | `MessageService.createMessageInNewTransaction` with `@Transactional(REQUIRES_NEW)` | **Superseded — same method, different home** | **Plan A §3.0.a** | Folded into Plan A's helper prerequisite. No work for this plan; verify after Plan A's helper PR (item 1) lands. |
| F3 | `closeBOL` try/finally to drain `bolToClose` | **Approve, expanded** — replace `List` with `ConcurrentHashMap.newKeySet()` and remove the inverted "remove on contains" branch. The pessimistic lock at line 262 already provides the serialization the guard was attempting; the guard's only remaining job is fast-fail visibility, and that's only meaningful if it's correctly maintained. | This plan §3.3 | See §3.3. |
| F4 | Phase 9 N+1 → bulk `finalizeBatchesByIds()` with NOT EXISTS | **Approve** | This plan §3.4 | Confirmed: current loop reloads each batch + queries each batch's orders post-clear. Idempotent under concurrent close (NOT EXISTS only fires when *all* orders are finished). Increment `version` for optimistic-lock cohabitation with anything else holding the row. Re-uses the lock-ordering convention documented at `CustomerorderBatchRepository.java:30`. |
| F5 | IN-clause chunking at 500 ids | **Approve, but caveat** | This plan §3.5 | At 900 parcels you only have one bulk statement past the ~1 000 mark in the worst case. The hard cap is 32 767 (JDBC parameter limit), not 1 000. Chunk size 500 is conservative and right; the bigger win is *just doing it now* so a future 5 000-parcel BOL doesn't hit a planner cliff. Apply the same helper consistently across Phase 5 and Phase 6. |
| F6 | Bulk carrier unlink in `UnitloadBusinessService.transferPalletTreesToLocation` via `clearCarrierUnitloadByIds` | **Approve** | This plan §3.6 | Smaller win (~30 saves at 900 parcels) but on the same hot path. Verified per-pallet `save()` loop at `UnitloadBusinessService.java:316-320`. |

### 3.1 ~~Decouple OMS notification from the close-BOL transaction (F1)~~ — SUPERSEDED by Plan A §3.3

**Status:** SUPERSEDED. The OMS-decoupling at `BillofladingService.java:584` is owned by **[Plan A](260424-oms-notification-rollback-risk-remediation.md) §3.3 (S3)** and ships in Plan A rollout item 11, using `OmsNotificationHelper.deferToCommit(...)` (Plan A §3 Template 3) — the same mechanism already in production at `PickingorderBusinessService.finishPickingOrder:150-164`, `confirmPick:344-350`, `MobilePickingService.processPick:438-450`, and `CustomerorderBatchService.runClubLine:738-755`.

**Why the original `BolClosedEvent` / `BolClosedEventListener` design was withdrawn:** introducing a new `@TransactionalEventListener` pattern in v1 would have meant two competing decoupling mechanisms for the same problem class — the existing helper-style sites and a new event-style site. Plan A's program-level argument for DRY-ing 18+ sites to one helper is what tipped the decision. The event-listener design and its rationale are kept in the document history (see git log on this file) for traceability.

**What was preserved from this section:** the requirement that the post-commit POST + `Message` row use `MessageService.createMessageInNewTransaction(...)` (`@Transactional(REQUIRES_NEW)`) — see §3.2 below — moved into Plan A's helper as the prerequisite §3.0.a.

**No implementation work in this plan for F1.** Verify after Plan A item 11 lands: `BillofladingService.closeBOL` line 584 should call `OmsNotificationHelper.deferToCommit("closeBOL", "BOL " + bolId, () -> httpRestService.post(...), (succeeded, code, answer) -> messageService.createMessageInNewTransaction(...))`.

### 3.2 ~~`MessageService.createMessageInNewTransaction` (F2)~~ — SUPERSEDED by Plan A §3.0.a

**Status:** SUPERSEDED. The `@Transactional(propagation = REQUIRES_NEW)` variant of `MessageService.createServiceLog` is now Plan A's prerequisite §3.0.a. The motivation surfaced during this plan's review (the existing in-production `runClubLine:738-755` afterCommit reference quietly drops `Message` rows when called post-commit because `messageRepository.save` no-ops without an active transaction); credit is captured in Plan A's Revision 3 changelog.

**No implementation work in this plan for F2.** Verify after Plan A's prerequisite §3.0.a lands: `MessageService.createMessageInNewTransaction(...)` exists and is invoked by Plan A's helper.

### 3.3 `bolToClose` correctness fix (F3, expanded)

**Replace** `BillofladingService.java:107`:

```java
// before
private List<Long> bolToClose = new ArrayList<Long>();

// after
private final Set<Long> bolToClose = ConcurrentHashMap.newKeySet();
```

**Replace** `closeBOL` lines 261-273 with:

```java
public void closeBOL(Long bolId) throws FacadeException, BusinessException {
    Billoflading billOfLading = billofladingRepository.findByIdForUpdate(bolId)
            .orElseThrow(() -> new BusinessException("BOL not found: " + bolId));
    LOG.debug("start with billOfLading=" + billOfLading.getId());

    if (!bolToClose.add(billOfLading.getId())) {
        throw new BusinessException("BOL is currently in process.");
    }
    try {
        // ...existing Phase 1-9 body...
    } finally {
        bolToClose.remove(billOfLading.getId());
    }
}
```

`Set.add(...)` returns `false` if the element was already present — that's the atomic check-and-set the original code intended. The `finally` guarantees no leak under any throw path. The pessimistic row lock taken at line 262 is the *real* cross-thread guard; this in-memory set is now just a fast-fail short-circuit that correctly drains itself.

### 3.4 Phase 9 — bulk batch finalization (F4)

**New repository method** in `CustomerorderBatchRepository.java`:

```java
@Modifying
@Transactional
@Query(value =
    "UPDATE customerorder_batch cb " +
    "SET state = :finishedState, staginglane_id = NULL, version = cb.version + 1, modified = NOW() " +
    "WHERE cb.id IN (:ids) " +
    "  AND cb.state < :finishedState " +
    "  AND NOT EXISTS ( " +
    "      SELECT 1 FROM customerorder co " +
    "      WHERE co.orderbatch_id = cb.id " +
    "        AND co.state < :finishedState " +
    "  )", nativeQuery = true)
int finalizeBatchesByIds(@Param("ids") Collection<Long> ids,
                         @Param("finishedState") int finishedState);
```

Returns the affected row count for logging. The `state < :finishedState` guard makes the operation idempotent — a concurrent BOL close that already finalized the batch is a silent no-op.

**Replace** `BillofladingService.java:608-620` with:

```java
// === PHASE 9: bulk finalize batches whose orders are all FINISHED ===
if (!orderBatchHashMap.isEmpty()) {
    Set<Long> batchIdsToFinalize = orderBatchHashMap.values().stream()
        .map(CustomerorderBatch::getId).collect(Collectors.toSet());
    int finalized = chunked(batchIdsToFinalize, 500,
        ids -> customerorderBatchRepository.finalizeBatchesByIds(ids, WmsConstants.State.FINISHED));
    LOG.debug("Phase 9 finalized batches: requested=" + batchIdsToFinalize.size() + " applied=" + finalized);
}
```

Where `chunked(...)` is the helper described in §3.5.

**Side-effect audit:** the current `customerorderBatchRepository.save(orderBatch)` would trigger Hibernate `PreUpdate` / `PostUpdate` on `CustomerorderBatch`. Verified there are no such listeners on this entity (grep `@PreUpdate.*CustomerorderBatch` returns nothing). The `version + 1` increment in the native query keeps optimistic-lock cohabitation correct for any later code that reads-then-saves the same row in the same request.

### 3.5 IN-clause chunking helper (F5)

**Add** a small utility (private static in `BillofladingService` or new `util/CollectionChunker.java` if reused elsewhere):

```java
private static <T> int chunked(Collection<T> items, int chunkSize, java.util.function.ToIntFunction<List<T>> op) {
    if (items == null || items.isEmpty()) return 0;
    List<T> buffer = new ArrayList<>(items);
    int total = 0;
    for (int i = 0; i < buffer.size(); i += chunkSize) {
        total += op.applyAsInt(buffer.subList(i, Math.min(i + chunkSize, buffer.size())));
    }
    return total;
}
```

**Apply** to every Phase 5 / Phase 6 bulk update on a set whose worst-case size could exceed ~1 000. Concretely:

| Existing call | Touched set | Chunk |
|---|---|---|
| `customerorderRepository.updateStateByIds(FINISHED, allOrderIds)` | order ids (~900) | yes |
| `customerorderPositionRepository.updateStateByOrderIds(FINISHED, allOrderIds)` | order ids (~900) | yes |
| `unitloadRepository.updateEntityLockByIds(entityLock, allUnitloadIdsForLock)` | pallets + parcels (~930) | yes |
| `stockunitRepository.updateEntityLockByUnitloadIds(entityLock, childUnitloadIds)` | parcel ids (~900) | yes |
| `unitloadRepository.updateStoragelocationByIds(...)` (called from `transferPalletTreesToLocation`) | full pallet trees (~930-1800) | yes |
| `billofladingPositionRepository.updateStateByBillofladingId(bolState, bolId)` | scoped by FK, no IN | no |
| `customerorderBatchRepository.finalizeBatchesByIds(...)` (new) | unique batch ids (~30-50) | yes (cheap; same helper) |

The repository methods themselves don't need changes — chunking happens in the caller. Existing single-statement methods still get one statement when the input is small.

### 3.6 Bulk carrier unlink in `transferPalletTreesToLocation` (F6)

**New repository method** in `UnitloadRepository.java`:

```java
@Modifying
@Transactional
@Query(value = "UPDATE unitload SET carrierunitload_id = NULL, version = version + 1 " +
               "WHERE id IN (:ids) AND carrierunitload_id IS NOT NULL", nativeQuery = true)
int clearCarrierUnitloadByIds(@Param("ids") Collection<Long> ids);
```

**Replace** `UnitloadBusinessService.java:316-320` with:

```java
List<Long> palletsWithCarrier = pallets.stream()
    .filter(p -> p.getCarrierunitloadId() != null)
    .map(Unitload::getId)
    .collect(Collectors.toList());
if (!palletsWithCarrier.isEmpty()) {
    unitloadRepository.clearCarrierUnitloadByIds(palletsWithCarrier);
    // mirror the in-memory state so downstream phases see the unlink
    pallets.forEach(p -> { if (palletsWithCarrier.contains(p.getId())) p.setCarrierunitloadId(null); });
}
```

The in-memory mirror is required because the same `pallets` list is read later in the same method (`parentIdMap.put(pallet.getId(), null)` at line 330) and `BillofladingService` builds its DTOs from these in-memory unitloads (Phase 3, lines 422-500) — though Phase 3 actually runs *before* Phase 4 calls this method, so for the close-BOL path the in-memory mirror is defensive; required for any other caller.

---

## 4. V1/V2 Applicability

This plan targets v1/wms-api only; v2 has its own equivalent work to track separately.

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| `closeBOL` exists | Yes — `BillofladingService.java` | Yes — `wms2-api` has the equivalent service | v2 likely has the same structural OMS-in-transaction issue; create a paired plan via `wms-v2-migrate` after this lands. |
| `OmsNotificationHelper.deferToCommit(...)` available | Yes — Plan A delivers it in v1 | v2 has its own helper port (per Plan A §4) | Pattern ports cleanly. |
| Multi-tenant context | v1 is single-tenant per deploy (no `TenantContext` in main java tree — grep) | v2 is multi-tenant via headers + dynamic routing | v2 port MUST re-establish tenant context if the helper's afterCommit lane moves async. |
| Multi-replica deployment | v1 typically single-instance per tenant | v2 is horizontally scaled | v2 port MUST think through "another replica retries while this one's afterCommit hook is mid-POST" — `Message` row idempotency on `sharedUniqueBolId` would be the right key. |

### What Needs Porting (to v2)
1. The whole afterCommit decoupling (delivered via Plan A's helper) — plus tenant-context bridging if the helper's afterCommit lane becomes async on v2.
2. The bolToClose correctness fix (or its v2 equivalent).
3. The Phase 9 NOT EXISTS bulk finalize.
4. IN-clause chunking helper.

### What Does NOT Need Porting
- v1's `bolToClose` `List<Long>` field doesn't exist in v2 if v2 uses the row lock alone — verify during the v2 migrate pass.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No schema change. Flyway version unchanged. | dev | Native queries reference existing columns only. |
| 2 | **Feature flags / system properties** | `WMS_WEBSERVICE_ORDER_BATCH_SHIPPED_URL` system property must be set (already required today). | dev | No new sysprops introduced. |
| 3 | **Config / env changes** | None. | dev | HTTP timeouts at `HttpRestService.java` (5 s connect, 15 s read) remain unchanged. |
| 4 | **Deploy-order dependencies** | None — OMS contract is unchanged. | dev | OMS still receives the same `ORDER_BATCH_SHIPPED` payload at the same URL. |
| 5 | **Data migration** | One-time SQL runbook (already in ticket description) for any BOLs currently stuck in OMS-closed/WMS-open state. | DBA | Run **before** deploy if any prod BOLs are stuck. |
| 6 | **External systems** | OMS endpoint must accept the existing payload (no contract change). | OMS team | No new endpoint, no new fields. |
| 7 | **Access / permissions** | None. | N/A | |
| 8 | **Monitoring / alerts** | New ERROR log line: `"OMS BOL-closed notification failed; recording FAILED message for retry"`. Add an alert if `Message.status='FAILED' AND process='ORDER_BATCH_SHIPPED'` rate exceeds N/hour. | ops | Existing `Message` table already supports this — likely a Grafana panel. |

### 5.2 Implementation Checklist (this plan only — F3–F6)

> **Blocked-by:** Plan A rollout item 11 (S3 — closeBOL afterCommit decoupling). Run after Plan A item 11 is verified in production.

#### Pre-flight verification (Plan A artifacts must be present)

- [ ] `service/util/OmsNotificationHelper.java` exists with `deferToCommit(...)` (Plan A §3 Template 3).
- [ ] `MessageService.createMessageInNewTransaction(...)` exists with `@Transactional(propagation = REQUIRES_NEW)` (Plan A §3.0.a).
- [ ] `BillofladingService.closeBOL:584` invokes the helper instead of an inline `httpRestService.post(...)` block (Plan A §3.3).

#### F3 — `bolToClose` correctness

- [ ] Replace `bolToClose` declaration at `BillofladingService.java:107` with `private final Set<Long> bolToClose = ConcurrentHashMap.newKeySet();`.
- [ ] Rewrite the entry guard at `closeBOL` lines 266-272: `if (!bolToClose.add(billOfLading.getId())) throw new BusinessException("BOL is currently in process.");`.
- [ ] Wrap Phases 1-9 of `closeBOL` in `try { ... } finally { bolToClose.remove(billOfLading.getId()); }`.

#### F4 — Phase 9 bulk finalize

- [ ] Add `CustomerorderBatchRepository.finalizeBatchesByIds(...)` native UPDATE with NOT EXISTS guard.
- [ ] Replace the per-batch loop at `BillofladingService.java:608-620` with a single chunked call to `finalizeBatchesByIds(...)`.

#### F5 — IN-clause chunking helper

- [ ] Add a `chunked(...)` static helper (private to `BillofladingService` initially; promote to `service/util/CollectionChunker.java` if a second caller appears).
- [ ] Apply to: `customerorderRepository.updateStateByIds`, `customerorderPositionRepository.updateStateByOrderIds`, `unitloadRepository.updateEntityLockByIds`, `stockunitRepository.updateEntityLockByUnitloadIds`, `unitloadRepository.updateStoragelocationByIds` (called from `transferPalletTreesToLocation`), and the new `finalizeBatchesByIds`.

#### F6 — Bulk carrier unlink

- [ ] Add `UnitloadRepository.clearCarrierUnitloadByIds(...)` native UPDATE.
- [ ] Replace the per-pallet `save()` loop at `UnitloadBusinessService.java:316-320` with the bulk call + in-memory mirror of the unlink for downstream phases.

#### Verification & sign-off

- [ ] Unit tests added (see §6).
- [ ] Integration tests added (Testcontainers — see §6).
- [ ] Code review completed.
- [ ] Manual smoke test on staging with a realistic BOL (≥ 100 parcels, ideally one with shared-batch siblings).
- [ ] Confirm `bolToClose` is empty after each `closeBOL` call (success and failure paths) via test or temporary log.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| Normal close (small BOL) | Close a 10-parcel BOL with one batch | All 9 phases succeed; 1 OMS POST fires after commit; `Message` row SENT; batch finalized (state=700, staginglane_id=NULL). |
| Large BOL close | Close a 900-parcel BOL across 30 batches | Same outcome; total time within HikariCP `connectionTimeout` (default 30 s) since OMS POST is now post-commit; Phase 9 single bulk statement. |
| OMS unreachable in afterCommit hook | Close a 10-parcel BOL while OMS endpoint returns 503 | WMS commit succeeds; BOL state = CLOSED; `Message` row FAILED via Plan A helper's `MessagePersister`; ERROR log emitted; subsequent `MessageService.resendMessage(...)` resends successfully. |
| Phase 9 fails mid-flight | Force a Hibernate exception in the bulk finalize call | Outer transaction rolls back; **no OMS POST** (afterCommit hook never fires); `bolToClose` set is drained by the try/finally added in §3.3; next call to close the same BOL succeeds. |
| Concurrent close attempts on same BOL | Two threads call `closeBOL(bolId)` simultaneously | The pessimistic row lock at line 262 serializes them; the loser sees `BOL not found` (if first finishes) or completes its own close (if first rolled back); `bolToClose` re-entrancy guard fast-fails any in-flight duplicate. |
| Concurrent close attempts on different BOLs sharing a batch | Two threads close different BOLs whose orders share batch B | Both Phase 9 calls hit the NOT EXISTS guard idempotently; whichever sees all orders FINISHED finalizes the batch; the other no-ops. No optimistic-lock storm. |
| JVM crash between WMS commit and afterCommit hook | Force a JVM kill -9 between commit and the helper's hook firing | WMS DB shows BOL CLOSED but no `Message` row. Manual reconciliation needed (Plan A's Phase 2a auto-resender does NOT cover this case — only FAILED rows). Documented in §8. |

### New / updated tests

| Test class | Test method | What it asserts | Owner |
|---|---|---|---|
| `BillofladingServiceTest` | `closeBOL_drainsBolToCloseOnException` | Force a Phase 9 exception; assert `bolToClose` set is empty after the throw. | This plan §3.3 |
| `BillofladingServiceTest` | `closeBOL_drainsBolToCloseOnSuccess` | Successful close; assert `bolToClose` set is empty afterwards. | This plan §3.3 |
| `BillofladingServiceTest` | `closeBOL_secondConcurrentCallShortCircuits` | Add `bolId` to `bolToClose` manually; assert second call throws `"BOL is currently in process."` and does NOT remove the original. | This plan §3.3 |
| `CustomerorderBatchRepositoryTest` | `finalizeBatchesByIds_skipsBatchesWithUnfinishedOrders` | Two batches: one all-finished, one with one unfinished order; assert exactly the all-finished one is updated. | This plan §3.4 |
| `CustomerorderBatchRepositoryTest` | `finalizeBatchesByIds_isIdempotent` | Run twice; assert second run affects 0 rows but does not error. | This plan §3.4 |
| `UnitloadRepositoryTest` | `clearCarrierUnitloadByIds_setsCarrierToNull` | Three pallets, two have carriers; assert only those two are nulled and version bumped. | This plan §3.6 |
| `BillofladingServiceTest` | `closeBOL_largeBolWith900Parcels` | Synthetic data via `@Sql`; assert all phases complete without timeout; verify chunking happens (mock the chunk helper or assert by row counts). | This plan §3.4–§3.6 |
| `BillofladingServiceTest` | `closeBOL_phase9Rollback_noOmsCall` | Already covered by Plan A `S3` test of the same name; this plan re-runs it after the bulk-finalize change to confirm the rollback semantics are preserved. | Plan A §3.3 (regression here) |
| `MessageServiceTest` | `createMessageInNewTransaction_runsInIsolation` | Owned by **Plan A §3.0.a**; not duplicated here. | Plan A |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| UI close-BOL happy path | staging | 1. Open Truck Loading. 2. Pick a small BOL. 3. Close. | Spinner clears within seconds; BOL shows CLOSED; OMS Order Monitor reflects shipped. | |
| UI close-BOL with simulated OMS down | staging | 1. Block OMS endpoint via `iptables`/proxy. 2. Close a BOL. | WMS shows CLOSED; Message Monitor (`/v3/message/...`) shows FAILED row for ORDER_BATCH_SHIPPED. Resend works once OMS is back. | |
| Large-BOL close | staging | 1. Stage a 100+ parcel BOL via the `addToBOL` flow. 2. Close. | Completes within HikariCP `connectionTimeout` (default 30 s). No `connection is not available` log lines. | |
| SQL sanity post-close | staging DB | `SELECT state FROM billoflading WHERE id = :bolId; SELECT state, COUNT(*) FROM customerorder_batch WHERE id IN (...) GROUP BY state;` | BOL=CLOSED; all touched batches state=700. | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=BillofladingServiceTest,CustomerorderBatchRepositoryTest,UnitloadRepositoryTest` | | |
| `mvn verify` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Concurrent multi-replica retry of FAILED Message rows | v1 is single-instance per tenant; this is a v2 concern only. |
| Stress test at 5 000+ parcels | Production hasn't hit this yet; revisit if/when ticket comes in. |

---

## 7. Horizontal Scalability Validation

Not applicable to v1/wms-api (single-instance-per-tenant deployment). The v2 port plan **must** address this section in full — particularly Concern #10 (external notifications inside transactions, which is the structural fix this plan + Plan A together deliver) and Concern #6 (retry/idempotency across replicas if Plan A's helper afterCommit lane becomes async on v2).

---

## 8. Notes

### Out of scope (file separately if needed)

- **OMS-side idempotency on `sharedUniqueBolId`.** Today nothing prevents the helper's afterCommit hook from POSTing twice if a deploy restart races with a not-yet-fired hook. v1 is low-replica and the OMS already receives the `sharedUniqueBolId` field — making OMS idempotent on it is a separate hardening ticket. (Tracked in Plan A §9 open questions.)
- **Outbox pattern.** A more robust approach than the helper's afterCommit hook is a transactional outbox table polled by a background sweeper. Plan A's **Phase 2b §3.14** sketches this; out of scope for SBDEV-2095.
- **Auto-retry of FAILED Message rows.** Plan A's **Phase 2a §3.13** adds a scheduled `MessageRetryJobService` that polls `message WHERE status='FAILED' AND retries<5` and invokes `MessageService.resendMessage(...)`. If Plan A bundles Phase 2a with rollout item 11, this plan benefits automatically.

### Operator-facing post-deploy task

If any BOLs are currently stuck (OMS-closed but WMS-open) at deploy time, run the SQL runbook from the ticket description before the new code ships. Mark them with a comment in the corresponding `Message` row so audit trails reflect the manual reconciliation.

### Document version history

- 2026-04-25 — Initial draft from SBDEV-2095 Fix Notes; code-grounded against `v1/wms-api` `main`. F1=`BolClosedEvent`/`@TransactionalEventListener`, F2=`createMessageInNewTransaction`, F3-F6=closeBOL-specific bug + perf.
- 2026-04-25 (rev 2) — Coordination with [Plan A](260424-oms-notification-rollback-risk-remediation.md). F1 and F2 SUPERSEDED — moved to Plan A §3.3 / §3.0.a using the program-wide `OmsNotificationHelper.deferToCommit(...)`. This plan narrows to F3-F6 and runs as Plan A rollout item 12. Original event-listener design preserved in §3.1's superseded note for traceability.
- 2026-04-25 (rev 3) — F3–F6 implemented. See Implementation Status below.

---

## Implementation Status (2026-04-25)

| Feature | Status | Files touched | Tests added | Pass evidence |
|---------|--------|---------------|-------------|---------------|
| **F3** — `bolToClose` correctness | DONE | `service/BillofladingService.java` | 3 unit tests in `BillofladingServiceUnitTest` | `mvn test -Dtest=BillofladingServiceUnitTest` → 39/39 pass |
| **F4** — Phase 9 bulk `finalizeBatchesByIds` | DONE | `service/BillofladingService.java`, `repo/jpa/CustomerorderBatchRepository.java` | 2 IT tests in `CustomerorderBatchRepositoryIT` | Compiles clean; IT tests require Docker (not available in current env) |
| **F5** — IN-clause chunking helper | DONE | `service/BillofladingService.java` (private `chunked()`), `service/UnitloadBusinessService.java` (private `chunked()`), `repo/jpa/CustomerorderRepository.java`, `repo/jpa/CustomerorderPositionRepository.java`, `repo/jpa/UnitloadRepository.java`, `repo/jpa/StockunitRepository.java` | (covered by existing unit tests + F3 tests) | `mvn compile -q` → clean |
| **F6** — Bulk carrier unlink | DONE | `service/UnitloadBusinessService.java`, `repo/jpa/UnitloadRepository.java` | 1 IT test in `UnitloadRepositoryIT` | Compiles clean; IT test requires Docker |

### Design decisions

- **`void` → `int` on 5 repo methods** (`updateStateByIds`, `updateStateByOrderIds`, `updateEntityLockByIds`, `updateEntityLockByUnitloadIds`, `updateStoragelocationByIds`): preferred over a counting lambda wrapper — cleaner call sites, additive change.
- **`chunked()` duplicated** in `BillofladingService` and `UnitloadBusinessService`: the F5 scope includes one call in each service; duplicating is the smallest-diff approach given both are private-static helpers. Promote to `service/util/CollectionChunker.java` if a third caller appears.
- **Plan A status**: `OmsNotificationHelper.deferToCommit` was NOT yet applied to `BillofladingService.closeBOL` in the current working tree at the time F3-F6 were implemented. F3-F6 are independent of Phase 8 and compile/test correctly against the current file. Plan A §3.3 should be applied before this branch is merged to ensure the deferral is in place.
- **IT test Docker dependency**: `CustomerorderBatchRepositoryIT` and `UnitloadRepositoryIT` follow the `@SpringBootTest + @ExtendWith(AppPostgresDBSetupExtension.class)` pattern used by `ClientRepositoryIT` / `BoxtypeRepositoryIT`. They require the Docker daemon at test time (`mvn verify` or `mvn test -Dtest=...` in a Docker-enabled environment).
