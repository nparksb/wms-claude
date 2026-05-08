## Run Club availability exception analysis (2026-04-05)

### Incident

Observed production exception during `CustomerorderBatchService.runClubLine(...)`:

- `BusinessException: amount=2.0000 requested is more than available=0.0000`

The log context shows Run Club selected a staging-lane stock unit and then failed inside `StockunitBusinessService.transferStockToUnitLoad(...)`.

### Primary finding

The failure is primarily caused by a logic mismatch between **Run Club stock validation/selection** and **stock transfer enforcement**.

#### 1. Run Club validates against total amount, not available amount

In `src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java`:

- `validateStockOnStagingLane(...)` builds `availableItemDataIntegerMap` using `stockUnit.getAmount().intValue()` (lines 504-513).
- It does **not** subtract `reservedamount`.
- Therefore a stock unit with `amount=2` and `reservedamount=2` contributes `2` to the staging-lane total, even though its real available quantity is `0`.

#### 2. Run Club selects stock units using total amount, not available amount

Still in `runClubLine(...)`:

- it iterates `List<Stockunit> stockUnits = itemDataListMap.get(itemData)` (line 632)
- then compares `stockUnit.getAmount()` with `requiredAmount` (lines 642-656)
- it never checks `stockUnit.getAvailableamount()` or `amount - reservedamount`

So Run Club can select a stock unit whose entire quantity is already reserved.

#### 3. Transfer enforces available amount correctly

In `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java`:

- `transferStockToUnitLoad(...)` rejects the move if
  `sourceStockunit.getAmount().subtract(sourceStockunit.getReservedamount()).compareTo(amount) < 0`
  (lines 186-187)

This is the exact exception being seen.

### Why the observed message says `available=0.0000`

For the failing stock unit, the in-memory entity entering transfer had:

- `amount = 2.0000`
- `reservedamount = 2.0000`
- `available = amount - reservedamount = 0.0000`

`runClubLine(...)` treated that stock unit as usable because it only looked at `amount`, while `transferStockToUnitLoad(...)` correctly rejected it because it looked at `amount - reservedamount`.

This explains the exact sequence from the log:

1. Run Club found `stockUnits size = 1`
2. the stock unit looked sufficient by total amount
3. transfer was attempted for `2.0000`
4. transfer failed because actual available quantity was `0.0000`

### Supporting code evidence

#### `Stockunit` model defines available amount explicitly

In `src/main/java/net/aim_ai/wms/model/Stockunit.java`:

- `getAvailableamount()` returns `amount.subtract(reservedamount)` (lines 53-57)

So the domain model already defines the correct availability rule. Run Club is simply not using it.

#### Reservation flows do exist and use `reservedamount`

In `src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java`:

- order release creates reservations via `stockunitBusinessService.changeReservedAmount(stockUnit, ..., positiveAmount, ...)` (lines 572, 595, 619, 627)
- overstock allocation explicitly calculates `available = stockUnit.getAmount().subtract(stockUnit.getReservedamount())` (lines 589 and 611)
- candidate stock is loaded via `getStockUnitsByItemDataIdForUpdate(...)`, which already filters to `amount > reservedamount`

This shows the rest of the picking/release flow already treats **available amount** as the real constraint.

#### Reservation mutation is lock-aware; Run Club is not

`StockunitBusinessService.changeReservedAmount(...)` re-loads the stock unit with `findByIdForUpdate(...)` before changing reservations.

By contrast, `runClubLine(...)`:

- loads stock with `stockunitRepository.findByUnitloadIdIn(...)`
- keeps that list in memory
- later passes those entities into `transferStockToUnitLoad(...)`

No pessimistic lock is taken during stock selection for Run Club.

### Secondary finding: concurrency risk still exists

Even after fixing the deterministic bug above, there is still a smaller TOCTOU risk.

Reason:

- Run Club reads candidate stock without `FOR UPDATE`
- another transaction can reserve the same stock via `changeReservedAmount(...)`
- `transferStockToUnitLoad(...)` performs its availability check against the passed entity before reloading the source row with a lock

