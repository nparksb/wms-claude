# Transaction Scope Refactoring: runClubLine() & closeBOL()

**Date:** 2026-04-08
**Status:** Implemented (Priority 1-4, 8-10)
**Branch:** `tmp/np2-api-problem-areas`

---

## Problem Statement

Two critical operations hold a single database transaction for an entire batch, causing lock contention and connection pool pressure under high concurrency:

1. **`runClubLine()`** — Creates unit loads, transfers stock for ALL orders, and updates states in one transaction
2. **`closeBOL()` / `closeBOLs()`** — Closes an entire BOL (or multiple BOLs) with all unitload moves, state updates, and audit records in one transaction

---

## Analysis: runClubLine()

**Location:** `CustomerorderBatchService.java:545-700`
**Entry point:** `GET /v3/clubLine/runClubLine/{orderBatchId}` (ClubLineController:160)

### Confirmed: Single Mega-Transaction

Yes, `runClubLine()` runs as a single `@Transactional(value = "tenantTransactionManager")`. All called methods either join the outer transaction or use `REQUIRES_NEW` only for sequence generation.

### What happens inside (in order)

| Phase | Lines | Operation | Lock Impact |
|-------|-------|-----------|-------------|
| A | 549-604 | `SELECT ... FOR UPDATE` on batch row + stock validation reads | Pessimistic lock acquired, held until commit |
| B | 578-597 | Reference data lookups (location, UL type, itemdata) | Read-only, but inside locked TX |
| C | 606-665 | **Loop: N orders x M positions** — create unit load, transfer stock (each with its own `FOR UPDATE` on stock unit) | N `REQUIRES_NEW` sub-TXs for sequence gen + N*M row locks accumulated |
| D | 668-690 | OMS HTTP notifications | **Deferred to afterCommit** (already fixed) |
| E | 692-699 | Bulk state updates (orders -> PACKED, positions -> PACKED, batch -> FINISHED) | Bulk UPDATEs, then commit releases all locks |

### Key Risks

| Risk | Severity | Detail |
|------|----------|--------|
| Long-held pessimistic lock on batch row | **HIGH** | Lock at line 550 held for entire O(N*M) processing |
| Accumulated row locks on stock units | **HIGH** | `transferStockToUnitLoad()` acquires `FOR UPDATE` per stock unit (line 188 of StockunitBusinessService). For 300 orders x 5 SKUs = ~1500 row locks held simultaneously |
| Sequence generation serialization | **MEDIUM** | Each `createUnitload()` triggers `REQUIRES_NEW` sub-TX on sequence table — serialization point across all concurrent UL creation |
| `historytote` write in afterCommit without TX | **LOW** | `ManageOrderService.customerOrderPicked()` saves back to `customerorder` table in afterCommit with no `@Transactional` — fire-and-forget auto-commit |

---

## Analysis: closeBOL() / closeBOLs()

**Location:** `BillofladingService.java:284-704`
**Entry points:**
- Single: `GET /v3/billOfLading/closeOutboundBol/{id}` (BillOfLadingController:203)
- Batch: `POST /v3/billOfLading/closeOutboundBols` (BillOfLadingController:229)

### Confirmed: Single Mega-Transaction (worse for batch)

`closeBOL(Long)` at line 283 is `@Transactional(value = "tenantTransactionManager")`. The batch variant `closeBOLs()` at line 271 also has `@Transactional` and loops calling `closeBOL(Long)` — but because this is an **intra-class (self) call**, Spring's proxy-based AOP **does not intercept** the inner `@Transactional`. All BOLs process in the outer transaction.

### What happens inside (in order)

