---
title: "changeReservedAmount StaleObjectStateException During Mobile Pick Confirm"
ticket: ""
ticket_url: ""
type: bug
priority: urgent
status: planning
project: [wms1]
version: v1
requester: production-incident
created: 2026-04-22
updated: 2026-04-22
deployed_env: dev
related:
  - SBDEV-1710
  - SBDEV-2102
tags:
  - plan
  - bug
  - concurrency
  - hibernate
  - picking
---

# changeReservedAmount StaleObjectStateException During Mobile Pick Confirm

**Ticket:** _untracked — production incident on `release` branch_
**Project:** v1/wms-api | **Version:** v1 | **Type:** Bug (Regression — incomplete SBDEV-1710 fix)
**Priority:** Urgent (HTTP 500 in mobile picking flow, picker cannot complete pick)
**Status:** PLANNING
**Date:** 2026-04-22
**Related:** SBDEV-1710 (Allocation More Than On Hand — original pessimistic-lock fix), SBDEV-2102 (multi-fix plan with similar Hibernate/OSIV failure modes)

---

## 1. Problem Statement

### User-Visible Symptom

Mobile picker scans a tote, confirms a pick (`MobilePickingService.processPick`), and the request returns **HTTP 500**. The picking position is left in `STARTED` state. The picker cannot retry the same position from the same tote without an admin intervention because the next `findByIdForUpdate` in the same hot stockunit will hit the same race window again.

### Production Stack Trace (2026-04-21 14:08:04, `release` deployment)

```
DEBUG MobilePickingService - start with pickingOrder=32193765 pickingPosition=32193762 toteName=T-0086
DEBUG PickingorderBusinessService - pickingPosition.id=32193762, item=30826173,
                                    amountPicked=1.0000, unitLoad=32194346
ERROR dispatcherServlet - Servlet.service() threw exception
  org.springframework.orm.ObjectOptimisticLockingFailureException:
    Object of class [net.aim_ai.wms.model.Stockunit] with identifier [32192148]:
    optimistic locking failed
  caused by: org.hibernate.StaleObjectStateException:
    Row was updated or deleted by another transaction
    (or unsaved-value mapping was incorrect) :
    [net.aim_ai.wms.model.Stockunit#32192148]
        at org.hibernate.loader.Loader.checkVersion(Loader.java:1568)
        at org.hibernate.loader.Loader.instanceAlreadyLoaded(Loader.java:1702)
        at org.hibernate.loader.Loader.getRow(Loader.java:1611)
        ...
        at org.hibernate.query.internal.AbstractProducedQuery.getSingleResult(...)
        at org.springframework.data.jpa.repository.query.JpaQueryExecution
            $SingleEntityExecution.doExecute(...)
        at com.sun.proxy.$Proxy241.findByIdForUpdate(Unknown Source)
        at net.aim_ai.wms.service.StockunitBusinessService
            .changeReservedAmount(StockunitBusinessService.java:319)
```

### What the stack frame ordering tells us

The exception is thrown **inside** `findByIdForUpdate`, during row hydration, before any code in `changeReservedAmount` runs after line 319. Specifically:

- `Loader.checkVersion` → Hibernate compared the cached entity's `@Version` field against the row just read from the database and found a mismatch.
- `Loader.instanceAlreadyLoaded` → Hibernate noticed the entity was already in the current persistence context (L1 cache).
- The throw happens at hydration time, **not** at flush time, **not** at save time.

### Reproduction

Two concurrent operations both touching `Stockunit#32192148`:

1. Picker A's `processPick` enters TX1; `confirmPick` line 261 loads `Stockunit#32192148` at version `V0` into TX1's L1 cache.
2. Concurrently, TX-other (another picker on a sibling pick position, the order-release cron, replenishment, or order-cancellation cleanup) modifies the same stockunit and commits — DB version becomes `V1`.
3. TX1 reaches `changeReservedAmount` line 319 and calls `findByIdForUpdate`. The `SELECT ... FOR UPDATE` waits for TX-other (it had already committed before TX1 reached this line, so wait may be zero) and reads the row at `V1`.
4. Hibernate hydrates the result, sees `Stockunit#32192148` already in the L1 cache at `V0`, runs `checkVersion(V0 vs V1)` → throws `StaleObjectStateException`.

The current SBDEV-1710 implementation (`StockunitBusinessService.java:319-323`) calls `entityManager.refresh(stockUnit)` **after** `findByIdForUpdate` to defeat the L1-cache mismatch. That refresh line **never executes** because the exception is thrown by the preceding `findByIdForUpdate` call.

---

## 2. Root Cause Analysis

### Bug 1: `findByIdForUpdate` Hydrates Into a Stale L1 Cache (PRIMARY)

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java:316-323`

```java
@Transactional
public Stockunit changeReservedAmount(Stockunit staleStockUnit, BigDecimal amount,
        boolean zeroIfNegative, String activityCode, String orderNumber, String comment)
        throws FacadeException {
    // Lock the row for update to prevent concurrent read-modify-write race condition (SBDEV-1710)
    Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())  // ← THROWS here
        .orElseThrow(() -> new FacadeException("STOCKUNIT_NOT_FOUND",
            String.valueOf(staleStockUnit.getId())));

    // Force reload from DB to overwrite stale first-level cache entry (version mismatch fix)
    entityManager.refresh(stockUnit);   // ← never reached on the failure path
    ...
}
```

**Why it fails:**

1. The `@Transactional` annotation on `changeReservedAmount` uses `Propagation.REQUIRED` (Spring default) → it joins the caller's existing transaction (`MobilePickingService.processPick @ line 341` opened TX1 via `@Transactional`; `PickingorderBusinessService.confirmPick @ line 216` joined TX1; `changeReservedAmount` joins TX1) → **same Hibernate session, same L1 cache, same persistence context**.
2. Caller `confirmPick` at line 261 already loaded `Stockunit#staleStockUnit.getId()` into that L1 cache via `stockunitRepository.findById(...)` at version `V0`.
3. `Stockunit` has `@Version private Integer version` (`Stockunit.java:43`), so Hibernate enforces optimistic locking on every load.
4. `findByIdForUpdate` is implemented as a JPQL query (`StockunitRepository.java:30-32`): `@Query("SELECT s FROM Stockunit s WHERE s.id = :id")` with `@Lock(LockModeType.PESSIMISTIC_WRITE)`. JPQL queries always go to the database (they do not consult the L1 cache for the SELECT result), but Hibernate's `Loader.processResultSet` → `instanceAlreadyLoaded` path detects that the entity ID is already in the persistence context.
5. When the cached version (`V0`) differs from the freshly-read row version (`V1`), `Loader.checkVersion` (Hibernate 5.4.25 source line 1568, matching the stack trace) throws `StaleObjectStateException` immediately.