So the current implementation does not guarantee that the availability used for selection is still valid at transfer time.

This secondary risk does **not** appear necessary to explain the reported incident, because the current code already has a direct deterministic bug that can produce the exact failure with no race at all.

### Additional related mismatch

`CustomerorderBatchService.getClubLineSKUOverview(...)` uses `stockunitRepository.getAmountAvailable(...)`.

However in `src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java` that query is:

- `SELECT sum(stockUnit.amount) ...` (lines 44-51)

It does **not** subtract `reservedamount`, despite the method name implying availability.

This can mislead UI/users/operators into believing staging-lane stock is available when it is only present physically but fully reserved.

### Root cause conclusion

The most likely root cause of this incident is:

> Run Club counted and selected a stock unit by **physical quantity** (`amount`) instead of **available quantity** (`amount - reservedamount`). The selected stock unit was fully reserved, so transfer failed with `available=0.0000`.

### Safe fix recommendations (do not implement yet)

#### Fix 1 — align Run Club validation with business availability rules

In `validateStockOnStagingLane(...)`:

- sum `stockUnit.getAvailableamount()` instead of `stockUnit.getAmount()`
- ignore stock units where available amount is `<= 0`

This will make Run Club fail early with a correct “not enough stock” style error instead of failing mid-transfer.

#### Fix 2 — align Run Club stock selection with the same rule

In `runClubLine(...)`:

- compare `stockUnit.getAvailableamount()` against `requiredAmount`
- when partially consuming a stock unit, transfer only the available quantity
- skip stock units whose available quantity is `<= 0`

This keeps execution consistent with `transferStockToUnitLoad(...)`.

#### Fix 3 — apply the same eligibility filters used elsewhere

Prefer a repository query for staging-lane candidates that filters by:

- `su.amount > su.reservedamount`
- `su.entity_lock = 0`
- `ul.entity_lock = 0`
- `location.entity_lock = 0`

This would make Run Club use the same stock-eligibility semantics already used by picking/release flows.

#### Fix 4 — harden against races

For robust concurrency behavior, either:

- load candidate stock units with pessimistic locking (`FOR UPDATE`) when Run Club begins consuming them, or
- re-fetch the source stock unit with `findByIdForUpdate(...)` at the start of `transferStockToUnitLoad(...)` before checking availability

Without this, a concurrent reservation can still invalidate a previously-read stock unit.

#### Fix 5 — correct misleading “available” reporting

Review `getAmountAvailable(...)` and any Club Line UI/API that presents “available” quantity.

If the intended value is true availability, it should report `sum(amount - reservedamount)` (with the same lock filters), not `sum(amount)`.

### Suggested regression tests

Add unit tests for `CustomerorderBatchService.runClubLine(...)` covering:

1. stock unit with `amount=2`, `reservedamount=2`, required `2` -> should fail validation / report insufficient stock before transfer
2. mixed stock units where one is fully reserved and another has positive availability -> should skip the reserved unit and transfer from the available one
3. multiple stock units with partial reservations -> should consume only available quantities
4. Club Line SKU overview should not report reserved stock as available

### Confidence assessment

Confidence is high that the **primary incident cause** is the validation/selection mismatch described above, because:

- the exact exception text matches the transfer availability check
- the current Run Club path ignores `reservedamount`
- the `Stockunit` model and order-release flows already define availability as `amount - reservedamount`
- the reported numbers (`requested=2`, `available=0`) match a fully-reserved stock unit scenario exactly

---

## Code review (2026-04-05)

### Validation of original fix recommendations

All five fix recommendations have been validated against the source code. Each is confirmed correct.