| Phase | Lines | Operation | Lock Impact |
|-------|-------|-----------|-------------|
| A | 288-295 | In-memory concurrency guard + `SELECT ... FOR UPDATE` on BOL row | Pessimistic lock acquired |
| B | 300-335 | State and type validation | Read-only |
| C | 355-457 | Load all positions, build in-memory tree, 7 bulk `findAllById` queries | Reads within locked TX |
| D | 465-546 | **Loop: pallets -> parcels -> stock positions** — set states to FINISHED/CLOSED, build DTO tree | Dirty entities accumulated in persistence context |
| E | 549-551 | `saveAll` for BOL positions, orders, order positions | Batch writes |
| F | 554-618 | Bulk JPQL UPDATE for unitload location + entityLock | Bulk row updates |
| G | 622-632 | Bulk orphaned order position update | More JPQL UPDATEs |
| H | 635-636 | `entityManager.flush()` + `entityManager.clear()` | Forces all dirty state to DB, then detaches all entities |
| I | 653-655 | Save BOL as CLOSED (detached entity -> merge) | Re-attaches via merge |
| J | 659-666 | OMS notification | **Deferred to afterCommit** (already fixed) |
| K | 669-698 | Batch finalization — find completed batches, bulk update to FINISHED | Additional queries + updates |

### Key Risks

| Risk | Severity | Detail |
|------|----------|--------|
| `closeBOLs` mega-transaction (Spring self-call bypass) | **HIGH** | All BOLs close in one TX. Lock on first BOL held until ALL BOLs finish. One failure rolls back everything. |
| Pessimistic lock hold duration per BOL | **MEDIUM** | Single BOL lock held through ~10 phases of reads, writes, flush, clear, and batch finalization |
| `entityManager.clear()` mid-transaction | **LOW** | Detaches `billOfLading` at line 636, then saves it at 655 via `merge()` — works but wasteful |
| No lock timeout on `findByIdForUpdate` | **MEDIUM** | No `jakarta.persistence.lock.timeout` hint — concurrent requests block indefinitely |

---

## Recommended Strategies

These two issues require **different strategies** due to their different structures.

### Strategy A: runClubLine() — Chunked Processing Within Per-Order Transactions

The core problem is O(N*M) work under one transaction. Unlike `closeBOLs`, the batch here is a single logical entity (one `CustomerorderBatch`), so the solution is to break the inner loop into per-order (or chunked) transactions.

#### Option A1: Per-Order Transaction via Extracted Service (Recommended)

**Confidence: HIGH**

Extract the per-order processing (unit load creation + stock transfers) into a new `@Service` class so Spring's proxy creates a real transaction boundary per order.

```
CustomerorderBatchService.runClubLine()     -- orchestrator, minimal TX (validation + final state updates)
  |
  +-> ClubLineOrderProcessor.processOrder() -- NEW @Service, @Transactional per order
        |-> createUnitload()
        |-> transferStockToUnitLoad() x M positions
```

**Changes required:**
1. Create `ClubLineOrderProcessor` service with `@Transactional(value = "tenantTransactionManager")` per-order method
2. Split `runClubLine()` into:
   - **Validation phase** (own short TX or read-only TX): validate batch state, validate stock
   - **Processing phase** (no TX on orchestrator): loop calling `ClubLineOrderProcessor.processOrder()` per order
   - **Finalization phase** (own short TX): bulk state updates, batch state update
3. Move `historytote` UUID assignment into the per-order transaction (from the afterCommit callback)

**Trade-offs:**
| Pro | Con |
|-----|-----|
| Each order commits independently — failure isolates to one order | Partial success: some orders may be PACKED while others are not. Need a batch state like `PARTIALLY_COMPLETE` or a retry mechanism |
| Lock hold time drops from O(N*M) to O(M) per order | Validation phase sees a snapshot that may go stale by the time processing starts (unlikely in practice since the batch lock prevents concurrent runs) |
| Connection pool pressure reduced proportionally | More complex error handling and status reporting |

#### Option A2: Bulk Sequence Pre-Generation (Complementary)

**Confidence: HIGH**

Regardless of A1, reduce sequence serialization by generating N unit load numbers in a single `REQUIRES_NEW` call instead of N separate calls.

**Changes required:**
1. Add `SequenceTransactionService.getNextSequenceNumbers(String type, int count)` method
2. Modify `UnitloadService` to accept a pre-generated number

#### Option A3: Batch Size Guard (Quick Win)

**Confidence: HIGH**

Add a configurable maximum batch size (e.g., 500 orders) at the top of `runClubLine()`. Reject batches above the limit with a clear error message.

**Changes required:**
1. Add `wms.clubline.max-batch-size` property (default 500)
2. Add validation at the start of `runClubLine()`

---

### Strategy B: closeBOL() — Fix Self-Call Transaction Boundary + Per-BOL Isolation