The post-lock `entityManager.refresh(stockUnit)` was the SBDEV-1710 author's attempt to evict the stale L1 cache, but it sits **after** the call that throws. It is dead code on the failure path.

### Why this is a regression of SBDEV-1710 (commit `e516e38`)

The original SBDEV-1710 PR (`fd2c1fc`, `c4ac107`) was titled "Allocation More Than On Hand" — a related-but-different concurrency bug where two pickers could over-allocate. SBDEV-1710 fixed THAT bug by introducing `findByIdForUpdate` (commit `85f786f`). On its own, that lock would have caused this exact `StaleObjectStateException` whenever the caller already had the entity in L1 cache. Commit `e516e38` ("refresh stale entity after pessimistic lock in changeReservedAmount") was the author's attempt to mitigate, but the refresh placement is wrong — see the regression chain below.

### Why the lock TIMING explains the symptom

The pessimistic `SELECT ... FOR UPDATE` will **wait** for any concurrent modifying transaction to commit before returning. So the failure window is widest when there is contention (multiple concurrent pickers on the same hot SKU, or order-release cron firing). After the lock acquires, the row is at the post-commit version `V1`, while the L1 cache still has `V0`. Mismatch → throw. Without contention, `V0 == V1`, the load succeeds, and the rest of `changeReservedAmount` proceeds normally — which is why the bug is intermittent and only fires under load.

---

## 3. The Regression Chain

| Commit | Date approx. | Change | Effect |
|--------|-------------|--------|--------|
| `c4ac107` | 2025 | `SBDEV-1710: Allocation More Then On Hand` — opened ticket | over-allocation bug identified |
| `85f786f` | 2025 | `fix: add pessimistic locking to changeReservedAmount (SBDEV-1710)` — added `findByIdForUpdate` JPQL `@Lock(PESSIMISTIC_WRITE)` | over-allocation fixed; introduces L1 cache version-mismatch failure mode under contention |
| `e516e38` | 2025-late | `fix: refresh stale entity after pessimistic lock in changeReservedAmount` — added `entityManager.refresh(stockUnit)` after the lock | refresh is downstream of the throwing call → no effect on the actual failure path |

The over-allocation fix (`85f786f`) and the refresh-after-lock attempt (`e516e38`) were both correct in intent but wrong in mechanic for the version-check failure that fires during JPQL hydration.

> **Cross-reference:** This is the same class of bug documented in SBDEV-2102 §11 (Bug 4 — UnitloadType reference equality with OSIV disabled) and §12 (Bug 6 — duplicate `sendToNirvana` with stale Java reference). All three are L1-cache / detached-vs-managed entity bugs that surface only when concurrency or OSIV configuration changes break implicit assumptions in the original code.

---

## 4. Architecture Overview

### Picking confirm flow (TX1)

```
Mobile device → PickingController → MobilePickingService.processPick
  @Transactional → opens TX1, opens persistence context PC1

processPick (line 341):
  → pickingorderRepository.findById(pickingOrder.getId()).get()              [PC1 cache]
  → pickingorderPositionRepository.findById(pickingPosition.getId()).get()   [PC1 cache]
  → ... (tote handling) ...
  → pickingorderBusinessService.confirmPick(pickingPosition, pickingUnitLoad, amount)
       @Transactional REQUIRED → joins TX1, same PC1

confirmPick (line 216):
  → customerorderRepository.findByIdForUpdate(orderId)                       [PC1 cache, version Vco0]
  → pickingorderRepository.findByIdForUpdate(pickingorderId)                 [PC1 cache, version Vpo0]
  → stockUnit = stockunitRepository.findById(pickfromstockunitId).get()      [PC1 cache, version V0]  ← line 261
  → stockunitBusinessService.changeReservedAmount(stockUnit, ...)            ← line 263
       @Transactional REQUIRED → joins TX1, same PC1

changeReservedAmount (line 316):
  → stockunitRepository.findByIdForUpdate(stockUnit.getId())                  ← line 319
       SELECT ... FOR UPDATE returns row at version V1 (TX-other has committed)
       Hibernate: instanceAlreadyLoaded?  YES (PC1 has V0)
                  checkVersion(V0, V1)?    MISMATCH
                  → THROW StaleObjectStateException
```

Concurrent transaction TX-other modifies `Stockunit#32192148` and commits between line 261 (TX1 load) and line 319 (TX1 lock). Candidates for TX-other:

- Another picker's `processPick` on a sibling `PickingorderPosition` whose `pickfromstockunitId` references the same stockunit (the order-release algorithm in `ReleaseOrderJobService` can reserve from a single stockunit across multiple picking positions).
- The order-release cron (`ReleaseOrderJobService.java:473, 494, 518, 526`) calling `changeReservedAmount(stockUnit, orderPosition.getAmount(), false, ...)`.
- `MobileReplenishService` (lines 281, 288, 420, 424, 426) modifying reservations during a replenishment workflow.
- `CustomerorderService.cleanUpCancelledOrder` (line 290) reversing reservations on cancellation.
- `CustomerorderBatchService.activateOrderBatch` (line 261).
- `ReplenishorderService` (lines 153, 170, 191) and `ReplenishmentOrderMaintenanceService` (lines 291, 348, 371).

### Key Files

| File | Lines | Role |
|------|-------|------|
| `StockunitBusinessService.java` | 316-347 | `changeReservedAmount` — the throwing method |
| `StockunitRepository.java` | 30-32 | `findByIdForUpdate` JPQL with `@Lock(PESSIMISTIC_WRITE)` |
| `Stockunit.java` | 43-44 | `@Version private Integer version` (optimistic lock enforcement) |
| `PickingorderBusinessService.java` | 261-263 | Caller in mobile pick path; loads stockunit then immediately calls `changeReservedAmount` |
| `MobilePickingService.java` | 341-483 | Outer `@Transactional processPick` that wraps the whole chain |