| Fix | Verdict | Evidence |
|-----|---------|----------|
| Fix 1 — validation uses `amount` not available | **Confirmed** | `CustomerorderBatchService.java:504-513` — `stockUnit.getAmount().intValue()` with no subtraction of `reservedamount` |
| Fix 2 — selection uses `amount` not available | **Confirmed** | `CustomerorderBatchService.java:640-656` — compares `stockUnit.getAmount()` against `requiredAmount`, never checks `getAvailableamount()` |
| Fix 3 — apply eligibility filters from picking flows | **Confirmed** | `mapStockUnitsToItemData()` (line 548) uses `findByUnitloadIdIn()` which is a plain `SELECT ... WHERE unitloadId IN (...)` — no entity_lock, no location_area filters. Compare with `getStockUnitsByItemDataIdForUpdate` (StockunitRepository:95-107) which filters by `entity_lock = 0` on stockunit, unitload, location, and `amount > reservedAmount` |
| Fix 4 — harden against races | **Confirmed** | `findByUnitloadIdIn()` has no locking. Additionally, `transferStockToUnitLoad` lines 294 and 298-299 re-fetch source/destination with plain `findById()` (not `findByIdForUpdate()`), so even the mutation path lacks a pessimistic lock |
| Fix 5 — misleading `getAmountAvailable` | **Confirmed** | `StockunitRepository.java:44-51` — `SELECT sum(stockUnit.amount)` with no `reservedamount` subtraction and no `entity_lock` filters |

### Additional findings from code review

#### Finding A — Partial-transfer branch also uses total amount (Bug, same root cause) — IMPLEMENTED (Phase 1)

**Location:** `CustomerorderBatchService.java:654-658`

When a stock unit has less total amount than required, the `< 0` branch transfers `amountOnSourceStockUnit` which is set to `stockUnit.getAmount()` (line 640), not `stockUnit.getAvailableamount()`.

```java
// Line 640 — uses total, not available
BigDecimal amountOnSourceStockUnit = stockUnit.getAmount();
// ...
// Line 656 — transfers the full total amount
Stockunit stockUnitUpdated = stockunitBusinessService.transferStockToUnitLoad(
    stockUnit, packageUnitLoad, amountOnSourceStockUnit, ...);
requiredAmount = requiredAmount.subtract(amountOnSourceStockUnit);
```

Even after fixing the comparisons (Fix 2), the transfer amount in this branch must also use available amount. Otherwise a stock unit with `amount=10, reservedamount=3` would attempt to transfer `10` instead of `7`.

**Fix:** When fixing Fix 2, also change line 640 to `stockUnit.getAvailableamount()` and use that for both the comparison and the transfer amount.

**Status:** Fixed in Phase 1. Variable renamed to `availableOnSource = stockUnit.getAvailableamount()` and used for both comparison and transfer amount in all three branches.

#### Finding B — Integer truncation in validation silently loses precision — IMPLEMENTED (Phase 1)

**Location:** `CustomerorderBatchService.java:492, 509, 511`

Both the required-amount calculation and available-amount summation use `.intValue()`:

```java
// Line 492
int requiredStock = orderPosition.getAmount().intValue() * parcels;
// Lines 509, 511
amount = stockUnit.getAmount().intValue();  // should be getAvailableamount()
```

If any order position or stock unit has a fractional quantity (e.g., `2.5`), `intValue()` silently truncates to `2`. This could cause validation to incorrectly pass or fail.

**Recommendation:** Use `BigDecimal` throughout the validation logic instead of `int`. This aligns with how `runClubLine()` already uses `BigDecimal` for `requiredAmount` at line 634. Low priority if all current SKUs are integer quantities, but a latent bug if fractional quantities are ever introduced.

**Status:** Fixed in Phase 1. Converted `requiredItemDataIntegerMap` and `availableItemDataIntegerMap` from `Map<Itemdata, Integer>` to `Map<Itemdata, BigDecimal>`. Uses `BigDecimal.multiply()` for required calculation and `BigDecimal::add` via `merge()` for available summation.

#### Finding C — `getAmountAvailable` query lacks ALL safety filters — IMPLEMENTED (Phase 3)

**Location:** `StockunitRepository.java:44-51`

The report correctly identified the missing `reservedamount` subtraction. Additionally, this query lacks **every** safety filter that other stock queries use. Compare:

