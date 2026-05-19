---
title: "confirmPick last-pick detection race — unlocked sibling read leaves order stuck at STARTED"
ticket: "SBDEV-2223"
ticket_url: ""
type: "bugfix"
priority: "high"
status: "implemented"
project:
  - wms2
version: "v2"
requester: ""
created: "2026-05-12"
updated: "2026-05-12"
db_verified: false
related:
  - sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
  - sbdocs/3-Resources/architecture/wms2-end-to-end-request-journey.md
  - sbdocs/3-Resources/workflows/wms2-picking-workflow.md
tags:
  - plan
  - wms2
  - picking
  - concurrency
  - pessimistic-lock
  - race-condition
---

# SBDEV-2223 — `confirmPick` last-pick detection race

**Ticket:** SBDEV-2223
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high
**Status:** draft
**Date:** 2026-05-12

> **db_verified: false** — Plan is grounded in source code only. Manual pre-deploy check: query
> `customerorder` rows where all sibling `customerorderposition` rows have `state >= 600` but
> the parent `customerorder.state = 500`. This is the bug's signature. Record the count before
> merge. See §10 for the verification SQL.

---

## §0 Affected Sites

All `CustomerorderPositionRepository.findByOrderId(Long)` call sites in
`PickingorderBusinessService.java` were enumerated and triaged.

| # | File:line | Method | Race? | Triage |
|---|-----------|--------|-------|--------|
| 1 | `PickingorderBusinessService.java:529` | `confirmPick` | **YES** — unlocked sibling read after CO lock at :499; primary bug site | **IN-SCOPE — Fix B** |
| 2 | `PickingorderBusinessService.java:223` | `finishPickingOrder` | **YES** — unlocked sibling read; CO already locked at :176 via `findByIdForUpdate` bulk pre-fetch | **IN-SCOPE — Fix C** |
| 3 | `PickingorderBusinessService.java:346` | `cleanUpCancelledOrder` | **DEFERRED** — see rationale below | deferred |
| 4 | `CustomerorderPositionRepository.java:20` | `findByOrderId` — no locked variant exists | n/a — missing method | **IN-SCOPE — Fix A** |
| 5 | `PickingorderBusinessServiceUnitTest.java` | 17 stubs for `findByOrderId` covering `confirmPick` / `finishPickingOrder` paths | n/a — break on rename | **IN-SCOPE — stub migration** |

**`:346` deferral rationale:** `cleanUpCancelledOrder` is called from `finishPickingOrder:215-217` only
when `markedforcancellation==true`. The CO is already pessimistically locked at line 176 (the bulk
pre-fetch `findByIdForUpdate` loop). Two concurrent calls converging here would both set COP rows
to `CANCELED (800)` — an idempotent terminal transition guarded by `@Version` on
`CustomerorderPosition` (inherited from `AbstractBaseEntity`). `updateStateByOrderIds` already
has the guard `cp.state != 800` (`CustomerorderPositionRepository.java:66`). The race window is
narrow (flag-gated, low frequency) and the outcome is correct (both writers agree on CANCELED).
**Reviewer must verify:** no path allows a concurrent `confirmPick` on a CO that is already
flagged-for-cancellation but not yet CANCELED — if such a window exists, promote `:346` to in-scope.

**18 additional sites** across 11 other service classes are deferred to follow-up tickets. See §11.

---

## 1. Problem Statement

A `Customerorder` (CO) remains stuck at `state = STARTED (500)` after all of its
`CustomerorderPosition` (COP) rows have been individually confirmed to `state = PICKED (600)`.
The last-pick promotion to `PICKED (600)` never fires. The order is invisible to downstream
packing, palletizing, and BOL flows until a DBA manually patches the CO state.

State codes (confirmed from `WmsConstants.java`):

| Constant | Value |
|----------|-------|
| `STARTED` | 500 |
| `PENDING` | 550 |
| `PICKED` | 600 |
| `FINISHED` | 700 |
| `CANCELED` | 800 |

**Reproduction:**

