# Connection Pool Exhaustion — Fix Plan

**Date:** 2026-03-04  
**Problem:** HikariCP pool maxes out at 25 connections, all requests timeout after 30s  
**Root cause:** Recent concurrency fixes (Feb 2026) introduced pessimistic locks and `@Transactional` boundaries that hold DB connections while making blocking HTTP calls to OMS  

---

## Phase 0: Merge existing fix branch (data integrity)

**Branch:** `fix/transactional-rollback-checked-exceptions`  
**Risk:** Low — additive only, no behavioral change to happy path  

Merge as-is. Adds `rollbackFor = {BusinessException.class, FacadeException.class}` to all 25 `@Transactional` annotations. This doesn't fix connection exhaustion but prevents silent partial commits on checked exceptions (the WineCo tote T-0135 incident).

This fix is a prerequisite — the changes below build on top of it.

---

## Phase 1: Move OMS HTTP calls outside transaction boundaries

**Impact:** High — this is the primary cause of pool exhaustion  
**Risk:** Low — OMS callbacks are best-effort notifications, not part of the business transaction  

### Problem

`MobilePickingService.processPick()` and `PickingorderBusinessService.confirmPick()` make HTTP calls to OMS **inside** `@Transactional` methods. Each HTTP call can block up to 20s (5s connect + 15s read timeout), holding a DB connection the entire time.

### Files changed

| File | Method | Change |
|------|--------|--------|
| `MobilePickingService.java` | `processPick()` | Extract OMS tote-assigned callback to run after transaction commits |
| `PickingorderBusinessService.java` | `confirmPick()` | Extract OMS picking-started callback to run after transaction commits |

### Approach

Create a lightweight helper that collects OMS notifications during the transaction and fires them after commit using Spring's `TransactionSynchronizationManager.registerSynchronization()`. This keeps the OMS calls best-effort and non-blocking to the DB connection.

```java
// After the @Transactional method returns and the transaction commits:
TransactionSynchronizationManager.registerSynchronization(
    new TransactionSynchronization() {
        @Override
        public void afterCommit() {
            try {
                manageOrderService.customerOrderToteAssigned(...);
            } catch (Exception e) {
                LOG.error("OMS callback failed, continuing", e);
            }
        }
    }
);
```

The OMS calls are already wrapped in try-catch (line 412 of MobilePickingService), confirming they're best-effort. Moving them post-commit is safe.

---

## Phase 2: Narrow pessimistic lock scope on `changeReservedAmount`

**Impact:** Medium — prevents lock contention from cascading into connection pileup  
**Risk:** Medium — changes transaction propagation; needs careful testing  

### Problem

`StockunitBusinessService.changeReservedAmount()` uses `SELECT FOR UPDATE` (pessimistic lock). When called from inside `confirmPick()`, the lock is held for the entire outer transaction — including all the subsequent repository calls and (pre-Phase-1) the HTTP calls. Concurrent picks targeting the same stock unit queue up, each holding a connection while waiting for the lock.

### Files changed

| File | Method | Change |
|------|--------|--------|
| `StockunitBusinessService.java` | `changeReservedAmount()` | Change propagation to `REQUIRES_NEW` |

### Approach

```java
// Before:
@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
public Stockunit changeReservedAmount(...)

// After:
@Transactional(propagation = Propagation.REQUIRES_NEW,
               rollbackFor = {BusinessException.class, FacadeException.class})
public Stockunit changeReservedAmount(...)
```

This opens a **separate short-lived transaction** just for the lock-acquire → update → commit cycle. The pessimistic lock is held for milliseconds instead of seconds. The outer transaction continues with the updated (committed) reserved amount.

**Trade-off:** If the outer transaction fails after `changeReservedAmount` succeeds, the reserved amount change is NOT rolled back (it was committed independently). This is acceptable because:
- The existing code already had this exact same behavior before the `@Transactional` additions in commit `cfc3ae2` — each `save()` auto-committed independently
- A stuck reservation is recoverable (admin can adjust); a stuck connection pool takes down the entire warehouse

---

## Phase 3: HikariCP configuration tuning

**Impact:** Low — provides breathing room and diagnostic visibility  
**Risk:** Low — configuration only  

### File changed: `application.properties`

```properties
## DB connection pool
spring.datasource.hikari.connectionTimeout=30000
spring.datasource.hikari.maximumPoolSize=15
spring.datasource.hikari.minimumIdle=5
spring.datasource.hikari.leak-detection-threshold=30000
spring.datasource.hikari.max-lifetime=1800000
spring.datasource.hikari.idle-timeout=600000
spring.datasource.hikari.validation-timeout=5000
```

| Setting | Value | Rationale |
|---------|-------|-----------|
| `maximumPoolSize` | 15 | After Phases 1-2, connections are held for ms not seconds. 15 is more than enough. Going higher masks problems. |
| `minimumIdle` | 5 | Keep 5 warm connections ready; let the pool shrink during idle periods |
| `leak-detection-threshold` | 30000 | Log a warning + stack trace if any connection is held >30s. This is the early warning system. |
| `max-lifetime` | 1800000 | 30min (HikariCP default). No reason to retire connections faster. |
| `idle-timeout` | 600000 | 10min idle timeout before excess connections (above minimumIdle) are retired |
| `keepalive-time` | *(removed)* | Not supported in HikariCP 3.4.5 — silently ignored |

---

## Implementation order

```
1. Merge Phase 0 branch (fix/transactional-rollback-checked-exceptions)
2. Apply Phase 1 (move HTTP calls out of transactions)     ← biggest impact
3. Apply Phase 2 (narrow pessimistic lock scope)
4. Apply Phase 3 (HikariCP config)
5. Deploy and monitor leak-detection logs
```

Phases 1 + 2 can be implemented together in one PR. Phase 3 is a properties-only change that can go with them or separately.

---

## Out of scope (V2 only)

The transaction manager mismatch (`@Transactional` defaulting to landlord instead of tenant) is a real bug but only affects the V2 multi-tenant deployment. The fix exists on branch `v2/bug/SBDEV-1961-fix-transaction-manager-mismatch`. It should be merged into V2 but is not needed for V1 single-tenant deployments.

---

## How to verify the fix

1. **Leak detection logs** — After deploying, any connection held >30s will produce a log like:
   ```
   WARN  com.zaxxer.hikari.pool.ProtoConnection - Connection leak detection triggered for connection
   ```
   followed by the stack trace of the borrowing thread. Zero of these = success.

2. **HikariCP metrics** — Monitor `hikaricp.connections.active` (should stay well below 15 during peak picking) and `hikaricp.connections.pending` (should be 0).

3. **Load test** — Simulate 10+ concurrent pick operations against shared stock units. Before the fix, this exhausts the pool in seconds. After, it should complete without connection timeouts.