| Filter | `getAmountAvailable` (line 44) | `getStockAndReservedForLocation` (line 53) |
|--------|-------------------------------|-------------------------------------------|
| `stockunit.entity_lock = 0` | Missing | Present |
| `unitload.entity_lock = 0` | Missing | Present |
| `location.entity_lock = 0` | Missing | Present |
| `location_area.entity_lock = 0` | Missing | Present (joins location_area) |
| Subtracts `reservedamount` | Missing | Returns both total and reserved |

This means the Club Line SKU Overview UI shows physically present quantity including locked and fully reserved stock — significantly overstating what is actually available.

**Fix:** Either replace `getAmountAvailable` to return `sum(amount - reservedamount)` with entity_lock filters, or reuse `getStockAndReservedForLocation` and compute availability in Java. The latter avoids duplicating filter logic.

**Status:** Fixed in Phase 3. Query changed to `sum(amount - reservedamount)` with `entity_lock = 0` filters on stockunit, unitload, and location, plus `amount > reservedamount` guard. Note: `location_area` join was not added — the query filters by specific `locationId` which is sufficient for the staging lane context. If broader area-level filtering is needed in future, the `location_area` join can be added.

#### Finding D — `transferStockToUnitLoad` availability check uses stale entity — IMPLEMENTED (Phase 4)

**Location:** `StockunitBusinessService.java:186-187, 294-301`

The availability guard at line 186 checks the **passed-in** `sourceStockunit` entity (which was read much earlier in `mapStockUnitsToItemData`). The actual amount mutation at lines 298-301 re-fetches with `findById()` — but this is a plain read, not `findByIdForUpdate()`.

This means:
1. The availability check (line 186) operates on a potentially stale snapshot
2. The re-fetch (line 299) gets a fresher snapshot but without a row lock
3. Between the re-fetch and the `save()` at line 301, another transaction can still modify the row

This is a stronger statement than the report's Fix 4. The TOCTOU window exists **within** `transferStockToUnitLoad` itself, not just between selection and transfer.

**Recommended hardening for Fix 4:** Add `findByIdForUpdate()` at the top of `transferStockToUnitLoad` to re-fetch and lock the source stock unit before the availability check. This single change closes both the selection-to-transfer gap and the internal check-to-mutate gap.

**Status:** Fixed in Phase 4. Added `findByIdForUpdate()` + `entityManager.refresh()` at method entry, following the same pattern as `changeReservedAmount`. The locked entity is used for both the availability check and all subsequent logic.

#### Finding E — External HTTP calls inside transaction boundary — NOT IMPLEMENTED (pre-existing)

**Location:** `CustomerorderBatchService.java:675-677` → `ManageOrderService.java:131-189, 254-308, 309-382`

`runClubLine()` calls three `manageOrderService` methods that make HTTP POST calls to OMS, all within the `@Transactional` boundary. If the subsequent state updates (lines 679-686) throw, the transaction rolls back all DB changes — but the HTTP messages to OMS cannot be rolled back.

Scenario: stock is transferred (DB), OMS is notified "orders picked" (HTTP), then the batch state update fails → DB rolls back, but OMS already believes orders are picked.

**Note:** The `ManageOrderService` methods catch all HTTP exceptions internally and log them as FAILED messages, so an OMS communication failure won't roll back the transaction. The risk is specifically the reverse direction: DB failure after successful OMS notification.

**Recommendation:** This is a pre-existing architectural concern, not caused by this bug. Flag for awareness but do not block the availability fix on this. A future improvement could move the HTTP notifications to an `@TransactionalEventListener(phase = AFTER_COMMIT)` so they only fire after the transaction succeeds.

**Status:** Not implemented. Pre-existing architectural concern, out of scope for this fix. Documented in the "Other horizontal scalability considerations" section for future planning.

#### Finding F — `customerOrderPicked` mutates DB inside a "messaging" method — NOT IMPLEMENTED (pre-existing)

**Location:** `ManageOrderService.java:339-341`