The core problem is different: `closeBOL(Long)` for a single BOL is already reasonably scoped. The **real** issue is `closeBOLs()` collapsing all BOLs into one transaction due to Spring's self-call limitation.

#### Option B1: Extract Batch Orchestrator to Separate Service (Recommended)

**Confidence: HIGH**

Move the loop from `closeBOLs()` into a new `BillofladingBatchService` (or into the controller). Each `closeBOL()` call goes through Spring's proxy, getting its own transaction.

```
BillOfLadingController.closeOutboundBols()
  |
  +-> BillofladingBatchService.closeBOLs()   -- NEW @Service, NO @Transactional
        |
        +-> billofladingService.closeBOL(bolId1)  -- proxy call, own TX
        +-> billofladingService.closeBOL(bolId2)  -- proxy call, own TX
        +-> ...
```

**Changes required:**
1. Create `BillofladingBatchService` with a non-transactional `closeBOLs()` method that loops and delegates to `BillofladingService.closeBOL(Long)` via the injected proxy
2. Update `BillOfLadingController` to call the new service
3. Add error aggregation: collect per-BOL success/failure results and return a summary response
4. Remove `@Transactional` from the old `closeBOLs()` (or remove the method entirely)

**Trade-offs:**
| Pro | Con |
|-----|-----|
| Each BOL commits independently — failure of one doesn't roll back others | Partial success needs UI handling (some BOLs closed, some failed) |
| Lock hold time per BOL is only its own processing time | New service class adds slight indirection |
| OMS afterCommit notifications fire per BOL instead of batched at the end | Slightly more DB connections used (one TX per BOL vs one shared TX) |

#### Option B2: Add Pessimistic Lock Timeout (Complementary)

**Confidence: HIGH**

Add a lock timeout hint to `BillofladingRepository.findByIdForUpdate()` to prevent indefinite blocking.

**Changes required:**
1. Add `@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "5000"))` to `findByIdForUpdate` in `BillofladingRepository`
2. Consider the same for `CustomerorderBatchRepository.findByIdForUpdate`

#### Option B3: Clean Up entityManager.clear() Side Effect (Optional)

**Confidence: MEDIUM**

After the `entityManager.clear()` at line 636, re-fetch `billOfLading` from the DB instead of relying on `merge()` of the detached entity at line 655.

**Changes required:**
1. After line 636, add `billOfLading = billofladingRepository.findById(bolId).orElseThrow()`
2. Then set state and save as normal

---

## Cross-Cutting Improvements (Apply to Both)

| Improvement | Effort | Impact | Confidence |
|-------------|--------|--------|------------|
| **HttpRestService timeout configuration** — Add connection/read timeouts to `RestClient`. Other callers (e.g., `PickingorderBusinessService`) still make HTTP calls inside transactions. | LOW | MEDIUM | HIGH |
| **Pessimistic lock timeouts** on all `findByIdForUpdate` queries across the codebase | LOW | MEDIUM | HIGH |
| **Monitoring** — Add timing metrics (Micrometer) to both methods to track transaction duration and identify regressions | LOW | LOW | HIGH |

---

## Implementation Priority

| Priority | Item | Strategy | Effort | Risk Reduction | Status |
|----------|------|----------|--------|----------------|--------|
| 1 | Fix `closeBOLs` self-call (B1) | Extract batch orchestrator | Medium | **HIGH** — eliminates the multi-BOL mega-transaction | **DONE** — `BillofladingBatchService` created, controller updated, per-BOL TX isolation with error aggregation |
| 2 | Split `runClubLine` per-order (A1) | Extract order processor service | Medium-High | **HIGH** — reduces lock hold from O(N*M) to O(M) | **DONE** — `ClubLineOrderProcessor` created, `runClubLine()` split into validate/process/finalize phases, new `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` state added |
| 3 | Batch size guard (A3) | Quick validation | Low | **MEDIUM** — prevents pathological cases immediately | **DONE** — configurable `wms.clubline.max-batch-size` property (default 500), checked in `validateClubLine()` |
| 4 | Lock timeouts (B2) | Query hint annotations | Low | **MEDIUM** — prevents indefinite blocking | **DONE** — 5s `jakarta.persistence.lock.timeout` on `BillofladingRepository` and `CustomerorderBatchRepository` `findByIdForUpdate` |
| 5 | Bulk sequence generation (A2) | New method + refactor | Medium | **MEDIUM** — eliminates N sub-TXs | Backlog |
| 6 | HttpRestService timeouts | RestClient config | Low | **MEDIUM** — safety net for all HTTP calls | Backlog |
| 7 | entityManager.clear cleanup (B3) | Re-fetch after clear | Low | **LOW** — correctness improvement | Backlog |

