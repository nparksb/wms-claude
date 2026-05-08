# Receiving Quantities Not Updating — Root Cause Analysis & Fix Plan

**Date:** 2026-02-23
**Branch:** `v2-tmp/np51-receiving-formance`
**Related:** `docs/plan/260424-RECEIVING_PERFORMANCE_PLAN.md` (Phases 1–4 complete)

### Status

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 1 | Enable Error Visibility | **COMPLETE** |
| Phase 2 | Fix the Underlying Exception | **COMPLETE** |
| Phase 3 | Hardening | **COMPLETE** |

**Commits:**
- `704b7d7` (wms-api) — Phase 1: `catch (RuntimeException e)` in `ReceivingController.receive()` + this plan doc
- `7220d0b` (wms-web-ui) — Phase 1: uncommented error toast in `receiveInboundItems` catch block
- `07099b9` (wms-api) — Phase 2: convert RuntimeExceptions to checked exceptions in `receiveGoods()`
- `d44ac7d` (wms-api) — Phase 3: RuntimeException catch on all endpoints, move orElseThrow inside try blocks
- `c650928` (wms-web-ui) — Phase 3: uncomment all error toasts in receiving store actions
- `3e6c889` (wms-api) — Phase 2 addendum: add `tenantTransactionManager` to all `@Transactional` in ReceivingService
- `9ff08be` (wms-api) — Bonus fix: `AdviceService.close()` — `SimpleDateFormat` → `DateTimeFormatter` for `LocalDate` fields (Hibernate 6 type change)

---

## 1. Symptom

After clicking "Receive Inventory" on the Inventory Receiving screen:
- The **Received** and **Remaining** values in the Quantities section do not update
- After returning to the Inbound Notice detail page, the **Qty Received** column in the positions table also does not update
- The user sees no error message

## 2. How The Flow Works

```
 ┌─ FRONTEND ──────────────────────────────────────────────────────────┐
 │                                                                     │
 │  1. User clicks "Receive Inventory"                                 │
 │     └─ POST /v3/receiving/receive  { advicePositionId, qty, ... }   │
 │                                                                     │
 │  2. On response, clears form fields                                 │
 │                                                                     │
 │  3. Calls updateQuantities()                                        │
 │     └─ GET /v3/receivingDtoView/search/findByAdvicepositionid       │
 │        (queries receiving_dto_view — a live PostgreSQL view          │
 │         that SUMs goodsreceiptposition.amount per advice position)   │
 │                                                                     │
 │  4. Vue watcher updates displayed Received / Remaining              │
 └─────────────────────────────────────────────────────────────────────┘
```

**Key files:**

| Layer | File | Purpose |
|---|---|---|
| Frontend page | `wms-web-ui/components/receiving/open/receive/receivingForm.vue` | "Receive Inventory" button, Quantities display |
| Frontend store | `wms-web-ui/store/receiving/receive.js` | `receiveInboundItems` Vuex action |
| Controller | `ReceivingController.java` | `POST /v3/receiving/receive` endpoint |
| Service | `ReceivingService.java` | `receiveGoods()` — core receiving logic |
| DB view | `receiving_dto_view` (in `V1.1.01__wms_views.sql`) | Aggregates GRP amounts per advice position |
| View entity | `ReceivingDtoView.java` | JPA entity mapped to `receiving_dto_view` |
| View repo | `ReceivingDtoViewRepository.java` | `findByAdvicepositionid()` Spring Data REST endpoint |

## 3. Root Cause: Silent Exception Swallowing

The quantities don't update because `receiveGoods()` is **throwing an exception that rolls back the transaction**, but **the error is invisible to the user** due to two gaps in error handling — one backend, one frontend.

### 3.1 Backend Gap — Controller Only Catches Two Exception Types

**File:** `ReceivingController.java:231–237`

```java
try {
    receivingService.receiveGoods(advicePositionId, ...);
} catch (BusinessException e) {
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
} catch (FacadeException e) {
    errors.add(getErrorMessage("Runtime Error", e.getLocalizedMessage()));
}
```

The controller **only** catches `BusinessException` and `FacadeException`. Any other exception type — including `RuntimeException` and its subclasses — propagates uncaught to Spring's exception handling framework.

The optimization work introduced several `.orElseThrow(() -> new EntityNotFoundException(...))` calls in the receiving path. `EntityNotFoundException` extends `RuntimeException`:

```java
// EntityNotFoundException.java
public class EntityNotFoundException extends RuntimeException { ... }
```

A global `@ControllerAdvice` handler catches it and returns **HTTP 404**:

```java
// RestExceptionHandler.java:115-121
@ExceptionHandler(EntityNotFoundException.class)
protected ResponseEntity<ProblemDetail> handleEntityNotFound(EntityNotFoundException ex) {
    ProblemDetail problemDetail = ProblemDetail.forStatusAndDetail(
        HttpStatus.NOT_FOUND, ex.getMessage());
    return ResponseEntity.status(HttpStatus.NOT_FOUND).body(problemDetail);
}
```

Because `EntityNotFoundException` is a `RuntimeException`, the `@Transactional` on `receiveGoods()` **automatically rolls back** before the exception handler runs. The `goodsreceiptposition` records are never committed.

### 3.2 Frontend Gap — Error Toast Commented Out

**File:** `wms-web-ui/store/receiving/receive.js:77–91`

```javascript
async receiveInboundItems(context, data) {
  try {
    const results = await this.$axios.$post('/receiving/receive', data)
    if (results.errors) {
      this.$toast.error(results.errors[0].message)    // ← shown for BusinessException
    } else {
      this.$toast.success('Inventory received')
    }
    ...
  } catch (error) {
    console.log(error);                                // ← only logged to console
    // this.$toast.error('Error: ' + error)            // ← COMMENTED OUT!
  }
},
```

When `receiveGoods()` throws a `RuntimeException`:
1. Spring returns HTTP 404 (via `RestExceptionHandler`)
2. Axios throws (non-2xx status code)
3. The `catch(error)` block runs — but the toast is **commented out**
4. The error is silently written to `console.log` only
5. The user sees **nothing**

### 3.3 The Chain

```
receiveGoods() throws EntityNotFoundException (or other RuntimeException)
    ↓
@Transactional rolls back automatically (unchecked exception)
    ↓ No goodsreceiptposition records persisted
Controller does NOT catch RuntimeException
    ↓
RestExceptionHandler returns HTTP 404
    ↓
Frontend axios throws (non-2xx)
    ↓
catch(error) { console.log(error) }  ← TOAST COMMENTED OUT
    ↓
User sees nothing. receive() continues to updateQuantities()
    ↓
updateQuantities() queries view → returns old data (transaction was rolled back)
    ↓
Quantities don't change
```

## 4. Identifying the Specific Exception

Without server logs, the exact exception cannot be determined definitively. The most likely candidates, ranked by probability:

### 4.1 Most Likely: `EntityNotFoundException` from New Pre-Fetch Code

The optimization added new `orElseThrow()` calls in `receiveGoods()`:

```java
// Line 474-475 — Spawn location
Location spawnLocation = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_SPAWN)
    .orElseThrow(() -> new EntityNotFoundException(...));

// Line 477-478 — Putaway location (only when carrier == null)
Location putAwayLocation = (carrier == null)
    ? locationRepository.findById(itemdata.getPutawaylocationId())
        .orElseThrow(() -> new EntityNotFoundException(...))
    : null;

// Line 480 — Unitload type name (returns null if not found, no exception)
String unitloadTypeName = unitloadTypeRepository.findNameById(unitloadType.getId());
```

**However**, the spawn location lookup also existed in the original `UnitloadService.createUnitload()` and would have failed before the optimization too. So this is less likely unless the `Spawn` location was recently deleted or the database changed.

### 4.2 Possible: `ObjectOptimisticLockingFailureException` from Version Conflict

All entities extend `AbstractBaseEntity` which has `@Version private Integer version;`. The optimization changed the unitload save pattern:

**Old code (2 saves per loop iteration):**
```java
Unitload unitload = unitloadService.createUnitload(...);  // save #1 → version 1
unitload.setBoxtypeId(boxType.getId());
unitloadRepository.save(unitload);                         // save #2 → version 2
```

**New code (1 save):**
```java
Unitload unitload = unitloadService.createUnitload(..., boxtypeId);  // save #1 → version 1
// No second save — boxtypeId already set
```