`customerOrderPicked()` saves `historytote` UUIDs to customer orders (`customerorderRepository.saveAll(clubOrdersToSave)`) before sending the HTTP message. This DB write is hidden inside what callers treat as a notification method. If the outer transaction rolls back, these tote UUIDs are lost, and the tote labels sent in the HTTP payload won't match anything in the DB.

**Recommendation:** Low priority. This is a pre-existing design concern, not introduced by the availability bug. Acknowledge but don't fix now.

**Status:** Not implemented. Pre-existing design concern, out of scope for this fix. Documented in the "Other horizontal scalability considerations" section for future planning.

### Prioritized implementation plan

#### Phase 1 — Fix the deterministic bug (Critical, fixes the reported incident)

**Files:** `CustomerorderBatchService.java`

1. **Fix `validateStockOnStagingLane`** (lines 504-513):
   - Change `stockUnit.getAmount().intValue()` → `stockUnit.getAvailableamount()` (use BigDecimal)
   - Skip stock units where `getAvailableamount().compareTo(BigDecimal.ZERO) <= 0`
   - Change `requiredItemDataIntegerMap` and `availableItemDataIntegerMap` to `Map<Itemdata, BigDecimal>`
   - Update the comparison at line 524 to use `BigDecimal.compareTo`

2. **Fix `runClubLine` stock selection** (lines 638-660):
   - Line 640: change `stockUnit.getAmount()` → `stockUnit.getAvailableamount()`
   - Line 642: change `stockUnit.getAmount().compareTo(requiredAmount)` → `stockUnit.getAvailableamount().compareTo(requiredAmount)`
   - Lines 643-658: use `availableAmount` variable for both comparison and transfer amount
   - Add a guard to skip stock units with `getAvailableamount() <= 0`

#### Phase 2 — Fix entity_lock filtering (High, prevents transfer failures on locked stock)

**Files:** `CustomerorderBatchService.java`, optionally `StockunitRepository.java`

3. **Filter locked entities in `mapStockUnitsToItemData`** (lines 537-558):
   - After bulk-fetching stock units at line 548, filter out stock units where `entityLock != 0`
   - Also need to check unitload locks and location locks — either:
     - (a) Add a new repository query that joins unitload/location and filters by `entity_lock = 0` on all three, OR
     - (b) Filter in Java by loading the unitload for each stock unit and checking locks (less efficient but simpler)
   - Option (a) is preferred — create a `findEligibleByUnitloadIdIn(Collection<Long> unitloadIds)` query

#### Phase 3 — Fix misleading UI reporting (Medium, prevents operator confusion)

**Files:** `StockunitRepository.java`, `CustomerorderBatchService.java`

4. **Fix `getAmountAvailable` query** (StockunitRepository lines 44-51):
   - Replace `sum(stockUnit.amount)` with `sum(stockUnit.amount - stockUnit.reservedamount)`
   - Add `entity_lock = 0` filters on stockunit, unitload, location
   - Add `location_area` join with `entity_lock = 0` filter
   - Or: replace the call in `getClubLineSKUOverview` (line 1055) with `getStockAndReservedForLocation` and compute available in Java

#### Phase 4 — Harden concurrency (Low priority for this incident, important for correctness)

**Files:** `StockunitBusinessService.java`

5. **Add pessimistic lock in `transferStockToUnitLoad`** (line 186):
   - Before the availability check, re-fetch with `findByIdForUpdate(sourceStockunit.getId())`
   - Use the locked entity for both the availability check and all subsequent logic
   - This pattern already exists in `changeReservedAmount` (line 395) — follow the same approach

### Items explicitly NOT in scope

- **Finding E** (HTTP in transaction): Pre-existing architectural concern. Documented for future improvement.
- **Finding F** (historytote mutation): Pre-existing design concern. Documented for future improvement.

### Additional findings implementation summary