1. CO `O` has two open positions `P1`, `P2`, both at `STARTED (500)`.
2. Two concurrent `confirmPick` calls: T1 confirming P1's last unit, T2 confirming P2's last unit.
3. Both reach line 529 and call `findByOrderId` — no row lock on sibling COP rows.
4. T1 reads `[P1=STARTED, P2=STARTED]` (T2's write uncommitted). `hasAllPicked = false`. T1 commits; CO stays at STARTED.
5. T2 reads `[P1=STARTED, P2=STARTED]` or `[P1=PICKED, P2=STARTED]` depending on timing. `hasAllPicked = false`. T2 commits; CO stays at STARTED.
6. Both COP rows end at `PICKED`, but CO is stuck at `STARTED`.

---

## 2. Root Cause Analysis

### Bug 1 — Unlocked sibling read in `confirmPick` (`PickingorderBusinessService.java:529`)

```java
// :499 — CO is locked ✓
Optional<Customerorder> customerOrderOpt =
    customerorderRepository.findByIdForUpdate(customerOrder.getId());
// ...
// :525 — gate: only enter on last-pick decision path
if (customerOrderPosition.getState() >= WmsConstants.State.PENDING
        && customerOrder.getState() < WmsConstants.State.PICKED) {
    // :529 — sibling read WITHOUT lock ✗
    List<CustomerorderPosition> allCoPositions =
        customerorderPositionRepository.findByOrderId(customerOrder.getId());
```

The `Customerorder` row lock at line 499 serializes writes to the CO row across transactions.
It does NOT make sibling `CustomerorderPosition` reads consistent. Under PostgreSQL `READ COMMITTED`
(the wms2-api default), each `SELECT` statement sees a snapshot as of its start time. T1's
`findByOrderId` at line 529 returns data from before T2 commits — even though T2's COP write
is in flight.

### Bug 2 — Same pattern in `finishPickingOrder` (`PickingorderBusinessService.java:223`)

```java
// :176 — CO locked ✓ (bulk pre-fetch)
customerorderRepository.findByIdForUpdate(coId).ifPresent(co -> coMap.put(co.getId(), co));
// ...
// :222 — gate: CO not yet PICKED
if (customerOrder.getState() < WmsConstants.State.PICKED) {
    // :223 — sibling read WITHOUT lock ✗
    List<CustomerorderPosition> allCoPositions =
        customerorderPositionRepository.findByOrderId(customerOrder.getId());
```

Same unlocked sibling read on the last-pick decision path. CO is locked at line 176 via the
bulk `findByIdForUpdate` pre-fetch, so the CO → COP lock order is already correct — only the
sibling read needs to be upgraded to `FOR UPDATE`.

### Affected Locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `repo/jpa/CustomerorderPositionRepository.java` | 20 | `findByOrderId` — add locked variant |
| 2 | `service/PickingorderBusinessService.java` | 529 | `confirmPick` — unlocked sibling read |
| 3 | `service/PickingorderBusinessService.java` | 223 | `finishPickingOrder` — unlocked sibling read |
| 4 | `test/.../PickingorderBusinessServiceUnitTest.java` | various | 17 stubs to migrate |

---

## 3. Design / Proposed Fix

### 3.1 Fix A — Add `findByOrderIdForUpdate` to `CustomerorderPositionRepository`

**Problem:** No locked variant of the sibling-fetch exists.

**Solution:** Add after line 20, mirroring `CustomerorderRepository.findByIdForUpdate` (lines 25–27):

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT cp FROM CustomerorderPosition cp WHERE cp.orderId = :orderId ORDER BY cp.id")
List<CustomerorderPosition> findByOrderIdForUpdate(@Param("orderId") Long orderId);
```

Key choices:
- `@Lock(LockModeType.PESSIMISTIC_WRITE)` on a `@Query` method bypasses the Hibernate L1
  cache and issues `SELECT ... FOR UPDATE` on all matching rows. No `entityManager.refresh()`
  needed.
- JPQL entity-name syntax (`CustomerorderPosition`, not `customerorder_position`) — consistent
  with the existing locked finders in this repository.
- `ORDER BY cp.id` — ensures deterministic row-lock acquisition order across concurrent
  callers on the same order, preventing intra-table deadlock.
- Required new imports: `org.springframework.data.jpa.repository.Lock` and
  `jakarta.persistence.LockModeType`.

**Files changed:** `repo/jpa/CustomerorderPositionRepository.java`

---

### 3.2 Fix B — Substitute locked read in `confirmPick` (line 529)

**Problem:** `findByOrderId` at line 529 reads sibling COPs without a row lock.

**Solution:**

```java
// Before (line 529):
List<CustomerorderPosition> allCoPositions =
    customerorderPositionRepository.findByOrderId(customerOrder.getId());

// After (line 529):
List<CustomerorderPosition> allCoPositions =
    customerorderPositionRepository.findByOrderIdForUpdate(customerOrder.getId());
```

No other changes in this method.

**Files changed:** `service/PickingorderBusinessService.java`

---

### 3.3 Fix C — Substitute locked read in `finishPickingOrder` (line 223)

**Problem:** `findByOrderId` at line 223 reads sibling COPs without a row lock.

**Solution:**

```java
// Before (line 223):
List<CustomerorderPosition> allCoPositions =
    customerorderPositionRepository.findByOrderId(customerOrder.getId());

// After (line 223):
List<CustomerorderPosition> allCoPositions =
    customerorderPositionRepository.findByOrderIdForUpdate(customerOrder.getId());
```

No pre-lock addition needed — the CO is already locked at line 176 via the bulk
`findByIdForUpdate` pre-fetch. The lock order is already CO (176) → COP siblings (223).

**Files changed:** `service/PickingorderBusinessService.java`

---

### 3.4 Why Pessimistic, Not Optimistic, Locking

`Customerorder` has a `@Version` column (inherited from `AbstractBaseEntity:34`). Why not
rely on it?

`ObjectOptimisticLockingFailureException` fires when two transactions write the **same row** at
version `N`. In this bug, both T1 and T2 may write the CO row — but the bug is that they compute
the wrong decision **before** writing. `hasAllPicked` is computed from sibling COP rows in a
different table. Both transactions read stale sibling data, conclude "not last pick", and skip
the CO state write entirely. No version conflict fires because neither transaction writes CO.

The race is **read-then-decide on sibling rows**, not a **write-conflict on the same row**.
Pessimistic lock on the sibling read is the correct primitive: the second transaction blocks
at `findByOrderIdForUpdate` until the first commits, then re-reads the now-committed sibling
state and correctly decides it is the last pick (or not).

Optimistic locking on `CustomerorderPosition` would also not help: T1 writes `P1`, T2 writes
`P2` — different rows, different versions, no conflict.

---

### 3.5 Lock Ordering & Throughput

**`confirmPick` lock chain (after fix):**

```
CO pre-lock  (line 405)  findByIdForUpdate(coId)       ← CO lock #1 (cancel-race guard)
PO lock      (line 412)  findByIdForUpdate(poId)        ← PO lock
position save (line 461) save(customerOrderPosition)    ← COP self, implicit via @Version
CO re-lock   (line 499)  findByIdForUpdate(coId)        ← CO lock #2 (promotion gate)
COP siblings (line 529)  findByOrderIdForUpdate(coId)   ← NEW: COP sibling FOR UPDATE
```

**`finishPickingOrder` lock chain (after fix):**

```
CO lock      (line 176)  findByIdForUpdate(coId)        ← CO lock (bulk pre-fetch)
COP siblings (line 223)  findByOrderIdForUpdate(coId)   ← NEW: COP sibling FOR UPDATE
CO state write (line 241) setState(PICKED)              ← CO write (flush on commit)
```

Both methods acquire CO before COP. No lock inversion; no deadlock cycle possible.

**Throughput:** The gate at line 525 (`COP.state >= PENDING && CO.state < PICKED`) means the
new lock fires only during the final last-pick decision window. Concurrent picks on non-terminal
positions skip this block entirely. The `finishPickingOrder` gate at line 222 (`CO.state < PICKED`)
has no per-position predicate, so the lock fires on every `finishPickingOrder` call against
a non-promoted order — but this call is far less frequent than individual `confirmPick` calls.

The `ORDER BY cp.id` in the JPQL ensures two concurrent `findByOrderIdForUpdate` callers on
the same order acquire sibling row locks in the same order (ascending id), preventing deadlock.

---

## 4. V1/V2 Applicability

This plan targets **v2 only**. If v1 `PickingorderBusinessService` exhibits the same pattern,
file a paired plan under `sbdocs/1-Projects/wms1/plan/` with the matching base name.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No schema change. No migration. | N/A | Pure code change |
| 2 | **Feature flags / system properties** | None required | N/A | |
| 3 | **Config / env changes** | None required | N/A | |
| 4 | **Deploy-order dependencies** | None — single JAR deploy | N/A | |
| 5 | **Data migration** | None | N/A | |
| 6 | **External systems** | None | N/A | |
| 7 | **Access / permissions** | None | N/A | |
| 8 | **Monitoring / alerts** | Post-deploy: query for stuck orders (`customerorder.state=500` where all COPs `state>=600`). Rate should drop to zero. See §10. | Implementer | |

### 5.2 Implementation Checklist

- [ ] Add `findByOrderIdForUpdate` to `CustomerorderPositionRepository` (Fix A) with `@Lock`, `@Query` (JPQL), `ORDER BY cp.id`, and required imports.
- [ ] Substitute `findByOrderId` → `findByOrderIdForUpdate` at `PickingorderBusinessService.java:529` (Fix B).
- [ ] Substitute `findByOrderId` → `findByOrderIdForUpdate` at `PickingorderBusinessService.java:223` (Fix C).
- [ ] Migrate all 17 `findByOrderId` stubs in `PickingorderBusinessServiceUnitTest.java` that cover `confirmPick` / `finishPickingOrder` paths to `findByOrderIdForUpdate`. (The 4 stubs in `CleanUp*` test classes stay on `findByOrderId`.)
- [ ] Add AC3/AC4 `verify(repo)` assertions to the corresponding unit test methods.
- [ ] Write `PickingorderBusinessServiceConcurrencyIT.java` (AC1 — Testcontainers PostgreSQL).
- [ ] Run `mvn test -Dtest=PickingorderBusinessServiceUnitTest` — must be green.
- [ ] Run `mvn verify` (Testcontainers) — must be green.
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2223-confirmPick-last-pick-detection-race.sh` — all PASS.
- [ ] Code review completed.
- [ ] Update plan: flip `status: draft → implemented`, record commit SHA, `mvn test`/`mvn verify` results, PR link.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Concurrent last-pick on same order | 2 threads, CountDownLatch start gate, each calls `confirmPick` on last unit of one of two positions | CO state = PICKED(600) after both threads complete; order not stuck at STARTED(500) |
| `confirmPick` calls locked variant | Unit test exercises last-pick branch | `verify(repo, times(1)).findByOrderIdForUpdate(anyLong())` passes; `verify(repo, never()).findByOrderId(anyLong())` passes |
| `finishPickingOrder` calls locked variant | Unit test exercises promotion branch | Same verify pattern passes |
| All 17 migrated stubs compile and pass | `mvn test -Dtest=PickingorderBusinessServiceUnitTest` | BUILD SUCCESS, 0 failures |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `PickingorderBusinessServiceConcurrencyIT` | `confirmPick_shouldPromoteOrderToPicked_whenConcurrentLastPickRaces` | CO = PICKED after two concurrent confirmPick calls on last two positions (Testcontainers) |
| `PickingorderBusinessServiceUnitTest` | existing `confirmPick` last-pick tests | Migrated stubs + `verify(findByOrderIdForUpdate)` + `never(findByOrderId)` |
| `PickingorderBusinessServiceUnitTest` | existing `finishPickingOrder` promotion tests | Same verify pattern |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Concurrent last-pick on a 2-position order | staging | 1. Create order with 2 positions. 2. Two operators confirm last unit of each position simultaneously via mobile UI. 3. Check order state after both confirm. | Order state = PICKED (600) within seconds | |
| Single picker finishing an order | staging | 1. Pick all positions normally. 2. Confirm last position. | Order advances to PICKED normally | |
| SQL stuck-order check (post-deploy 24h) | staging DB | `SELECT co.id FROM customerorder co WHERE co.state = 500 AND NOT EXISTS (SELECT 1 FROM customerorderposition cp WHERE cp.order_id = co.id AND cp.state < 600)` | Zero rows (no new stuck orders) | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=PickingorderBusinessServiceUnitTest` | | |
| `mvn verify` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2223-confirmPick-last-pick-detection-race.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| H2-based variant of the concurrency test | H2 does not implement PostgreSQL `SELECT ... FOR UPDATE` semantics; the test would pass regardless of whether the fix is in place |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce per-replica in-memory state? | No | Pure DB-layer change |
| 2 | **Connection pool math** | Change per-request DB connection usage? | No | Same connection per transaction; `FOR UPDATE` adds a row lock, not a new connection |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` job? | No | |
| 4 | **Long transactions** | Hold a DB transaction across additional repository calls? | Yes | The new `FOR UPDATE` is acquired and released within the existing `confirmPick` transaction boundary. Lock held for the duration of the last-pick decision block only — no external I/O between lock and commit on this path. Acceptable. |
| 5 | **Request affinity** | Assume same-replica follow-up? | No | |
| 6 | **Retry / idempotency** | Break if a replica dies mid-op? | No | `findByOrderIdForUpdate` inside `@Transactional(tenantTransactionManager)` — lock released on rollback |
| 7 | **Tenant context** | Use `TenantContext` across async boundaries? | No | No async introduced |
| 8 | **Distributed lock correctness** | Add pessimistic lock across replicas? | Yes | `findByIdForUpdate` / `findByOrderIdForUpdate` are inside `@Transactional(value="tenantTransactionManager")` — PostgreSQL row locks coordinate across all replicas via the shared tenant DB. Correct. |
| 9 | **Cache invalidation** | Write to a cached entity? | No | `CustomerorderPosition` is not Caffeine-cached in `CacheConfig` |
| 10 | **External notifications** | Send HTTP to OMS inside a transaction? | No | OMS notification in `finishPickingOrder:247-260` is already deferred to after-commit via `TransactionSynchronizationManager` |

### Evidence

| Concern # | Verified | Reference |
|-----------|----------|-----------|
| 4 | `confirmPick` is `@Transactional(value="tenantTransactionManager")` at line 376. The `FOR UPDATE` block at :529 runs inside it with no external I/O before commit. | `PickingorderBusinessService.java:376` |
| 8 | `CustomerorderRepository.findByIdForUpdate` pattern (existing) confirmed at `CustomerorderRepository.java:25-27`. New `findByOrderIdForUpdate` uses the same mechanism. | `CustomerorderPositionRepository.java:20` (before fix) |

---

## 8. Notes

### 8.1 Acceptance Criteria (for wms-tdd-gate)

**AC1 — Concurrency integration test (Testcontainers + `CountDownLatch`)**

New test class `PickingorderBusinessServiceConcurrencyIT.java` boots a real PostgreSQL container,
seeds one CO with two positions both in STARTED state, and uses two threads + a start-gate
`CountDownLatch` to force both `confirmPick` calls into the last-pick window simultaneously.
After both threads `join()`, reload CO in a fresh transaction and assert:

- CO `state == CustomerorderState.PICKED (600)`
- CO `state != CustomerorderState.STARTED (500)` (the bug's symptom)

PostgreSQL (not H2) required for real row-lock semantics.

**AC2 — No double-promote**

Within AC1, assert the CO state is exactly `PICKED (600)` — if double-promotion somehow occurred,
an `ObjectOptimisticLockingFailureException` would have been thrown (CO has `@Version`). The test
passes only if exactly one promotion committed without exception.

**AC3 — `confirmPick` calls the locked variant**

```java
verify(customerorderPositionRepository, times(1)).findByOrderIdForUpdate(anyLong());
verify(customerorderPositionRepository, never()).findByOrderId(anyLong());
```

Applied to unit tests exercising the last-pick branch of `confirmPick`.

**AC4 — `finishPickingOrder` calls the locked variant**

Same `verify` pattern applied to unit tests exercising the promotion branch of `finishPickingOrder`.

**AC5 — All 17 migrated stubs compile and pass**

`mvn test -Dtest=PickingorderBusinessServiceUnitTest` exits 0 with 0 failures. The 4 stubs in
`CleanUp*` classes remain on `findByOrderId`.

**AC6 — Full `mvn test` passes without regressions**

`mvn test` from `v2/wms2-api/` exits 0.

### 8.2 Regression Chain

Commit `da64cc03` — "port v1 Order_241019 lock-ordering fix" — introduced the CO pre-lock at
line 405 to guard against a cancel race. This established the CO→PO lock ordering invariant that
this fix extends. The unlocked COP sibling read at line 529 was already present in that commit;
`da64cc03` did not touch the sibling-read logic.

### 8.3 Known Uncovered Call Sites (§11 follow-up)

18 additional `findByOrderId` call sites across 11 service classes share the same pattern and
are deferred to follow-up tickets. See §11 below.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2223-confirmPick-last-pick-detection-race.sh`

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 3 files, 4 code changes, 1 new test class |
| **Pre-draft step** | done (ralplan) | Plan already consensus-approved |
| **Plan-review step** | done | Architect + Critic passed |
| **Implementation shape** | `executor` | Mechanical substitutions + one new test class; well-bounded |
| **Verification step** | verify-script + verifier | Mandatory |
| **Code-review step** | `code-reviewer` | Concurrency fix — second pair of eyes warranted |
| **Commit step** | `git-master` | Logical single commit |

---

## §11 Known Uncovered Call Sites (Follow-up)

The following 18 `findByOrderId` call sites are **not** modified by this plan. Triage each in
a separate follow-up ticket. Read-only sites (marked) need only a `wontfix` triage record.

| File | Lines | Classification |
|------|-------|----------------|
| `CustomerorderService.java` | :316, :330, :383, :426, :616 | Decision-path — needs triage |
| `CustomerorderBatchService.java` | :182, :247, :285, :387, :403, :477, :1125 | Decision-path — needs triage |
| `TransferOrderService.java` | :156, :200, :249, :406 | Decision-path — needs triage |
| `ManageOrderService.java` | :79 | Needs triage |
| `UtilRestController.java` | :965 | Needs triage |
| `MobileTruckLoadingService.java` | :286 | Needs triage |
| `ReleaseOrderJobService.java` | :130 | Needs triage |
| `MobileTransferOrderService.java` | :167 | Needs triage |
| `MobileInfoService.java` | :253 | **Read-only** — no race risk |
| `ParcelMonitorViewService.java` | :391 | **Read-only** — no race risk |
| `MobilePickingService.java` | :1015 | Needs triage |

**Recommendation:** open a parent ticket "Audit `CustomerorderPositionRepository.findByOrderId`
call sites for last-pick / last-action races" and spawn child tickets per file group. The two
read-only sites are pre-triaged as no-race.

---

## §10 Rollout & Verification

**Pre-deploy DB check** (record count before merge):

```sql
-- Stuck orders: state=STARTED but every position already PICKED
SELECT co.id, co.state AS co_state, count(*) AS total_positions
FROM customerorder co
JOIN customerorderposition cp ON cp.order_id = co.id
WHERE co.state = 500
GROUP BY co.id, co.state
HAVING count(*) = count(*) FILTER (WHERE cp.state >= 600);
```

**Deploy:** Single-JAR redeploy of `wms2-api`. No schema migration, no data migration,
no feature flag.

**Rollback:** Redeploy the previous JAR artifact. No data rollback needed — there is no
data migration. Orders correctly promoted post-deploy stay promoted; pre-deploy stuck
orders remain stuck (manual SQL correction required regardless).

**Post-deploy (24h after):** Re-run the query above. Rate of new stuck orders should
be zero. Monitor `wms2.customerorder.state.transitions{from=500,to=600}` Micrometer
metric for normal promotion activity.