Later, `transferUnitLoadToCarrier()` re-fetches and saves the unitload:
```java
Unitload unitload = unitloadRepository.findById(staleUnitload.getId())...;
unitload.setCarrierunitloadId(destinationUnitload.getId());
unitload = unitloadRepository.save(unitload);  // version 1→2 (new code) or 2→3 (old code)
```

Then `processTransfer()` re-fetches and saves AGAIN:
```java
Unitload unitload = unitloadRepository.findById(staleUnitload.getId())...;
unitload.setStoragelocationId(destinationLocation.getId());
unitload = unitloadRepository.save(unitload);
```

If any of these re-fetches gets a stale version (due to Hibernate first-level cache not being refreshed after `processTransfer`'s recursive child processing), an `ObjectOptimisticLockingFailureException` could be thrown. This is a `RuntimeException` and would NOT be caught by the controller.

### 4.3 Possible: `PessimisticLockException` from Lock Timeout

The new pessimistic lock `findByIdForUpdate()` could timeout if another transaction holds a lock on the same advice position row. This extends `PersistenceException` (a `RuntimeException`). Unlikely in single-user testing, but possible if a background job or previous failed transaction is involved.

### 4.4 Possible: `DataIntegrityViolationException` from Duplicate GRP Number

The counter-based numbering `generateNumberWithGoodsReceiptByCount()` starts counting from `countByGoodsreceiptId()`. If this count is incorrect (e.g., due to concurrent inserts or a stale count), it could generate a duplicate GRP number. If `goodsreceiptposition.number` has a unique constraint in the database (not visible in the JPA entity), this would throw `DataIntegrityViolationException` (a `RuntimeException`).

## 5. Fix Plan

### Phase 1: Enable Error Visibility ✅ COMPLETE

**Goal:** See the actual error before fixing it.

#### 1.1 Uncomment Frontend Error Toast

**File:** `wms-web-ui/store/receiving/receive.js:88`

```javascript
// BEFORE:
catch (error) {
    console.log(error);
    // this.$toast.error('Error: ' + error)
}

// AFTER:
catch (error) {
    console.log(error);
    this.$toast.error('Error: ' + (error.response?.data?.detail || error.message || error))
}
```

This shows the `ProblemDetail.detail` field from the backend's `EntityNotFoundException` handler, or falls back to the generic error message.

#### 1.2 Add RuntimeException Catch in Controller

**File:** `ReceivingController.java:231–237`

```java
// BEFORE:
try {
    receivingService.receiveGoods(advicePositionId, ...);
} catch (BusinessException e) {
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
} catch (FacadeException e) {
    errors.add(getErrorMessage("Runtime Error", e.getLocalizedMessage()));
}

// AFTER:
try {
    receivingService.receiveGoods(advicePositionId, ...);
} catch (BusinessException e) {
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
} catch (FacadeException e) {
    errors.add(getErrorMessage("Runtime Error", e.getLocalizedMessage()));
} catch (RuntimeException e) {
    LOG.error("Unexpected error during receive: {}", e.getMessage(), e);
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
}
```

This ensures ALL exceptions from `receiveGoods()` are caught and returned in the standard `{ errors: [...] }` response format that the frontend already handles (shows error toast).

**Important:** The `@Transactional` on `receiveGoods()` still rolls back for `RuntimeException`, so this doesn't change data integrity — it only makes the error visible to the user.

#### 1.3 Reproduce and Read the Error

After applying 1.1 and 1.2, reproduce the issue:
1. Navigate to the Inventory Receiving screen
2. Select a parent container, enter quantity, click "Receive Inventory"
3. **Read the error toast** — it will tell you exactly which entity is not found (or which exception occurred)
4. Also check the server logs for the `LOG.error` from step 1.2

### Phase 2: Fix the Underlying Exception ✅ COMPLETE

**Fixed:** Converted all 6 RuntimeException sources in `receiveGoods()` to checked exceptions (`BusinessException`/`FacadeException`) so they are properly caught by the controller and returned to the frontend:

1. `storageLocationOptional.get()` (line 406) — added `.isPresent()` check + `BusinessException`
2. `locationRepository.findById(carrierStorageLocationId).orElseThrow(EntityNotFoundException)` (line 418) — changed to `BusinessException`
3. `unitloadTypeOptional.get()` (line 424) — added `.isPresent()` check + `BusinessException`
4. `locationRepository.findByName(SPAWN).orElseThrow(EntityNotFoundException)` (line 474) — changed to `BusinessException`
5. `locationRepository.findById(putawaylocationId).orElseThrow(EntityNotFoundException)` (line 477) — changed to `BusinessException`
6. `throw new RuntimeException("adding to byte stream failed")` (line 521) — changed to `FacadeException`

**Below are the original scenario descriptions for reference:**

#### 2.1 If `EntityNotFoundException` — Missing Entity

Check that all required entities exist in the database:
- `Spawn` location (`locationRepository.findByName("Spawn")`)
- Putaway location for the item (`itemdata.putawaylocationId`)
- Unitload type for the advice position
- The advice position itself

If an entity is missing, create it or fix the reference.

If the entity EXISTS but the query isn't finding it (e.g., tenant-specific data isolation), verify that the query runs within the correct tenant context.

#### 2.2 If `ObjectOptimisticLockingFailureException` — Version Conflict

Add retry logic similar to what exists in `StockunitBusinessService.changeReservedAmount()`:

```java
// In the loop body, wrap the transfer call with retry
try {
    unitloadBusinessService.transferUnitLoadToCarrier(unitload, carrier, ...);
} catch (ObjectOptimisticLockingFailureException e) {
    LOG.warn("Optimistic lock conflict on unitload transfer, retrying...");
    // Re-fetch and retry
    unitload = unitloadRepository.findById(unitload.getId()).orElseThrow(...);
    unitloadBusinessService.transferUnitLoadToCarrier(unitload, carrier, ...);
}
```

Or, more robustly, use the existing `OptimisticLockRetry` utility.

#### 2.3 If `PessimisticLockException` — Lock Timeout

Add a lock timeout to prevent indefinite waits:

```java
// AdvicepositionRepository.java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "5000"))
@Query("SELECT ap FROM Adviceposition ap WHERE ap.id = :id")
Optional<Adviceposition> findByIdForUpdate(@Param("id") Long id);
```

And catch the timeout in the controller or service:
```java
catch (PessimisticLockException | LockTimeoutException e) {
    throw new BusinessException("Advice position is currently being received by another user. Please try again.");
}
```

#### 2.4 If `DataIntegrityViolationException` — Duplicate GRP Number

The counter-based numbering should be robust. If duplicates occur, either:
- Add a unique suffix (timestamp or random) to the GRP number
- Use the old `generateNumberWithGoodsReceipt()` method as fallback

### Phase 3: Hardening ✅ COMPLETE

#### 3.1 Uncomment ALL Silent Error Toasts

Several Vuex actions in `store/receiving/receive.js` have commented-out error toasts:
- `getPalletsForReceiving` (line 41)
- `createPallet` (line 58)
- `updatePallet` (line 73)
- `receiveInboundItems` (line 89)

Uncomment all of them to prevent future silent failures.

#### 3.2 Add Consistent RuntimeException Handling to Other Receiving Endpoints

Apply the same `catch (RuntimeException e)` pattern to:
- `setPallet()` (line 60-93)
- `createAndSelectPallet()` (line 96-133)
- `createPallet()` (line 138-161)
- `unlinkSelectedPallet()` (line 164-185)
- `updatePallet()` (line 187-212)

---

## 6. Verification Steps

After applying the fix:

1. **Reproduce the original scenario:** Select parent container, enter qty 12, click Receive Inventory
2. **Verify:** "Inventory received" success toast appears (not an error)
3. **Verify:** Received and Remaining values update in the Quantities section
4. **Enter qty 6, receive again**
5. **Verify:** Quantities update again (cumulative)
6. **Click "Return to Inbound Notice"**
7. **Verify:** Qty Received column shows the total received amount (18)
8. **Check database:** `SELECT * FROM goodsreceiptposition WHERE adviceposition_id = ?` should show records with correct amounts

---

## 7. Summary

| Issue | Description |
|---|---|
| **Root cause** | `receiveGoods()` throws an uncaught `RuntimeException`, rolling back the transaction |
| **Why invisible** | Controller doesn't catch `RuntimeException`; frontend error toast is commented out |
| **Data impact** | No data corruption — transaction rolls back cleanly. GRP records are simply never created. |
| **Fix priority** | Phase 1 (error visibility) is critical — apply immediately to see the actual error |
| **Risk** | Low — Phase 1 changes are purely diagnostic. Phase 2 fix depends on what the error reveals. |