| Finding | Description | Status |
|---------|------------|--------|
| A | Partial-transfer branch uses total amount | **Implemented** (Phase 1) |
| B | Integer truncation in validation | **Implemented** (Phase 1) |
| C | `getAmountAvailable` lacks all safety filters | **Implemented** (Phase 3) |
| D | `transferStockToUnitLoad` stale entity check | **Implemented** (Phase 4) |
| E | External HTTP calls inside transaction boundary | **Not implemented** — pre-existing, documented |
| F | `customerOrderPicked` mutates DB in messaging | **Not implemented** — pre-existing, documented |

### Suggested regression tests (updated)

1. Stock unit with `amount=2, reservedamount=2`, required `2` → validation should report insufficient stock
2. Stock unit with `amount=10, reservedamount=3`, required `7` → should succeed, transferring exactly `7`
3. Stock unit with `amount=10, reservedamount=3`, required `10` → should fail (only `7` available)
4. Mixed stock units: one fully reserved, one with availability → should skip reserved, transfer from available
5. Multiple stock units with partial reservations → should consume only available quantities across units
6. Locked stock unit (`entity_lock != 0`) → should be excluded from selection
7. Club Line SKU Overview → should not count reserved or locked stock as available
8. Partial-transfer branch: stock unit with `amount=5, reservedamount=2`, required `10` → should transfer `3` (not `5`) and continue to next stock unit

---

## Implementation status (2026-04-05)

| Phase | Description | Status | Files modified |
|-------|-------------|--------|----------------|
| Phase 1 | Fix availability logic in validation + selection | **Done** | `CustomerorderBatchService.java` |
| Phase 2 | Add entity_lock filtering to stock selection | **Done** | `StockunitRepository.java`, `CustomerorderBatchService.java` |
| Phase 3 | Fix misleading `getAmountAvailable` query | **Done** | `StockunitRepository.java` |
| Phase 4 | Add pessimistic lock in `transferStockToUnitLoad` | **Done** | `StockunitBusinessService.java` |
| Phase 5 | Batch-level lock for horizontal scalability | **Done** | `CustomerorderBatchRepository.java`, `CustomerorderBatchService.java` |
| Tests | Regression tests + existing test updates | **Done** | `CustomerorderBatchServiceUnitTest.java`, `StockunitBusinessServiceUnitTest.java` |

### Changes summary

**`CustomerorderBatchService.java`**
- `validateStockOnStagingLane()`: Changed from `int`/`getAmount()` to `BigDecimal`/`getAvailableamount()`. Skips stock units with available <= 0.
- `runClubLine()` stock selection loop: Uses `getAvailableamount()` for comparison and transfer amounts. Skips fully reserved stock units.
- `runClubLine()` entry: Added `findByIdForUpdate` on the batch row to prevent concurrent execution of the same batch across multiple API instances.
- `mapStockUnitsToItemData()`: Changed from `findByUnitloadIdIn` to `findEligibleByUnitloadIdIn` which filters by entity_lock and available amount at DB level.

**`CustomerorderBatchRepository.java`**
- Added `findByIdForUpdate()`: Pessimistic write lock query to serialize concurrent batch processing across horizontally scaled instances.

**`StockunitRepository.java`**
- `getAmountAvailable()`: Changed to `sum(amount - reservedamount)` with `entity_lock = 0` filters on stockunit, unitload, and location. Excludes fully reserved stock.
- Added `findEligibleByUnitloadIdIn()`: New native query that filters by `entity_lock = 0` on stockunit, unitload, location, and `amount > reservedamount`.

**`StockunitBusinessService.java`**
- `transferStockToUnitLoad()`: Added `findByIdForUpdate` + `entityManager.refresh` at method entry (same pattern as `changeReservedAmount`) to prevent TOCTOU races.

### Test results

- All 120 tests in `CustomerorderBatchServiceUnitTest` and `StockunitBusinessServiceUnitTest` pass (0 failures, 0 errors).
- 6 new regression tests added covering reserved stock scenarios and concurrent batch processing.
- 5 pre-existing unnecessary stubbing errors in `StockunitBusinessServiceUnitTest` fixed as part of test updates.
- Full unit test suite: zero new failures introduced. All pre-existing failures (`SequenceTransactionServiceUnitTest`) are unrelated.

### Horizontal scalability analysis