---

## Key File References

### New Files Created
- `ClubLineOrderProcessor.java` — per-order transaction processor (extracted from `runClubLine`)
- `BillofladingBatchService.java` — batch BOL closing orchestrator with per-BOL TX isolation
- `ClubLineOrderProcessorUnitTest.java` — 6 unit tests for per-order stock transfer logic
- `BillofladingBatchServiceUnitTest.java` — 5 unit tests for batch close with error aggregation

### Modified Files
- `CustomerorderBatchService.java` — `runClubLine()` refactored into `validateClubLine()` + per-order delegation + `finalizeClubLine()` + `rollbackClubLineState()`
- `BillofladingService.java` — removed `closeBOLs()` method (moved to `BillofladingBatchService`)
- `BillOfLadingController.java` — added `BillofladingBatchService` dependency, `closeOutboundBols` uses batch service with error aggregation
- `BillofladingRepository.java` — added 5s `lock.timeout` `@QueryHint` on `findByIdForUpdate`
- `CustomerorderBatchRepository.java` — added 5s `lock.timeout` `@QueryHint` on `findByIdForUpdate`
- `WmsConstants.java` — added `ORDER_BATCH_CLUB_RUN_IN_PROGRESS = 527` state

### Updated Tests
- `CustomerorderBatchServiceUnitTest.java` — added `ClubLineOrderProcessor` mock, updated `runClubLine` tests to verify processor delegation, added batch size guard test
- `BillofladingServiceUnitTest.java` — removed obsolete `closeBOLs` tests
- `BillOfLadingControllerUnitTest.java` — added `BillofladingBatchService` mock, updated `closeOutboundBols` test

---

## Review of Backlog Priorities 5-7 and Additional Suggestions

### Verdict on Priority 5: Bulk sequence generation (A2)

**Not necessary for the issue described in this plan.**

Why:
- In the current refactor, `runClubLine()` delegates to `ClubLineOrderProcessor.processOrder(...)`.
- That processor creates parcels via `unitloadService.createUnitload(order.getParcelexternalnumber(), ...)`, i.e. it passes an explicit label/number.
- Because this path does **not** rely on generated unitload numbers, it does **not** create the N separate sequence sub-transactions that A2 was meant to eliminate.

Recommendation:
- Remove priority 5 from this plan, or re-scope it as a **general sequence-service optimization** for other workflows.
- It does not materially reduce lock hold time or transaction scope for the `runClubLine()` / `closeBOL()` problem analyzed here.

### Verdict on Priority 6: HttpRestService timeouts

**Not necessary as a remaining action for this plan.**

Why:
- The relevant notifications for this plan are already outside the main transactions:
  - `runClubLine()` sends OMS notifications after the processing/finalization flow completes.
  - `closeBOL()` uses `OmsNotificationService.sendAfterCommit(...)`.
- `HttpRestService` in the current workspace already sets timeouts (`connectTimeout=5000`, `readTimeout=15000`).

Recommendation:
- Mark priority 6 as **already satisfied / no longer backlog** for this plan.
- If kept, narrow it to a smaller follow-up: make the timeout values configurable via properties instead of hard-coded.

### Verdict on Priority 7: entityManager.clear cleanup (B3)

**Optional cleanup only; not necessary to improve the issue described in this plan.**

Why:
- In `BillofladingService.closeBOL(...)`, `entityManager.clear()` does detach `billOfLading`, but the method still runs inside the same transaction that acquired the `PESSIMISTIC_WRITE` lock.
- The later `billofladingRepository.save(billOfLading)` simply merges the detached entity back; this is stylistically awkward, but it is not the main source of lock contention or connection pressure.
- Re-fetching `billOfLading` after `clear()` adds readability, but it does not significantly shorten the transaction or reduce lock duration.