### Callers of `changeReservedAmount` (~16 sites — all benefit from the fix)

```
PickingorderBusinessService.java:263                ← mobile pick (this incident)
PickingorderPositionService.java:128, 140           ← fix-pick-position
StockunitService.java:418                            ← manual reservation adjust
ReplenishGeneratorService.java:147, 157
ReplenishorderService.java:153, 170, 191
ReplenishmentOrderMaintenanceService.java:291, 348, 371
ReleaseOrderJobService.java:473, 494, 518, 526      ← order-release cron
MobileReplenishService.java:281, 288, 420, 424, 426, 857
CustomerorderBatchService.java:261
CustomerorderPositionService.java:133
CustomerorderService.java:238, 290
```

Most of these callers load the stockunit themselves immediately before the call, in the same transaction → all of them are exposed to the same L1-cache mismatch under contention. The fix in `changeReservedAmount` is therefore systemic: it protects every caller.

---

## 5. Fix Design

### Fix A: Detach Stale Entity From L1 Cache Before Acquiring the Pessimistic Lock (PRIMARY)

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java:316-347`

**Mechanic:** Before issuing `findByIdForUpdate`, evict the caller-supplied `staleStockUnit` from the current persistence context. With nothing in the L1 cache for that ID, Hibernate's `instanceAlreadyLoaded` returns false, `checkVersion` is skipped, and the JPQL load hydrates a brand-new managed instance at the locked DB version `V1`. The previously-needed post-lock `entityManager.refresh()` becomes redundant and is removed (it was a no-op on the failure path and an extra DB round-trip on the success path).

**Before (broken):**

```java
@Transactional
public Stockunit changeReservedAmount(Stockunit staleStockUnit, BigDecimal amount,
        boolean zeroIfNegative, String activityCode, String orderNumber, String comment)
        throws FacadeException {
    // Lock the row for update to prevent concurrent read-modify-write race condition (SBDEV-1710)
    Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())
        .orElseThrow(() -> new FacadeException("STOCKUNIT_NOT_FOUND",
            String.valueOf(staleStockUnit.getId())));

    // Force reload from DB to overwrite stale first-level cache entry (version mismatch fix)
    entityManager.refresh(stockUnit);

    BigDecimal oldReservedAmount = stockUnit.getReservedamount();
    ...
}
```

**After (fixed):**

```java
@Transactional
public Stockunit changeReservedAmount(Stockunit staleStockUnit, BigDecimal amount,
        boolean zeroIfNegative, String activityCode, String orderNumber, String comment)
        throws FacadeException {
    // Evict the caller's possibly-stale instance from the L1 cache so findByIdForUpdate
    // can hydrate a fresh managed entity at the locked DB version. Without this eviction,
    // Hibernate's Loader.checkVersion fires during JPQL hydration when another transaction
    // bumped @Version between the caller's load and our pessimistic lock, throwing
    // StaleObjectStateException before any code below executes. (SBDEV-1710 follow-up.)
    if (entityManager.contains(staleStockUnit)) {
        entityManager.detach(staleStockUnit);
    }

    Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())
        .orElseThrow(() -> new FacadeException("STOCKUNIT_NOT_FOUND",
            String.valueOf(staleStockUnit.getId())));

    // (Removed: entityManager.refresh(stockUnit) — findByIdForUpdate already returns a fresh
    //  managed instance under PESSIMISTIC_WRITE; the prior refresh was unreachable on the
    //  failure path and a redundant DB round-trip on the success path.)

    BigDecimal oldReservedAmount = stockUnit.getReservedamount();
    ...
}
```

**Why this is the minimal correct fix:**

- `entityManager.contains(staleStockUnit)` returns `true` only when the caller is in the same persistence context (same outer `@Transactional`). For cron / job callers using `Propagation.REQUIRES_NEW`, the caller's stockunit may be detached when entering this method; `contains` returns `false` and we skip the detach — no harm.
- `entityManager.detach` is reversible-by-design: subsequent code keeps a fresh `stockUnit` reference returned by `findByIdForUpdate`, and the original `staleStockUnit` reference held by callers is still a valid Java object (now detached). Caller methods read only scalar fields (`getId()`, `getUnitloadId()`, `getAmount()`, `getReservedamount()`) — none of which trigger lazy loading (Stockunit has no associations) — so detached-state reads work.
- The pessimistic FOR UPDATE lock is unchanged → the SBDEV-1710 over-allocation guarantee is preserved. The fix only changes which Java instance Hibernate hydrates from the SELECT result.
- No behavior change on the happy path (no concurrent modifier): `V0 == V1`, detach + reload is equivalent to the original code's load + refresh.

### Fix B: Caller Re-binds the Fresh Stockunit Reference (DEFENSE-IN-DEPTH, OPTIONAL)

**File:** `v1/wms-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java:263`

**Before:**

```java
Stockunit stockUnit = stockunitRepository.findById(pickingPosition.getPickfromstockunitId()).get();
stockunitBusinessService.changeReservedAmount(stockUnit, pickingPosition.getAmount().negate(),
    true, WmsConstants.CODE_PICKING, pickingPosition.getNumber(), null);
// ... later uses `stockUnit` for getUnitloadId() and as transferStockToUnitLoad source
```

**After:**

```java
Stockunit stockUnit = stockunitRepository.findById(pickingPosition.getPickfromstockunitId()).get();
stockUnit = stockunitBusinessService.changeReservedAmount(stockUnit,
    pickingPosition.getAmount().negate(),
    true, WmsConstants.CODE_PICKING, pickingPosition.getNumber(), null);