All fixes use **database-level locking** (`SELECT ... FOR UPDATE`), not JVM-level locks. This means they work correctly across multiple API instances sharing the same PostgreSQL database.

| Concern | Mitigation |
|---------|------------|
| Two instances run `runClubLine` on the same batch | Phase 5: Batch row locked with `FOR UPDATE`. Second instance blocks, then fails at state check. |
| Two instances reserve the same stock unit | Phase 4: `transferStockToUnitLoad` locks the stock unit row before availability check. |
| Stale stock reads during batch validation | Phase 2: `findEligibleByUnitloadIdIn` filters at DB level. Phase 4 lock catches any remaining staleness at transfer time. |
| `@Version` (optimistic lock) on all entities | Pre-existing. Provides last-line defense against concurrent updates at commit time. |

### Other horizontal scalability considerations

The following items were identified during analysis. They are **not** caused by the availability bug and are pre-existing architectural concerns. Listed here for awareness and future planning.

#### 1. External HTTP messages inside transaction boundary — Not implemented (pre-existing)

**Risk:** `runClubLine()` sends three HTTP POST calls to OMS (`customerOrderReleaseForPicking`, `customerOrderPickingStarted`, `customerOrderPicked`) inside the `@Transactional` boundary. If the DB state update after these calls fails, the transaction rolls back but OMS has already received the messages.

**Impact in multi-instance:** Two instances processing *different* batches simultaneously could interleave OMS messages. OMS must handle this correctly (idempotency).

**Recommended future fix:** Move HTTP notifications to `@TransactionalEventListener(phase = AFTER_COMMIT)` so they only fire after the transaction commits successfully.

**Status:** Not implemented. Pre-existing architectural concern. Low risk for the current incident scope.

#### 2. Long-running transaction in `runClubLine` — Not implemented (pre-existing)

**Risk:** `runClubLine` holds a single transaction for the entire batch — creating unit loads, transferring stock for ALL orders, sending HTTP messages, updating states. With many orders, this transaction can run for seconds or longer.

**Impact in multi-instance:** Long transactions hold row locks (`FOR UPDATE`) for extended periods, increasing lock contention and connection pool pressure. Under high concurrency, this can cause lock wait timeouts or connection pool exhaustion.

**Recommended future fix:** Consider breaking `runClubLine` into smaller transactions — e.g., one transaction per order — with a batch-level coordination mechanism (state machine with per-order tracking). This is a significant refactor.

**Status:** Not implemented. Acceptable for current batch sizes. Monitor under load.

#### 3. `historytote` UUID generation in messaging method — Not implemented (pre-existing)

**Risk:** `ManageOrderService.customerOrderPicked()` generates tote UUIDs and saves them to customer orders *before* sending the HTTP message. If the outer transaction rolls back, the UUIDs are lost, but the OMS may have already received them in the HTTP payload.

**Impact in multi-instance:** No additional multi-instance risk beyond the single-instance concern.

**Recommended future fix:** Move tote UUID assignment to `runClubLine` itself (before the messaging calls) to make the data flow explicit.

**Status:** Not implemented. Low priority. Pre-existing design concern.

#### 4. `nirvanaUnitload` singleton cache in `StockunitBusinessService` — No fix needed

**Risk:** The `nirvanaUnitload` field and `initialized` boolean are instance-level state on a Spring singleton bean.

**Analysis:** Each JVM instance caches its own copy of the same immutable DB row. The `@PostConstruct` / `ensureInitialized()` pattern is safe because the Nirvana unit load row never changes. No multi-instance concern.

**Status:** No fix needed. Safe as-is.

#### 5. `TenantContext` (ThreadLocal) — No fix needed

**Risk:** Thread-local storage is JVM-specific.

**Analysis:** `TenantContext` is set per-request from HTTP headers (`TenantFilter`). Each request carries its own tenant context regardless of which instance handles it. No cross-instance state sharing needed.

**Status:** No fix needed. Safe as-is.

### Scope note

This document is analysis and implementation. Code changes were applied as part of this work.