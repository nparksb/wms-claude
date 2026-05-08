# V1 Migration: Remove nullable amount from getIdsToCancelReplenishOrders

**V1 Commits:** `198c86a` (merge), `b04066c` (fix)
**V1 Branch:** `release-260327`
**V2 Branch:** `tmp/np106-v1-fixes-migration`

## Background

In V1, the `getIdsToCancelReplenishOrders` query accepted a nullable `BigDecimal amount` parameter and used `COALESCE(:amount, fixAssignment.upperbound)` to fall back to the fix assignment's upper bound when null. The only caller (`ReplenishOrderJob`) always passed `null`, which caused Hibernate to bind it as `bytea` — a type PostgreSQL cannot use in `COALESCE` with a numeric column. The fix removed the nullable parameter entirely and hardcoded `fixAssignment.upperbound`.

## Analysis: V2 Current State vs V1 Fix

### 1. `ReplenishorderRepository.getIdsToCancelReplenishOrders` — NEEDS MIGRATION

**V2 current** (`ReplenishorderRepository.java:128-134`):
```java
@Query(value = "SELECT DISTINCT replenishOrder.id FROM replenishOrder, fix_location_assignment fixAssignment, stockUnit " +
    "WHERE fixAssignment.assignedunitload_id = stockUnit.unitload_id " +
    "AND replenishOrder.itemdata_id = fixAssignment.itemdata_id " +
    "AND replenishOrder.state <= :state " +
    "AND stockUnit.amount >= :amount", nativeQuery = true)
List<Long> getIdsToCancelReplenishOrders(@Param("state") int state, @Param("amount") BigDecimal amount);
```

**V1 after fix** (`b04066c`):
```java
"AND stockUnit.amount >= fixAssignment.upperbound"
List<Long> getIdsToCancelReplenishOrders(@Param("state") int state);
```

**Problem in V2:** The V2 caller passes the system property value (not null), so it doesn't hit the exact same `bytea` bug. However, the V1 fix represents a deliberate design decision: each fix assignment should use **its own** `upperbound` rather than a global system default. This is the correct business logic — different SKUs/locations can have different upper bounds.

### 2. `ReplenishOrderJob.cancelReplenishmentIfFlowbinIsFull` — NEEDS MIGRATION

**V2 current** (`ReplenishOrderJob.java:267`):
```java
List<Long> resultList = replenishorderRepository.getIdsToCancelReplenishOrders(WmsConstants.State.PROCESSABLE,
        BigDecimal.valueOf(Integer.parseInt(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY))));
```

**V1 after fix:**
```java
List<Long> resultList = replenishorderRepository.getIdsToCancelReplenishOrders(WmsConstants.State.PROCESSABLE);
```

### 3. Other changes in merge commit `198c86a` — ALREADY MIGRATED

The following changes from the merge commit are **already present in V2** and do NOT need migration:

| Change | V2 Status | Notes |
|--------|-----------|-------|
| `CustomerorderPositionService.getSectionForOrder()` helper | Already exists at line 150 | Identical implementation |
| `CustomerorderPositionService.canOrderPositionBeCancelled()` null-safe section handling | Already implemented | V2 has early return for empty `poPositions` and null-safe section logging |
| `CustomerorderService.getSectionForOrder()` helper | Different approach (inline) | V2 uses inline null-safe lookups in `cancelOrder` (lines 617-622) — functionally equivalent |
| `CustomerorderService.cancelOrder()` rapid picking guard reorder | Already implemented | V2 checks `ASSIGNED` state + `historytote` before section lookup |
| `CustomerorderService.packageOrder()` null-safe section lookup | Already implemented | V2 throws `BusinessException` when section is null (lines 511-517) |
| `StockunitBusinessService.entityManager.refresh()` | Already exists at line 398 | Identical fix |

## Implementation Plan

### Step 1: Update `ReplenishorderRepository.java`

**File:** `src/main/java/net/aim_ai/wms/repo/jpa/ReplenishorderRepository.java`
**Lines:** 128-134

Remove the `:amount` parameter and use `fixAssignment.upperbound` directly:

```java
// BEFORE
"AND stockUnit.amount >= :amount", nativeQuery = true)
List<Long> getIdsToCancelReplenishOrders(@Param("state") int state, @Param("amount") BigDecimal amount);

// AFTER
"AND stockUnit.amount >= fixAssignment.upperbound", nativeQuery = true)
List<Long> getIdsToCancelReplenishOrders(@Param("state") int state);
```

### Step 2: Update `ReplenishOrderJob.java`

**File:** `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java`
**Lines:** 267-268

Remove the amount argument from the caller:

```java
// BEFORE
List<Long> resultList = replenishorderRepository.getIdsToCancelReplenishOrders(WmsConstants.State.PROCESSABLE,
        BigDecimal.valueOf(Integer.parseInt(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND_KEY))));

// AFTER
List<Long> resultList = replenishorderRepository.getIdsToCancelReplenishOrders(WmsConstants.State.PROCESSABLE);
```

### Step 3: Update or create test cases

**File:** `src/test/java/net/aim_ai/wms/unit/schedulejob/ReplenishOrderJobTest.java`

Verify the existing test mocks `getIdsToCancelReplenishOrders` — update the mock call to remove the `amount` parameter.

**File:** `src/test/java/net/aim_ai/wms/unit/service/job/ReplenishOrderJobServiceUnitTest.java`

Check if there are tests covering `cancelReplenishmentIfFlowbinIsFull` and update accordingly.

### Step 4: Verify no other callers

Search for all usages of `getIdsToCancelReplenishOrders` in the codebase to ensure no other caller passes an `amount` argument.

## Risk Assessment

- **Low risk.** The query change is functionally an improvement — using per-assignment upper bounds instead of a global default is more correct.
- V2 currently passes the global system property value, which works but applies the same threshold to all fix assignments regardless of their individual configuration.
- No database migration needed — this is a query-only change.

## Verification

1. Build compiles: `mvn clean package -DskipTests`
2. Affected tests pass: `mvn test -Dtest="ReplenishOrderJobTest,ReplenishOrderJobServiceUnitTest"`
3. Full test suite passes: `mvn test`

## Implementation Status: COMPLETED (2026-04-02)

All steps implemented and verified:

- **Step 1** Done — `ReplenishorderRepository.java:133` now uses `fixAssignment.upperbound` instead of `:amount` param
- **Step 2** Done — `ReplenishOrderJob.java:266` caller simplified to single `state` arg
- **Step 3** Done — Updated 3 locations in `ReplenishOrderJobTest.java`:
  - `shouldCancelReplenishmentWhenFlowbinIsFull` — removed sysprop mock and amount arg
  - `shouldUseCorrectUpperBoundValue` → renamed to `shouldUsePerAssignmentUpperBound` — verifies only state param
  - `setupEmptyRepositoryResponses` — updated mock signature
- **Step 4** Done — Grep confirmed no other callers of `getIdsToCancelReplenishOrders`

**Test results:**
- `ReplenishOrderJobTest`: 39/39 passed
- `ViewDtoServiceUnitTest`: 73/73 passed (includes prior commit's tests)
- Full suite: 10 failures + 56 errors are **pre-existing** (unrelated schedulejob tests: `OrderReleaseJobUnitTest`, `ReleaseExpiredPickingOrdersFromUserJobUnitTest`, `StockSummaryExportJobUnitTest`, `CleanUpOldMessagesJobUnitTest`). Confirmed by running same tests on clean `git stash` state — identical failures.