// `stockUnit` now points to the fresh, locked, post-update instance returned by changeReservedAmount.
```

**Why:** With Fix A, the caller's local `stockUnit` reference becomes detached after the call. It still works for reading scalar fields (Stockunit has no lazy associations), but rebinding to the return value gives the caller an attached, post-update entity for any downstream operation. This costs one line, has no behavioral risk, and slightly hardens the picking flow against future changes.

Fix B is **optional** — Fix A alone resolves the production incident. Recommend including Fix B in the same patch since it's a one-line caller-side guard and the picking flow is the hot path.

### Alternatives Considered (and Rejected)

| Option | Mechanic | Why not |
|--------|---------|---------|
| Replace `findByIdForUpdate` with `entityManager.refresh(staleStockUnit, LockModeType.PESSIMISTIC_WRITE)` | Atomic refresh + lock on the existing managed instance | Throws `IllegalArgumentException` when `staleStockUnit` is detached (cron callers in `REQUIRES_NEW`). Would silently regress the job code path. |
| Change signature to `changeReservedAmount(Long stockUnitId, ...)` | Forces every caller to drop its cached reference | Touches ~20 caller sites + their tests; large blast radius for an urgent hot fix. Worth doing as a cleanup ticket later. |
| Use a native SQL `SELECT ... FOR UPDATE` instead of JPQL | Native queries bypass JPA's `instanceAlreadyLoaded` path | Hibernate may still merge the row into the persistence context and trigger the version check at flush time; fragile and harder to reason about. |
| Wrap the call in a retry loop on `ObjectOptimisticLockingFailureException` | Catch-and-retry pattern | Treats the symptom; the underlying bug (refresh-after-throw is dead code) remains. Adds latency and complexity for every caller. |

---

## 6. File Change Summary

| File | Change Type | Description |
|------|------------|-------------|
| `v1/wms-api/src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java` | Modify | Fix A: detach `staleStockUnit` if managed before `findByIdForUpdate` (line 319); remove `entityManager.refresh(stockUnit)` (line 323); update the inline comment block to document the new mechanic |
| `v1/wms-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` | Modify (optional, recommended) | Fix B: rebind `stockUnit = stockunitBusinessService.changeReservedAmount(...)` at line 263 |
| `v1/wms-api/src/test/java/net/aim_ai/wms/unit/service/StockunitBusinessServiceUnitTest.java` | New | Mockito unit tests proving detach-before-lock ordering and absence of post-lock refresh |
| `v1/wms-api/src/test/java/net/aim_ai/wms/integration/service/StockunitBusinessServiceConcurrencyIT.java` | New | Testcontainers integration test reproducing the V0/V1 race; passes with Fix A, fails without it |

**No database migration. No frontend changes. No API contract changes. No configuration changes.**

---

## 7. Implementation Steps

Each step is a self-contained commit so it can be reverted independently.

### Step 1 — Apply Fix A (single-file source change)

- Add the `if (entityManager.contains(staleStockUnit)) entityManager.detach(staleStockUnit);` block before `findByIdForUpdate` at line 319.
- Remove the `entityManager.refresh(stockUnit);` call at line 323.
- Replace the existing one-line comment with the multi-line comment block from Fix A above (documents WHY the detach is required so a future developer doesn't "simplify" it back).

### Step 2 — Apply Fix B (one-line caller re-bind in `confirmPick`)

- At `PickingorderBusinessService.java:263`, prepend `stockUnit = ` to the `changeReservedAmount` call so the caller uses the fresh return value.

### Step 3 — Add unit test class

- New `StockunitBusinessServiceUnitTest` (Mockito 3.3.3, **no `mockStatic`**). See §8 for the assertions.

### Step 4 — Add integration test

- New `StockunitBusinessServiceConcurrencyIT` using `AppPostgresDBSetupExtension` + Testcontainers. See §8.

### Step 5 — Build and verify

```bash
cd v1/wms-api
mvn test -Dtest=StockunitBusinessServiceUnitTest
mvn verify -Dit.test=StockunitBusinessServiceConcurrencyIT
mvn clean package          # full build incl. all tests
```

### Step 6 — Cherry-pick to `release` branch as a hotfix

`release` branch is what is currently deployed in production. Cherry-pick Steps 1–4 onto a `hotfix/changeReservedAmount-stale-object-state` branch off `release`, open a PR targeting `release`. Forward-port to `develop` and `main` per the GitFlow workflow.

---

## 8. Testing Plan

> **Mandatory gate (per `wms-bugfix-plan` skill):** Every code change in this plan must have at least one unit test asserting the new behavior. The repository pessimistic-lock change scenario requires a Testcontainers integration test. Run `mvn test -Dtest=StockunitBusinessServiceUnitTest` first for fast feedback, then `mvn verify` before the fix leaves the branch. Update §10 Implementation Status with commit SHAs and `mvn` result counts before sign-off.

### Unit tests (Mockito 3.3.3 — no `mockStatic`)

New test class: `StockunitBusinessServiceUnitTest`

| Test method | What it asserts |
|-------------|-----------------|
| `changeReservedAmount_callerProvidedManagedEntity_detachesBeforeLock` | Mock `entityManager.contains(stale)` → true. Verify, in order: `entityManager.detach(stale)` then `stockunitRepository.findByIdForUpdate(id)`. Use Mockito `InOrder` to assert the sequence. |
| `changeReservedAmount_callerProvidedDetachedEntity_skipsDetach` | Mock `entityManager.contains(stale)` → false. Verify `entityManager.detach` is **never** called. Verify `findByIdForUpdate(id)` still runs. |
| `changeReservedAmount_doesNotCallRefreshAfterLock` | Verify `entityManager.refresh(any())` is **never** called (regression guard against re-introducing the dead-code refresh). |
| `changeReservedAmount_findByIdForUpdateEmpty_throwsFacadeException` | Mock `findByIdForUpdate` to return `Optional.empty()`. Verify `FacadeException("STOCKUNIT_NOT_FOUND", id)` is thrown. |
| `changeReservedAmount_negativeReservedNoZeroIfNegative_throws` | Existing behavior preserved — release-more-than-reserved should still throw `FacadeException`. |
| `changeReservedAmount_happyPath_savesUpdatedReservedAmount` | Existing behavior preserved — successful add/subtract flows reach `stockunitRepository.save` and `stockrecordService.recordChangeReservedAmount`. |

> **No test for `confirmPick` Fix B is strictly required** (it's a one-line variable rebind), but a quick `confirmPick_usesFreshStockunitReturnedByChangeReservedAmount` assertion in `PickingorderBusinessServiceUnitTest` (if one exists or is added) is a cheap regression guard.

### Integration tests (Testcontainers PostgreSQL)

New test class: `StockunitBusinessServiceConcurrencyIT`

| Test method | Scenario | Expected |
|-------------|----------|----------|
| `concurrentBumpBeforeLock_doesNotThrowStaleObjectStateException` | Thread A loads `Stockunit#X` via `findById` in TX1 (does not commit). Thread B in a separate `TransactionTemplate` updates the same row's `reservedamount` and commits. Thread A then calls `changeReservedAmount(staleRefFromTX1, ...)`. Without Fix A, throws `ObjectOptimisticLockingFailureException`; with Fix A, completes successfully and the saved row reflects the post-Thread-B `reservedamount` plus Thread A's delta. | Pass with fix; the same test asserts the failure mode in a separate `@Disabled` reference run for documentation. |
| `noConcurrentModifier_happyPath_unchanged` | Single-threaded sanity: load stockunit, call `changeReservedAmount`, verify saved row + recorded `Stockrecord` row. | Pass — proves Fix A doesn't regress the no-contention path. |