Recommendation:
- Keep priority 7 as a **very low-priority code hygiene item**, not as a meaningful concurrency fix.

### Additional Improvements — Code-Level Analysis and Verdict

These suggestions were raised during review. Each is analyzed against the actual code paths.

---

#### Suggestion 1: Stale detached `Stockunit` entities in the shared stock map

**VERDICT: CONFIRMED BUG — Must fix (Priority 8)**

**Root cause analysis:**

`validateClubLine()` loads `Stockunit` entities into `stockMap` within its transaction. When that TX commits, these become **detached**. The shared `stockMap` is then passed to each `ClubLineOrderProcessor.processOrder()`, each running in its own transaction.

Two concrete problems:

**Problem A — Stale `getAvailableamount()` (line 100 of `ClubLineOrderProcessor`):**
- The detached entity caches the amount from the validation TX. If order 1 drains a stockunit from 100→0, order 2 still sees `getAvailableamount() == 100` on the detached copy.
- In the old single-TX code, this was invisible because JPA L1 cache ensured `stockunitRepository.findById()` (line 305 of `StockunitBusinessService`) returned the **same managed object** in the list, so `.setAmount()` mutations were visible to the next loop iteration.
- In the new per-TX code, each `processOrder()` gets its own persistence context. The re-fetch inside `transferStockToUnitLoad()` (line 188) does catch reality and throws `BusinessException` if insufficient — so there's **no data corruption**. But the batch can **fail unnecessarily** because the stale hint causes it to attempt transfers on depleted stock units instead of skipping them.

**Problem B — Removal logic uses destination ID, not source ID (lines 143-145 of `ClubLineOrderProcessor`):**
- `transferStockToUnitLoad()` always returns `destinationStockUnit` (line 325 of `StockunitBusinessService`).
- In the **split path** (line 276-283, 298-302: source amount > transfer amount, or `fixLocationAssignment != null`), a new destination stockunit is created. Its ID ≠ source ID. The removal at line 143-145 collects destination IDs and tries to match against source list IDs — **no match, nothing removed**.
- In the **move path** (line 285-287: source fully transferred, no fix assignment), `destinationStockUnit = save(sourceStockunit)` — same entity, same ID. Removal **works correctly** in this path.
- Net effect: depleted source stock units from split-path transfers stay in the shared list. The next order retries them, `transferStockToUnitLoad` re-fetches and finds 0 available, and throws `BusinessException`.
- This was a **pre-existing latent bug** masked by JPA L1 cache in the single-TX code. The per-TX refactoring exposed it.

**Fix approach:**

Replace entity-based stock tracking with an immutable ID+amount snapshot map. In `ClubLineOrderProcessor.processOrder()`:
- Instead of iterating `List<Stockunit>` entities and calling `getAvailableamount()`, iterate snapshot records `(stockunitId, availableAmount)`.
- After each `transferStockToUnitLoad()` call, deduct the transferred amount from the snapshot (or remove if fully consumed). Use the **known transfer amount** for bookkeeping, not the returned entity's ID.
- Pass stock unit IDs to `transferStockToUnitLoad` (it already re-fetches by ID internally at line 188).

This eliminates both the stale-entity and wrong-ID-removal problems.

**Effort:** Medium  
**Risk if not fixed:** Batch failures on multi-order batches where stock units are split across orders

---

#### Suggestion 2: Partial-failure semantics for `runClubLine()`

**VERDICT: PARTIALLY VALID — Fix rollback bug (Priority 9), defer full idempotency**

**Confirmed bug — wrong rollback state:**
- `rollbackClubLineState()` (line 636) hardcodes `ORDER_BATCH_STAGING_LANE_ASSIGNED` as the rollback target.
- But `validateClubLine()` (line 557-558) accepts both `ORDER_BATCH_ACTIVATED` and `ORDER_BATCH_STAGING_LANE_ASSIGNED`.
- If the original state was `ORDER_BATCH_ACTIVATED`, rollback sets it to the wrong state.
- **Fix:** Save the original state before setting `IN_PROGRESS`, pass it to `rollbackClubLineState()`.