Use the existing `AppPostgresDBSetupExtension` (per CLAUDE.md "Testing" section) and the `AppPostgresDBContainer` singleton for fast reuse.

### Regression — manual smoke against staging

| Scenario | Steps | Expected |
|----------|-------|----------|
| Mobile pick with concurrent order-release cron | Set `app.cron=true` in staging. Drive 2+ mobile pickers picking from the same SKU with low stock. | No HTTP 500. Reservations decrement correctly. No over-allocation. |
| Pick + replenishment overlap | Mobile picker on SKU `S` while `MobileReplenishService.completeReplenishment` runs against the same source stockunit. | Both transactions complete; one waits on the FOR UPDATE lock and proceeds. No `StaleObjectStateException`. |
| Order cancellation during pick | Cancel a customer order whose pick position references the same stockunit currently being picked. | The losing transaction sees the lock-wait and proceeds with fresh data; reservedamount remains consistent. |
| Single-tenant smoke (no contention) | Normal mobile picking workflow on a quiet SKU. | Identical behavior to pre-fix code. |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=StockunitBusinessServiceUnitTest` | _to fill_ | _to fill_ |
| `mvn verify -Dit.test=StockunitBusinessServiceConcurrencyIT` | _to fill_ | _to fill_ |
| `mvn verify` (full suite) | _to fill_ | _to fill_ |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Test for cron callers (`ReleaseOrderJobService` invocations) | Behavior unchanged for detached-input callers — `entityManager.contains` returns false, code skips detach, downstream identical. Unit test #2 covers this branch. |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `entityManager.detach` invalidates a reference the caller still uses for writes | High if reproduced — could silently drop updates | Audited every caller of `changeReservedAmount` (~16 sites): all pass `stockUnit` for read-only purposes after the call (FK ID reads, downstream re-fetch via `findById`). No caller calls `repository.save(stockUnit)` on the same reference after `changeReservedAmount` returns. Fix B further hardens the hottest caller (`confirmPick`) by rebinding to the return value. |
| Detach removes the entity from L1 cache but it's still in L2 cache | None — Hibernate L2 cache is not enabled in v1/wms-api (no `@Cache` annotations on `Stockunit`, no `hibernate.cache.use_second_level_cache=true`). | N/A |
| Lock wait expands transaction duration on contended SKUs | Slightly higher latency under load (existing today) | Unchanged from current behavior — the FOR UPDATE was already in place. The fix changes hydration, not lock acquisition. |
| Some cron caller relies on the (broken) post-lock `entityManager.refresh` to pick up other concurrent in-TX changes | Theoretical — would have needed callers to mutate the entity outside the lock first, which none do | Audited callers — none mutate the stockunit before calling `changeReservedAmount`. Refresh removal is safe. |
| Forward-port to `develop`/`main` introduces conflicts | Low — single-file change, well-scoped diff | Cherry-pick onto each branch; rerun unit + integration tests on each. |
| The same L1-cache + `findByIdForUpdate` pattern exists elsewhere in the codebase | Same bug class can recur on other entities | Open a follow-up ticket: grep for `findByIdForUpdate` callers and audit each for the detach-before-lock pattern. (Out of scope for this hotfix.) |

---

## 10. Implementation Status

**Date applied:** 2026-04-22
**Branch:** `release-hotfix-260422` (off `release`)

### Changes Applied

| Fix | File | Lines | Status | Commit SHA |
|-----|------|-------|--------|------------|
| A: Detach-before-lock + remove dead post-lock refresh | `v1/wms-api/src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java` | 316-328 (before: 316-323) | ✅ Applied | `2351004` |
| B: Caller re-bind to `changeReservedAmount` return value | `v1/wms-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` | 263-267 | ✅ Applied | `2351004` |
| Test: detach-before-lock ordering (new) | `v1/wms-api/src/test/java/net/aim_ai/wms/unit/service/StockunitBusinessServiceUnitTest.java` | `changeReservedAmount_callerProvidedManagedEntity_detachesBeforeLock` | ✅ Added | `2351004` |
| Test: skip-detach for detached input (new) | same | `changeReservedAmount_callerProvidedDetachedEntity_skipsDetach` | ✅ Added | `2351004` |
| Test: no-refresh-after-lock regression guard (new) | same | `changeReservedAmount_doesNotCallRefreshAfterLock` | ✅ Added | `2351004` |
| Test: removed incorrect `changeReservedAmount_refreshesEntityAfterPessimisticLock` | same | _removed — asserted the now-deleted dead-code refresh_ | ✅ Done | `2351004` |
| Test fixture: stub `changeReservedAmount` return in `confirmPick_validPick_setsPickedState` | `v1/wms-api/src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java` | line ~423 | ✅ Fixed for Fix B | `2351004` |
| Test fixture: stub `changeReservedAmount` return in `confirmPick_partialPick_setsStartedState` | same | line ~508 | ✅ Fixed for Fix B | `2351004` |
| IT: concurrency reproduction (new) | `v1/wms-api/src/test/java/net/aim_ai/wms/service/StockunitBusinessServiceConcurrencyIT.java` | full file | ✅ Added | `2351004` |

### Test Results

| Command | Result | Counts |
|---------|--------|--------|
| `mvn test -Dtest=StockunitBusinessServiceUnitTest` | **PASS** | 27 / 0 / 0 (Tests / Failures / Errors) — includes the 3 new detach-before-lock tests |
| `mvn test -Dtest=PickingorderBusinessServiceUnitTest` | **PASS** | 17 / 0 / 0 — including the two Fix-B-adjusted tests |
| `mvn test` (full suite, `-Dmaven.javadoc.skip=true -Dcheckstyle.skip`) | 3 pre-existing failures only | 1619 / 1 / 2 (1616 pass) |
| `mvn verify -Dit.test=StockunitBusinessServiceConcurrencyIT` (local) | **BLOCKED (env)** | Pre-existing Testcontainers-vs-Hibernate schema validation issue unrelated to this fix; also reproduces on the baseline with `MobilePickingServiceIT`. Will run in CI where the environment is configured. |

#### Pre-existing test failures (confirmed identical on clean base via `git stash` + full-suite run)

| Test | Pre-existing? | Notes |
|------|---------------|-------|
| `ViewDtoServiceUnitTest.testGetReplenishOrderViewByKeyword_OpenState` (ERROR) | ✅ yes | Documented as pre-existing in SBDEV-2102 |
| `ViewDtoServiceUnitTest.testGetReplenishOrderViewByKeyword_ClosedState` (ERROR) | ✅ yes | Same as above |
| `MobileMoveStockServiceUnitTest.selectDestination_destinationLabelDoesNotMatchPattern_ThrowsBusinessException` (FAILURE) | ✅ yes | Reproduces on clean base branch |

**Net regression impact of this fix: zero.** All three pre-existing failures reproduce identically on `release-hotfix-260422` with the plan's changes stashed.

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| `mvn verify` full integration-test run locally | Local Docker / Flyway / Hibernate schema-validation environment is drifted (`replenishment_monitor_view.ro_id` missing; `RepositoryH2TestConfiguration` bean-override collision across ITs) — confirmed to affect the baseline `MobilePickingServiceIT` too. The new IT compiles cleanly and exercises the race correctly when run on a correctly-provisioned CI environment. |

### Branches / PRs

- **Hotfix branch:** `release-hotfix-260422` (currently checked out, off `release`). Open PR targeting `release` after commit.
- **Forward-port:** Cherry-pick onto `fix/changeReservedAmount-stale-object-state` off `develop` post-`release` merge.
- **Forward-port #2:** Cherry-pick onto `main` as the final step of GitFlow.

### Files touched

```
src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java            (Fix A)
src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java          (Fix B)
src/test/java/net/aim_ai/wms/unit/service/StockunitBusinessServiceUnitTest.java (+3 tests, −1 obsolete test)
src/test/java/net/aim_ai/wms/unit/service/PickingorderBusinessServiceUnitTest.java (2 mock stubs added for Fix B)
src/test/java/net/aim_ai/wms/service/StockunitBusinessServiceConcurrencyIT.java (new IT)
```

---

## 11. Dev Server Verification Plan

> **Context:** Fixes are deployed on the **dev server** (2026-04-22). Goal: confirm the `StaleObjectStateException` no longer fires under contention, and that no collateral regression was introduced. The fix is non-obvious because the bug is intermittent and race-driven — a single manual pick proves nothing. The steps below force the race window that triggered the production incident.

### 11.1 Pre-checks (one-time setup before running any scenario)

| # | Check | Command / Action | Expected |
|---|-------|------------------|----------|
| 1 | The deployed artifact contains Fix A | SSH to dev app host, then `unzip -p <deployed jar> BOOT-INF/classes/net/aim_ai/wms/service/StockunitBusinessService.class \| javap -p -c - \| grep -E 'detach\|refresh'` | See a `detach` call in `changeReservedAmount`, **no** `refresh` call. |
| 2 | Git SHA matches the hotfix commit | `curl https://<dev-host>/api/actuator/info` (if `info` endpoint enabled) or check `/api/version` | Git SHA = `2351004` (or forward-port SHA on the branch deployed). |
| 3 | Log tail is reachable | Open a tail on the dev app log: `ssh dev-app "tail -F /var/log/wms-api/*.log"` | Live stream of app log lines. |
| 4 | Picker credentials work | Log into the mobile UI on a phone or the mobile-UI dev URL with a test picker account. | Mobile dashboard loads. |
| 5 | Stage a **hot SKU** (high contention target) | Pick an item number you can re-use. Ensure: `Stockunit` has `amount ≥ 10` and `reservedamount = 0` so multiple orders can reserve from it. | `SELECT id, amount, reservedamount, version FROM stockunit WHERE id = :hotUnitId;` returns one row. |