**Partial completion concern — valid but lower priority:**
- If order 7 fails after orders 1-6 committed, those 6 orders now have parcels + moved stock, but the batch rolls back to a retryable state.
- On retry, `processOrder()` for orders 1-6 calls `unitloadService.createUnitload(order.getParcelexternalnumber(), ...)` which checks `findByLabelid(name)` — returns existing unitload (idempotent for creation). But `order.setParcelId()` + `save()` overwrites with the existing ID (harmless). Then `transferStockToUnitLoad()` tries to move stock that's already been moved, and the source has 0 available → `BusinessException`.
- So retry is NOT idempotent. But full idempotency requires tracking which orders have been processed (e.g., skipping orders already in PACKED state), which is a larger design change.
- **Recommendation:** Fix the rollback bug now. Defer full idempotency to a follow-up, since the batch size guard (Priority 3) already reduces the likelihood of mid-batch failures.

**Effort:** Low (rollback fix), Medium-High (full idempotency)

---

#### Suggestion 3: Move batch finalization out of `closeBOL()` transaction

**VERDICT: NOT NEEDED NOW — Profile first**

The `completedBatchIds` query (line 675-682 of `BillofladingService`) and batch finalization UPDATE (line 685-690) add 2 queries to the `closeBOL()` TX. But:
- The main contention issue (multi-BOL mega-TX) is already fixed by Priority 1.
- For a single BOL, these 2 queries are ~5ms on indexed columns.
- Moving them out would add complexity (new method, separate TX) for marginal gain.
- **Recommendation:** Only pursue if production profiling shows `closeBOL()` still has excessive lock hold time. Not adding to plan.

---

#### Suggestion 4: Observability metrics

**VERDICT: VALID — Add as Priority 10**

Adding timing metrics to the 4 phases of `runClubLine()` and to `closeBOL()` would:
- Confirm that the refactoring actually reduced lock hold time in production
- Provide early warning if batch sizes grow beyond comfortable thresholds
- Help evaluate whether backlog items (A2, B3) are worth pursuing

**Effort:** Low (Micrometer `Timer` or simple log-based timing)

---

### Updated Implementation Priority Table

| Priority | Item | Strategy | Effort | Risk Reduction | Status |
|----------|------|----------|--------|----------------|--------|
| 1 | Fix `closeBOLs` self-call (B1) | Extract batch orchestrator | Medium | **HIGH** | **DONE** |
| 2 | Split `runClubLine` per-order (A1) | Extract order processor service | Medium-High | **HIGH** | **DONE** |
| 3 | Batch size guard (A3) | Quick validation | Low | **MEDIUM** | **DONE** |
| 4 | Lock timeouts (B2) | Query hint annotations | Low | **MEDIUM** | **DONE** |
| 5 | Bulk sequence generation (A2) | New method + refactor | Medium | **MEDIUM** | **Removed** — not relevant; `runClubLine` uses explicit parcel labels, not generated sequences |
| 6 | HttpRestService timeouts | RestClient config | Low | **MEDIUM** | **Removed** — already configured (connectTimeout=5000, readTimeout=15000); notifications are outside TX |
| 7 | entityManager.clear cleanup (B3) | Re-fetch after clear | Low | **LOW** | **Deferred** — cosmetic only, no concurrency impact |
| **8** | **Fix stale stock map in ClubLineOrderProcessor** | Replace entity list with ID+amount snapshots | Medium | **HIGH** — prevents false batch failures | **DONE** — `StockSnapshot` class replaces detached entities; tracked amounts deducted after each transfer; no more destination-ID-vs-source-ID removal bug |
| **9** | **Fix rollback state bug + partial-failure handling** | Save original state; skip already-processed orders on retry | Low (rollback) / Medium-High (idempotency) | **MEDIUM** — prevents wrong state after failure | **DONE** (rollback fix) — `originalBatchState` saved in `ClubLineValidationResult`, passed to `rollbackClubLineState()`; full retry idempotency deferred |
| **10** | **Observability metrics** | Log-based timing on runClubLine phases + closeBOL + closeBOLs | Low | **LOW** — validates production improvement | **DONE** — INFO-level timing logs with batch size, order count, per-phase elapsed ms, avg-per-order ms |