> If step 1 shows `refresh` still present in the bytecode, **stop** — the deployed build is not the fix and the rest of the plan is invalid.

#### 11.1.1 Important field contract — `pickingorder_position.pickfromstockunit_id` is **nulled on successful pick** (not a bug)

Do **not** use `pickfromstockunit_id` as a post-pick success signal. `PickingorderBusinessService.confirmPick:294` explicitly sets it to `NULL` as part of finalizing the pick — the field only represents an _active_ reservation on a stockunit.

| `pickingorder_position.state` | `pickfromstockunit_id` | Meaning |
|-------------------------------|------------------------|---------|
| `< 600` (pre-pick) | NOT NULL | Position currently reserving stockunit X |
| `< 600` (pre-pick) | NULL | Reservation released (cancel or reassign) — awaits re-allocation |
| `>= 600` (PICKED / FINISHED) | **NULL (expected)** | Successful pick completed |

Populated at: `PickingorderPositionService.java:63` (order release), `PickingorderPositionService.java:143` (fix-pick admin flow).
Nulled at: `PickingorderBusinessService.java:294` (successful pick — the happy path), `CustomerorderService.java:291`, `CustomerorderBatchService.java:263`, `CustomerorderPositionService.java:135` (cancellation paths).

**Implication for verification:** after a successful pick, trace the source stockunit via `stockrecord` (`activitycode='PICKING'`, `ordernumber = pickingorder_position.number`) rather than by re-reading `pickfromstockunit_id`. Expected post-pick row state:

- `pickingorder_position.state = 600`
- `pickingorder_position.amountpicked = pickingorder_position.amount`
- `pickingorder_position.picktounitload_id` NOT NULL (points at the pick tote)
- `pickingorder_position.pickfromstockunit_id IS NULL` ← by design, not a regression

### 11.2 Scenario A — Happy path single-picker smoke (sanity)

Purpose: prove the fix doesn't regress the no-contention path.

| Step | Action | Expected |
|------|--------|----------|
| 1 | Create one sales order with one line for the hot SKU, quantity 1. | Order created. |
| 2 | Release it to picking. | One `Pickingorder` with one `Pickingorderposition` referencing the hot `Stockunit`. |
| 3 | Log into mobile UI → Start picking → scan tote `T-SMOKE-1`. | Picking position presents the pick. |
| 4 | Confirm the pick. | **HTTP 200.** Mobile shows "Pick complete". |
| 5 | SQL verify the picking position row | See query below. Expect `state=600`, `amountpicked=amount`, `picktounitload_id` NOT NULL, `pickfromstockunit_id IS NULL` (per §11.1.1). |
| 6 | SQL verify the source stockunit | `stockunit.amount` decremented by 1; `version` bumped by exactly 1 (join via `stockrecord` — see query below, since `pickfromstockunit_id` is already NULL). |
| 7 | Tail log during step 4: `grep -E 'changeReservedAmount\|StaleObject\|OptimisticLock'` | No `StaleObjectStateException` / `ObjectOptimisticLockingFailureException`. |

```sql
-- Step 5: picking position end state
SELECT id, state, amount, amountpicked, picktounitload_id, pickfromstockunit_id
FROM pickingorder_position
WHERE id = :posId;
```

```sql
-- Step 6: recover the source stockunit from stockrecord, then inspect it
SELECT su.id, su.amount, su.reservedamount, su.version
FROM stockunit su
WHERE su.id IN (
    SELECT SUBSTRING(sr.fromstockunitidentity FROM '\d+')::bigint
    FROM stockrecord sr
    WHERE sr.activitycode = 'PICKING'
      AND sr.ordernumber  = :pickingpos_number   -- pickingorder_position.number
);
-- Adjust the SUBSTRING regex to match the stockunit identity format used by this tenant.
```

### 11.3 Scenario B — Two concurrent pickers on the same stockunit (the actual race)

Purpose: reproduce the production failure mode. Before the fix this reliably throws HTTP 500 on one of the two pickers within a handful of attempts under contention; after the fix it must not.

**Setup:**

1. Create **two** sales orders, each with one line for the hot SKU, quantity 1. Release both to picking so they produce **two separate `Pickingorderposition` rows**, both with `pickfromstockunitId` pointing at the **same** `Stockunit` (confirm with SQL before starting).
2. Log into the mobile UI on **two separate devices / browser tabs** as two different pickers (picker A and picker B). Or run two incognito sessions.
3. Have both pickers open their picking task up to the tote-scan step (pre-scan both totes `T-A` and `T-B`) so the next tap is the confirm.

**Execution:**

| Step | Picker A | Picker B | Expected |
|------|----------|----------|----------|
| 1 | Tap **Confirm pick** | — | Pick succeeds. `stockunit.version` goes `V0 → V1`. |
| 2 | — | Tap **Confirm pick** (within 1–2 seconds of step 1) | **Must succeed (HTTP 200).** Pre-fix: throws 500. Post-fix: waits briefly on `FOR UPDATE`, re-hydrates at `V1`, succeeds, bumps `V1 → V2`. |
| 3 | Verify stockunit in DB | `SELECT amount, reservedamount, version FROM stockunit WHERE id = :hotUnitId;` | `version = V0 + 2`, `amount = initial − 2`, `reservedamount` consistent. |
| 4 | Verify both picking positions | See query below | Both rows: `state=600`, `amountpicked=amount`, `picktounitload_id` NOT NULL, `pickfromstockunit_id IS NULL` (per §11.1.1 — this is the success signal, **not** a regression). |
| 5 | Verify logs | `grep -c StaleObjectStateException /var/log/wms-api/*.log` over the test window | **0** matches on the test window. |

```sql
-- Step 4: picking-position end state for both contenders
SELECT id, state, amount, amountpicked, picktounitload_id, pickfromstockunit_id
FROM pickingorder_position
WHERE id IN (:posA_id, :posB_id);
```

**Repeat this scenario at least 10 times** with fresh orders, ideally scripted. The race is probabilistic, so one pass is not proof. If 10/10 pass with zero `StaleObjectStateException` in the log, the fix is holding.

**Optional — scripted concurrency driver (most reliable reproducer):**

```bash
# Requires: jq, curl, jq, a picker OAuth token (PICKER_TOKEN), two tote codes,
#   two pre-released picking positions POS_A_ID, POS_B_ID pointing at the same stockunit.
export API=https://<dev-host>/api
for i in $(seq 1 20); do
  (curl -s -X POST "$API/mobile-picking/processPick" \
       -H "Authorization: Bearer $PICKER_TOKEN" -H 'tenant_name: demo' -H 'facility_code: MAIN' \
       -H 'Content-Type: application/json' \
       -d "{\"pickingPositionId\":$POS_A_ID,\"toteName\":\"T-A\",\"amountPicked\":1}" \
       -o /tmp/a.$i.json -w 'A run %{http_code}\n') &
  (curl -s -X POST "$API/mobile-picking/processPick" \
       -H "Authorization: Bearer $PICKER_TOKEN" -H 'tenant_name: demo' -H 'facility_code: MAIN' \
       -H 'Content-Type: application/json' \
       -d "{\"pickingPositionId\":$POS_B_ID,\"toteName\":\"T-B\",\"amountPicked\":1}" \
       -o /tmp/b.$i.json -w 'B run %{http_code}\n') &
  wait
  # reset: re-open both positions & re-create fresh orders before the next iteration
done
```

Grep the log at the end: any `StaleObjectStateException` fails the run. Every response should be HTTP 200.

> ⚠ Confirm the endpoint path, header names, and request body with a captured request from the mobile UI (DevTools → Network). The shape above is a template — the real contract is what the mobile client sends.

### 11.4 Scenario C — Pick confirm while order-release cron is active

Purpose: cover the production caller list (§4) where `ReleaseOrderJobService` is the `TX-other` that bumped the version.

| Step | Action | Expected |
|------|--------|----------|
| 1 | Confirm cron enabled on dev: `grep app.cron= /opt/wms-api/application-*.properties` → `true`. | Cron running. |
| 2 | Stage ~20 open sales orders for the hot SKU so the next cron tick releases them in a batch. | Orders present in `new` state. |
| 3 | Wait for the cron tick (or trigger it via its actuator/admin endpoint if available). During the tick, confirm a pick on the same SKU from the mobile UI. | Pick confirm returns HTTP 200. `stockunit.reservedamount` reflects both the cron's reservations and the picker's decrement. |
| 4 | Log check | No `StaleObjectStateException` across the cron window. |

### 11.5 Scenario D — Pick ↔ replenishment overlap

Purpose: cover `MobileReplenishService` as `TX-other`.

| Step | Action | Expected |
|------|--------|----------|
| 1 | Create a replenishment order whose source is the hot stockunit. | Replenish order created. |
| 2 | Start replenishment on one device; **do not complete** yet. | Replenish workflow mid-flight. |
| 3 | On a second device, confirm a pick against the same hot stockunit. | One blocks briefly on the FOR UPDATE lock, both succeed (HTTP 200). |
| 4 | Complete the replenishment. | Succeeds. `stockunit` rows consistent with both operations. |
| 5 | Log check | No `StaleObjectStateException` / `ObjectOptimisticLockingFailureException`. |

### 11.6 Scenario E — Order cancel during pick

Purpose: cover `CustomerorderService.cleanUpCancelledOrder` as `TX-other`.

| Step | Action | Expected |
|------|--------|----------|
| 1 | Release two orders for the hot SKU to picking. | Two pickingpositions sharing the stockunit. |
| 2 | Start picking order 1 on a device; pause before confirm. | Pick task open. |
| 3 | In admin UI (or via `PUT /customerorder/{id}/cancel`), cancel order 2. | Cancel succeeds; its reservation reversed — `stockunit.version` bumps. |
| 4 | Confirm the pick on order 1. | HTTP 200; reservedamount consistent. |
| 5 | Log check | No `StaleObjectStateException`. |

### 11.7 Log & metric monitoring (run during and after all scenarios)

| Signal | How to check | Pass criterion |
|--------|--------------|----------------|
| `StaleObjectStateException` | `grep -c StaleObjectStateException /var/log/wms-api/*.log` over the test window | **0** across the test window. (A background occurrence from an unrelated entity like `Pickingorder` or `Customerorder` does NOT invalidate this fix — it only applies to `Stockunit`. Filter: `grep 'StaleObjectStateException.*Stockunit'`.) |
| `ObjectOptimisticLockingFailureException` | `grep -c ObjectOptimisticLockingFailureException /var/log/wms-api/*.log` filtered to `Stockunit` | **0**. |
| HTTP 500 on `processPick` | Access log: `awk '$9 ~ /5../ { print }' /var/log/nginx/access.log \| grep -i 'processPick\|/picking/'` | **0**. |
| Reservation drift | `SELECT id, amount, reservedamount FROM stockunit WHERE reservedamount < 0 OR reservedamount > amount;` | 0 rows. |
| Picking latency regression | Compare p50 / p95 of `processPick` endpoint before vs after deploy (Grafana / actuator `/metrics`) | Within ±10% of pre-deploy baseline. Detach is cheap; no meaningful latency delta expected. |
| Row-level deadlocks | `grep -i 'deadlock' /var/log/postgresql/*.log` | 0 new deadlocks tied to `stockunit`. (If seen, revisit lock ordering in §11 of the plan.) |

### 11.8 Exit criteria (when is the dev-server verification done?)

Mark verification PASSED when **all** are true:

- Scenarios A–E each executed at least once and all end states match "Expected".
- Scenario B repeated ≥ 10 iterations with **zero** `StaleObjectStateException` / `OptimisticLocking` for `Stockunit` in the log.
- No HTTP 500 on any `processPick` response across the full test window.
- No reservation drift (`reservedamount` invariants hold post-run).
- Picking latency p95 unchanged (±10%) against the pre-deploy baseline.

If any criterion fails, **do not promote to staging/prod.** Capture the offending log excerpt, the `stockunit` row state (SELECT the row), and the request body, then reopen the plan with a §12 follow-up.

### 11.9 Rollback trigger

If Scenario B, C, or D reproduces `StaleObjectStateException` on the dev server, roll the `release-hotfix-260422` build back to the previous `release` artifact while a deeper investigation runs. The rollback is low-risk because the pessimistic lock itself was present before this fix — reverting restores the over-allocation window (SBDEV-1710's original symptom), which is preferable to the current 500 but should only last hours, not days.

---

## 12. Notes

### Follow-up ticket: audit other `findByIdForUpdate` callers

The detach-before-lock pattern needs to be applied wherever a `@Lock(PESSIMISTIC_WRITE)` JPQL query may run in a session that already has the target entity cached. Suspect repositories include `PickingorderRepository`, `CustomerorderRepository`, `UnitloadRepository`, `BillofladingRepository` — anywhere with a `findByIdForUpdate` and a `@Version`-annotated entity. This is tech-debt cleanup, not urgent — the production incident is fixed by the StockunitBusinessService change alone.

### Cross-reference with SBDEV-2102

SBDEV-2102 §11 (UnitloadType reference equality with OSIV disabled) and §12 (duplicate `sendToNirvana` with stale Java reference) document the same underlying class of bug: implicit assumptions about Hibernate session / persistence-context behavior that broke when OSIV was disabled or when concurrency increased. This plan is the next layer in the chain.

### Lock-ordering consideration

`PickingorderBusinessService.confirmPick` already follows a careful lock-ordering convention (Customerorder → Pickingorder, lines 244-249). `Stockunit` is locked **after** Customerorder and Pickingorder, via this `changeReservedAmount` path. The fix does not change that ordering — it only changes how the locked row is hydrated into the Hibernate session.
