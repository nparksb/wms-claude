---
title: "Activate Transfer Order — Two-Transaction Split Strands Orders at 505-with-Lane"
ticket: ""
ticket_url: ""
type: bugfix
priority: high
status: implemented
project:
  - wms2
version: v2
requester: nam.park@siteboss.net
created: 2026-06-29
updated: 2026-06-29
db_verified: true
related:
  - "[[260629-transfer-lane-leak-on-cancel]]"
  - "[[wms2-transfer-order-workflow]]"
  - "[[260521-customerorderbatchservice-runclubline-self-invocation-tx-fix]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
tags:
  - plan
  - wms2
  - transfer-order
  - transaction
  - atomicity
---

# Activate Transfer Order — Two-Transaction Split Strands Orders at 505-with-Lane

**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high
**Status:** draft (pending approval)
**Date:** 2026-06-29
**Plan ID:** `260629-activate-transfer-atomicity`

> **Root-cause sibling of** [[260629-transfer-lane-leak-on-cancel]] (H2). That plan fixed lane **release** on cancel/unlink. **This** plan fixes the activate **atomicity** so 505-with-lane orders are never manufactured in the first place. The two plans are complementary and non-overlapping: lane release is owned by the sibling and is **not** re-touched here.

---

## 0. Affected Sites

| # | Site | File:line | In scope | Fix |
|---|------|-----------|----------|-----|
| 1 | `TransfersController.activateTransferOrder` — two sequential service calls | `TransfersController.java:159` + `:161` | **Yes** | F1 (controller calls one orchestration method) |
| 2 | `TransferOrderService.activateTransferOrder(lane, co)` | `TransferOrderService.java:116-129` | **Yes — keep, also reused** | F2 (new orchestration method built on its logic) |
| 3 | `TransferOrderService.assignTransferLaneToTransferOrder(lane, co)` | `TransferOrderService.java:85-101` | **Yes — keep (other callers)** | not modified |
| 4 | `TransfersController.reassignTransferLane` → `assignTransferLaneToTransferOrder` | `TransfersController.java:109` | No — single call, already atomic | — |
| 5 | `TransfersController.assignTransferLane` → `assignTransferLaneToTransferOrder` | `TransfersController.java:187` | No — single call, already atomic | — |
| 6 | `LocationRepository.getAvailableTransferLanesForUpdate` (the gate / pessimistic lock) | `LocationRepository.java:72` | No — correct as-is | — |
| 7 | Stranded-order recovery (operator unlink) | `TransfersController.unlinkTransferLane` `:124-145` | No — owned by sibling plan | cross-ref |

**Caller audit (grep, 2026-06-29):**
- `transferOrderService.activateTransferOrder(` → **1 caller**: `TransfersController.java:159` only.
- `transferOrderService.assignTransferLaneToTransferOrder(` → **3 callers**: `TransfersController.java:109` (`reassignTransferLane`), `:161` (`activateTransferOrder` — the bug site), `:187` (`assignTransferLane`).

So `assignTransferLaneToTransferOrder` has two **other** legitimate single-call callers and **must be kept**. `activateTransferOrder` has exactly one caller — the bug site — so it can be kept-and-reused (preferred) without risk to other paths.

---

## 1. Problem Statement

**Defect:** `TransfersController.activateTransferOrder` (GET `/v3/transfers/activateTransferOrder/{customerOrderId}/{locationId}`, `:147-174`) drives **two separately-`@Transactional`** `TransferOrderService` methods in sequence:

1. `transferOrderService.activateTransferOrder(lane, co)` (`:159`) — TX1: sets `transferlaneId = lane` + `state = CUSTOMER_ORDER_ACTIVATED (505)`, commits in its own tenant transaction.
2. `transferOrderService.assignTransferLaneToTransferOrder(lane, co)` (`:161`) — TX2: sets `transferlaneId = lane` (again) + `state = CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED (510)`, commits in its **own separate** tenant transaction.

The controller method is **non-transactional**, so these are **two independent transactions**. If TX2 throws (e.g. lane lost the availability race between the two locks → `BusinessException`) or the user/process abandons after TX1 commits, the order is **committed at state 505 with a lane already assigned**. Per the sibling plan's gate analysis, `getAvailableTransferLanes` excludes any lane held by an order with `state < FINISHED(700)`, so a 505-with-lane order **leaks its lane forever** — the exact stranded state observed in 5 of the 6 leaked orders in [[260629-transfer-lane-leak-on-cancel]] §1.

### DB Verification (`db_verified: true`)

**Confirmed on `wms2-wineco-dev`, 2026-06-29** (MCP reachable on re-run):

```sql
SELECT count(*) FILTER (WHERE state = 505 AND transferlane_id IS NOT NULL) AS stranded_505_with_lane,
       count(*) FILTER (WHERE state = 510 AND transferlane_id IS NOT NULL) AS active_510_with_lane,
       count(*) FILTER (WHERE state < 700 AND transferlane_id IS NOT NULL) AS all_below_finished_with_lane
FROM customerorder WHERE fulfillmenttype = 'Transfer';
-- → stranded_505_with_lane = 5 | active_510_with_lane = 1 | all_below_finished_with_lane = 6
```

→ **5 transfer orders are stranded at state 505 with a lane still assigned** — the exact bad state this defect manufactures. This is despite the sibling-plan session having cleared 5 such orders earlier the same day (`UPDATE … SET transferlane_id = NULL`), so the bad state has **re-accumulated** (consistent with activate testing after the lanes were freed, or any partial/abandoned activate). This is direct, live evidence that the two-transaction split keeps producing 505-with-lane orders — i.e. **recurrence prevention is the point of this plan**, and a one-time data cleanup (sibling plan) does not address the source. (The 1 order at 510-with-lane is the legitimately in-progress one intentionally left during the sibling session.)

**Note on remediation overlap:** the 5 newly-stranded 505 orders can be freed via the sibling plan's operator recovery (`GET /v3/transfers/unlinkTransferLane/{id}`) once PR #56 deploys; this plan stops them being created in the first place.

---

## 2. Root Cause Analysis

### 2.1 Two-transaction split (PRIMARY, confirmed, HIGH)

**Evidence:** `TransferOrderService.activateTransferOrder` (`:116`) and `assignTransferLaneToTransferOrder` (`:85`) are **each** annotated `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`. The controller (`:147-174`) calls both through the Spring proxy in sequence with **no enclosing transaction**. Spring's default propagation is `REQUIRED`; because the controller holds no transaction, **each call starts and commits its own** tenant transaction. TX1's `state=505 + lane` write is durable the instant `activateTransferOrder` returns — before TX2 even begins.

Failure windows that strand the order at 505-with-lane:
- **TX2 business failure** — `assignTransferLaneToTransferOrder` re-acquires `getAvailableTransferLanesForUpdate` (`:89`) and throws `BusinessException("transfer lane is not available anymore...")` (`:92`) if a concurrent activation grabbed the lane between TX1 and TX2. TX2 rolls back; **TX1 stays committed**.
- **TX2 infra failure** — optimistic-lock (`@Version` on `Customerorder`), pool exhaustion, pod eviction, etc. between the two commits.
- **Operator/process abandonment** — request aborted, client timeout, or app restart after TX1 commit and before TX2.

In every case the order persists at `505` with `transferlane_id` set → leaked lane (sibling-plan gate).

### 2.2 Redundant double-write (CONTRIBUTING)

Even on the happy path the two methods **both** set `transferlaneId` and **both** call `customerorderRepository.save(co)` — two flushes, two `@Version` increments — to land a single net state (`510` with `lane`). The intermediate `505` persistence has no consumer (see §10 OQ-1). Collapsing to one transaction also collapses the redundant write.

### 2.3 Why this is the upstream cause (cross-ref sibling §2.3)

The sibling plan classified this as H2 / CONTRIBUTING / out-of-scope and explicitly deferred it here. The sibling's lane-release fixes (cancel/unlink) are **recovery**; this plan is **prevention**. With both landed, a 505-with-lane order can neither be manufactured (this plan) nor leak permanently if one ever is (sibling).

---

## 3. Regression Chain

N/A — longstanding design (two endpoints folded into one controller action), not a regression from a prior fix. The workflow doc has flagged it as a known landmine since at least the §10 "Two transactions to activate" entry.

---

## 4. Architecture Overview

```
BEFORE (two transactions, non-atomic)
─────────────────────────────────────
TransfersController.activateTransferOrder  (NO @Transactional)
   │
   ├─► transferOrderService.activateTransferOrder(lane, co)      [TX1 commit]
   │        getAvailableTransferLanesForUpdate (PESSIMISTIC_WRITE)
   │        co.transferlaneId = lane ; co.state = 505 ; save()   ← DURABLE HERE
   │
   │   ╳ [TX2 throws / abandon]  →  co committed at 505-with-lane  →  LANE LEAKED
   │
   └─► transferOrderService.assignTransferLaneToTransferOrder(lane, co)  [TX2 commit]
            getAvailableTransferLanesForUpdate (PESSIMISTIC_WRITE)  ← may now fail
            co.transferlaneId = lane ; co.state = 510 ; save()

AFTER (one transaction, atomic)
───────────────────────────────
TransfersController.activateTransferOrder  (NO @Transactional)
   │
   └─► transferOrderService.activateAndAssignTransferLane(lane, co)   [SINGLE TX]
            getAvailableTransferLanesForUpdate (PESSIMISTIC_WRITE)   ← one lock check
            co.transferlaneId = lane ; co.state = 510 ; save()       ← one flush
        │
        ╳ [any failure]  →  whole tx rolls back  →  co stays at pre-activate state, NO lane
```

### Key Files

| File | Role |
|------|------|
| `controller/TransfersController.java` | `activateTransferOrder` (`:147-174`) — change the body to one orchestration call (F1) |
| `service/TransferOrderService.java` | `activateTransferOrder` (`:116-129`), `assignTransferLaneToTransferOrder` (`:85-101`) — add orchestration method `activateAndAssignTransferLane` (F2); keep both existing methods |
| `repo/jpa/LocationRepository.java` | `getAvailableTransferLanesForUpdate` (`:72`) `@Lock(PESSIMISTIC_WRITE)` — the gate (unchanged) |

---

## 5. Fix Design

### 5.1 Chosen: Option 1 — single `@Transactional` orchestration method, inline the writes

Add **one** new method to `TransferOrderService`:

```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void activateAndAssignTransferLane(Location transferLane, Customerorder customerOrder) throws BusinessException {
    LOG.debug("start with customerOrder={} and transferLane={}", customerOrder, transferLane);

    // Single availability check under PESSIMISTIC_WRITE — the lane must still be free.
    List<Location> availableTransferLanes =
        locationRepository.getAvailableTransferLanesForUpdate(customerOrder.getId(), WmsConstants.State.FINISHED);

    if (availableTransferLanes.stream().noneMatch(lane -> lane.getId().equals(transferLane.getId()))) {
        throw new BusinessException("transfer lane is not available anymore. refresh and try again.");
    }

    // Activate + assign atomically: land the net state (510 with lane) in ONE flush.
    // The intermediate CUSTOMER_ORDER_ACTIVATED(505) is not separately persisted — no consumer
    // observes the transient 505 (see plan §10 OQ-1). This prevents the two-transaction split
    // that strands orders at 505-with-lane (260629-activate-transfer-atomicity).
    customerOrder.setTransferlaneId(transferLane.getId());
    customerOrder.setState(CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED);
    customerorderRepository.save(customerOrder);

    LOG.debug("end with customerOrder={} and transferLane={} (state=510)", customerOrder, transferLane);
}
```

Controller (`TransfersController.activateTransferOrder`) **Before** (`:159-161`):

```java
            // activate transfer order first
            transferOrderService.activateTransferOrder(availableTransferLane, currentTransferOrder);
            // then assign transfer lane selected
            transferOrderService.assignTransferLaneToTransferOrder(availableTransferLane, currentTransferOrder);
```

**After:**

```java
            // Activate + assign the lane in ONE tenant transaction so the order can never be
            // stranded at state 505-with-lane (260629-activate-transfer-atomicity).
            transferOrderService.activateAndAssignTransferLane(availableTransferLane, currentTransferOrder);
```

**Why inline rather than `self.activateTransferOrder()` + `self.assignTransferLaneToTransferOrder()`:** see §5.4 self-invocation analysis. Inlining the two field writes (`setTransferlaneId` + `setState(510)`) and a **single** `save()` is the simplest correct form — one lock check, one flush, one `@Version` increment, no proxy machinery, and no double-availability-check race window.

**Keep both existing methods unchanged.** `assignTransferLaneToTransferOrder` retains 2 other callers (`reassignTransferLane`, `assignTransferLane`). `activateTransferOrder` has only the bug-site caller, but is left in place (harmless, and avoids a wider diff / preserves any future single-step activate). Removing it is a separate cleanup, not part of this fix.

**Relapse-vector guard (Architect rec, in scope).** Because `activateTransferOrder` is retained but now has no production caller, add a one-line Javadoc/comment on it warning it must **never** be paired with `assignTransferLaneToTransferOrder` in a non-transactional caller (that re-creates the two-TX split this plan removed); point new activate paths at `activateAndAssignTransferLane`. The verify script's N3 self-invocation check cannot catch a future controller re-pairing the two, so this comment documents the constraint at the call-temptation site.

### 5.2 Rejected: Option 2 — keep two methods, wrap them in a self-proxied orchestration

Add `activateAndAssignTransferLane` that internally calls `self.activateTransferOrder(...)` then `self.assignTransferLaneToTransferOrder(...)` via a `@Lazy @Autowired TransferOrderService self` proxy (the canonical 260521 pattern).

**Rejected because:** heavier and strictly worse here. It would (a) run **two** `getAvailableTransferLanesForUpdate` pessimistic-lock checks and **two** `save()` flushes inside one tx for no benefit; (b) introduce a self-injection field + proxy hop where none is needed; (c) still persist the transient 505 mid-transaction (one extra `@Version` bump). The 260521 self-injection pattern exists to make **already-correctly-annotated** phase methods actually transactional when a non-transactional orchestrator (`runClubLine`) must keep Phase-4 OMS HTTP outside the tx. Here the orchestrator itself becomes transactional and there is no OMS-HTTP-outside-tx constraint, so the self-proxy adds risk with zero upside.

### 5.3 Rejected: Option 3 — make the controller method `@Transactional`

Annotating `TransfersController.activateTransferOrder` would make both inner calls join one tx (the inner `@Transactional` would become `REQUIRED`-join). **Rejected because:** the project convention keeps transactions in the service layer, not controllers (no `@Transactional` controller exists in this codebase); a transactional controller also keeps the tenant connection open across the response-serialization tail. Service-layer orchestration is the established pattern (`ReceivingService`, `MobilePickingService`).

### 5.4 Self-invocation / CGLIB-proxy analysis (per v2/wms2-api CLAUDE.md + osiv map)

The CLAUDE.md caveat: a `@Transactional` method calling another `@Transactional` method on `this` **bypasses the CGLIB proxy** — the inner annotation is inert (the 260521 `runClubLine` bug). For the **chosen** Option 1 this is a non-issue **by construction**: the new method does **not** call `this.activateTransferOrder(...)` or `this.assignTransferLaneToTransferOrder(...)` at all — it **inlines** the two field writes + one `save()`. There is no inner `@Transactional` whose proxy could be bypassed, no double-save, and no reliance on the inner annotations.

(If a future maintainer chooses to delegate instead of inline, they must route via a `@Lazy @Autowired` self proxy — but Option 1 deliberately avoids needing one.)

### 5.5 End-state decision: persist 510 directly, skip transient 505

The orchestration method sets `state = 510` directly and never persists `505`. Justification (OQ-1): grep shows the transfer mobile flow queries `findByState(CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED)` = **510** (`MobileTransferOrderService.updateOrderList`, per workflow §9), i.e. consumers look for 510, not 505. The 505 state in the old two-call flow was only ever a sub-second intermediate between TX1 and TX2 that no reader was designed to observe. No OMS callback fires on activate (workflow §7 — OMS callbacks are on run/finish, not activate). **No consumer depends on observing 505 during activation.** See §10 OQ-1 for the residual question to confirm with the requester.

---

## 6. File Change Summary

| # | File | Method | Change | Fix |
|---|------|--------|--------|-----|
| 1 | `service/TransferOrderService.java` | new `activateAndAssignTransferLane(Location, Customerorder)` | Add single `@Transactional(tenantTransactionManager, rollbackFor=...)` method: one lock check, set lane + state 510, one `save()` | F2 |
| 2 | `controller/TransfersController.java` | `activateTransferOrder` (`:159-161`) | Replace the two sequential service calls with one `activateAndAssignTransferLane(...)` call | F1 |
| 3 | `service/TransferOrderService.java` | `activateTransferOrder` (`:116`) | Add a one-line warning comment (relapse-vector guard, §5.1); logic unchanged | F1 |
| 3b | `service/TransferOrderService.java` | `assignTransferLaneToTransferOrder` (`:85`) | **Unchanged** (kept for other callers) | — |
| 4 | `src/test/.../TransferOrderServiceUnitTest` | new tests | Atomicity unit tests (see §8) | F2 |
| 5 | `src/test/.../TransfersControllerUnitTest` | new test | Controller delegates to the orchestration method only (see §8) | F1 |

---

## 7. Prerequisites & Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|---|---|---|
| 1 | **Database state** | No schema change; no Flyway migration | Pure transaction-boundary refactor |
| 2 | **Feature flags / sysprops** | N/A | No toggle gates this fix |
| 3 | **Config / env** | N/A | No properties change |
| 4 | **Deploy-order** | None — wms2-api standalone | No OMS/UI co-deploy; the UI continues to call the same endpoint with the same response |
| 5 | **Data migration** | None. Already-stranded 505-with-lane orders are recovered by the **sibling plan's** operator unlink (`GET /v3/transfers/unlinkTransferLane/{id}`) — no separate migration here. | Cross-ref [[260629-transfer-lane-leak-on-cancel]] §7 runbook |
| 6 | **External systems** | N/A | No OMS callback on activate (workflow §7) |
| 7 | **Access / permissions** | No new endpoint or role; the existing `/activateTransferOrder/{coId}/{locId}` URL and response are unchanged | UI unaffected |
| 8 | **Monitoring / alerts** | N/A | — |

### 7.2 Implementation Checklist (ordered atomic commits)

- [ ] **Commit 1 (F2):** add `TransferOrderService.activateAndAssignTransferLane(...)` (single `@Transactional` tenant TM, inline writes, one save) + unit tests.
- [ ] **Commit 2 (F1):** point `TransfersController.activateTransferOrder` at the new orchestration method; delete the two sequential calls + controller unit test.
- [ ] `mvn clean compile` (gate DI/compile drift, per project memory).
- [ ] `mvn test -Dtest=TransferOrderServiceUnitTest,TransfersControllerUnitTest` → 0 failures.
- [ ] `bash sbdocs/9-System/scripts/verify-260629-activate-transfer-atomicity.sh` → 0 fail.
- [ ] Re-run the §1 DB query when the MCP is reachable; record the live stranded count.

### 7.3 Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Rationale |
|---|---------|---------|-----------|
| 1 | Stateless services | **PASS** | `TransferOrderService` holds no request state; new method is a pure method |
| 2 | No in-JVM lane cache | **PASS** | Availability queried from DB every call; no static/`ConcurrentHashMap` |
| 3 | Assign uses pessimistic lock | **PASS** | One `getAvailableTransferLanesForUpdate` `@Lock(PESSIMISTIC_WRITE)` (`LocationRepository:72`); **one** check now instead of two, narrower lock window |
| 4 | Atomic state+lane write in tenant TX | **PASS (key)** | Single `@Transactional("tenantTransactionManager")` — lane + state 510 commit or roll back together; `Customerorder` `@Version` optimistic lock guards concurrent writers |
| 5 | No scheduler added | **PASS** | No `@Scheduled`/job introduced |
| 6 | Tenant context | **PASS** | Set by `TenantFilter`; no `@Async` boundary crossed; same thread as today |
| 7 | Idempotency | **PASS** | GET endpoint; re-invoking on an order already at 510-with-this-lane re-passes the availability check (the order's own lane isn't excluded — gate excludes `co.id != :coId`) and re-writes the same net state (idempotent). A lane lost to a concurrent winner now fails the **single** check up front — cleaner than failing in TX2 after TX1 committed |
| 8 | Connection-pool math | **PASS** | One transaction instead of two → **fewer** pool acquisitions per activate, one flush instead of two |
| 9 | Optimistic-lock retry | **PASS** | One `@Version` increment instead of two; lock failure bubbles 409; **less** contention than before |
| 10 | Cleanup-job amplification | **N/A** | No scheduled job in this plan |

### 7.4 V2-only Constraints

| # | Constraint | Verdict | Rationale |
|---|------------|---------|-----------|
| 1 | Correct transaction manager | **PASS (key)** | New method uses `value = "tenantTransactionManager"` (NOT the `@Primary` landlord TM) — matches both source methods |
| 2 | `rollbackFor` present | **PASS** | `{BusinessException.class, FacadeException.class}` — identical to the two methods it replaces |
| 3 | OSIV-disabled safe | **PASS** | All work inside the new tx; `transferlaneId`/`state` are scalars; no lazy association touched outside the tx |
| 4 | `readOnly` | **N/A** | Write path |
| 5 | Caffeine eviction | **N/A** | `transferlaneId`/`state` not `@Cacheable` |
| 6 | `jakarta.*` imports | **PASS** | `org.springframework.transaction.annotation.Transactional` already imported (`TransferOrderService.java:11`); no new import needed |
| 7 | Constructor injection | **PASS** | No new dependency; reuses existing `locationRepository` + `customerorderRepository` fields |
| 8 | `BaseControllerTest` | **PASS** | Controller signature/route/response unchanged; existing `TransfersControllerUnitTest` extends `BaseControllerTest` — add one delegation test |

---

## 8. Testing Plan

> **Harness note:** the v2 Testcontainers Postgres lane is broken (SBDEV-2217 — `outbox_message` Flyway-profile gap + landlord datasource). Author behavior tests as **Mockito unit tests** (no DB) where possible; any test that genuinely needs a real tx boundary is `@Disabled` with `TODO(SBDEV-2217)`. The TDD gate relies on the unit tests below.

### Unit tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `TransferOrderServiceUnitTest` | `activateAndAssignTransferLane_availableLane_setsState510AndLane_singleSave` | Happy path: `transferlaneId == lane.id`, `state == CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED(510)`, `customerorderRepository.save(...)` called **exactly once** (`times(1)`), `getAvailableTransferLanesForUpdate` called **exactly once** (F2: one flush, one lock check — never the 505 intermediate) |
| `TransferOrderServiceUnitTest` | `activateAndAssignTransferLane_laneNotAvailable_throws_noSaveNoStateChange` | When the requested lane is **not** in the available set, the method throws `BusinessException` **before** any `setState`/`save` — simulates the "TX2 would have failed" case. Asserts `save` is **never** called (`never()`) and the order is **not** persisted at 505-with-lane. This is the core atomicity assertion: on the failure that used to strand the order, nothing is written |
| `TransferOrderServiceUnitTest` | `activateAndAssignTransferLane_saveThrows_propagates_rollbackForBusinessException` | When `customerorderRepository.save(...)` throws (simulated infra failure inside the tx), the exception propagates and (annotation-level) `rollbackFor` covers `BusinessException`/`FacadeException` — documents that the whole write rolls back as one unit (Mockito asserts propagation; tx rollback itself is annotation-verified by the verify script + the `@Disabled` IT) |
| `TransfersControllerUnitTest` | `activateTransferOrder_delegatesToActivateAndAssign_notTwoCalls` | Controller invokes `transferOrderService.activateAndAssignTransferLane(lane, co)` **once** and invokes **neither** `activateTransferOrder(...)` **nor** `assignTransferLaneToTransferOrder(...)` (`verify(..., never())` on both) — the NEGATIVE check that the two-call split is gone |

### Integration tests (`@Disabled TODO(SBDEV-2217)`)

| Test | What it asserts |
|------|-----------------|
| `activateTransferOrder_tx2FailureSimulated_orderNotStrandedAt505` | With a real tenant tx, force the post-availability write to fail; assert the `Customerorder` row is **not** committed at `state=505` with a non-null `transferlane_id` (the manufactured-bad state). `@Disabled` `TODO(SBDEV-2217)` — body filled, compile-clean |
| `activateTransferOrder_success_orderAt510WithLane_inOneTx` | Happy path through a real tx → order at `510`-with-lane; lane excluded from a subsequent `getAvailableTransferLanes` for another order. `@Disabled` `TODO(SBDEV-2217)` |

### Regression

- Re-run full `TransferOrderServiceUnitTest`, `TransfersControllerUnitTest`; confirm `reassignTransferLane`/`assignTransferLane` (which still call `assignTransferLaneToTransferOrder`) and any existing `activateTransferOrder` coverage still pass.
- Known clean-`develop` failures (4/4194 — Bol shipped-date, RestExceptionHandler 404, UtilRest ×2) are pre-existing and unrelated.

### Manual test plan

| Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Normal activate lands 510 atomically | staging | Open Activate Transfer Order dialog, pick a lane, Next | Order ends at state 510 with the lane; UI flow unchanged | |
| Concurrent activate race | staging | Two operators activate two orders onto the same lane near-simultaneously | One succeeds to 510; the other fails the **single** availability check with the "not available anymore" message and is **not** left at 505-with-lane | |
| No 505-with-lane manufactured | staging DB | After a forced/aborted activate, query `SELECT state, transferlane_id FROM customerorder WHERE id=<co>` | Never `state=505 AND transferlane_id IS NOT NULL` | |

### Acceptance

Machine-checkable acceptance: **`sbdocs/9-System/scripts/verify-260629-activate-transfer-atomicity.sh`**. A "DONE" claim with any FAIL line is not accepted. Optional `mvn_test_passes` of `TransferOrderServiceUnitTest` + `TransfersControllerUnitTest`.

---

## 9. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Other (non-controller) caller relies on the transient 505 from the old two-call flow | Low | Medium | Caller audit (§0): the two-call flow exists **only** in `TransfersController.activateTransferOrder`; no other code reads 505-during-activate (workflow §9 consumers query 510). OQ-1 confirms with requester |
| Removing the separate 505 persistence breaks an OMS callback expecting it | Low | Medium | Workflow §7 — OMS callbacks fire on run/finish, **not** activate; no activate notification exists. No outbox enqueue in either source method today |
| `assignTransferLaneToTransferOrder` accidentally deleted (still has 2 other callers) | Low | High | Plan keeps it; verify script POSITIVE-checks it still exists and its 2 other call-sites remain |
| New orchestration method uses wrong (landlord) TM | Low | High | Verify script asserts `value = "tenantTransactionManager"` on the new method; matches the two methods it replaces |
| Self-invocation trap if a maintainer later delegates instead of inlining | Low | Medium | §5.4 documents the inline decision; verify script asserts the new method does **not** call `this.activateTransferOrder`/`this.assignTransferLaneToTransferOrder` |
| Behavioral change in error timing (fail up-front vs after TX1) surprises the UI | Low | Low | UI already handles the `BusinessException` "not available anymore" path; failing earlier is strictly better (nothing committed) |

---

## 10. Open Questions / Resolved Decisions

### Resolved (locked scope)

1. **Chosen fix = Option 1** (single `@Transactional` orchestration method `activateAndAssignTransferLane`, inline writes, one save). Rejected Option 2 (self-proxy two-call) and Option 3 (transactional controller).
2. **Keep both existing service methods** — `assignTransferLaneToTransferOrder` has 2 other callers; `activateTransferOrder` kept (harmless, smaller diff).
3. **Lane release / stranded-order recovery is OUT OF SCOPE** — owned by [[260629-transfer-lane-leak-on-cancel]] (cancel/unlink). No migration here; operator unlink recovers any pre-existing 505-with-lane order.
4. **End state persisted directly as 510**, skipping the transient 505 (§5.5).

### Resolved (requester decision 2026-06-29)

- **OQ-1 — RESOLVED: persist `510` directly, skip the transient `505`.** Requester confirmed no consumer observes the mid-activate 505 (mobile queries 510; no OMS activate callback; 505 was only a sub-second TX1→TX2 intermediate). The orchestration method writes `state = 510` + lane with one `save()`; it does NOT write an intermediate 505. (If a hidden 505-mid-activate consumer is ever discovered, revisit per §5.5.)

### ADR

- **Decision:** collapse the activate→assign two-transaction split into a single `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` `TransferOrderService.activateAndAssignTransferLane` that inlines the lane+state(510) writes with one `save()`; point the controller at it; keep both legacy methods for their other callers.
- **Drivers:** prevent recurrence of 505-with-lane stranding (the root cause of the leak the sibling plan only *recovers* from); minimal blast radius (one new method + one controller line); preserve the established service-layer-transaction convention; avoid the self-invocation/CGLIB trap by inlining.
- **Alternatives considered:** (i) self-proxied two-call orchestration (260521 pattern); (ii) `@Transactional` on the controller; (iii) leave activate alone and rely solely on the sibling recovery + a scheduled abandonment sweep.
- **Why chosen:** (i) rejected — two redundant lock checks + flushes + a `@Version` bump and a needless proxy hop for zero benefit (no Phase-4-OMS-outside-tx constraint here). (ii) rejected — no transactional controller exists in this codebase; keeps a tenant connection across response serialization. (iii) rejected — recovery without prevention means the bad state keeps being manufactured; the inline fix is cheaper than a sweep job.
- **Consequences:** activate is now atomic — an order can never commit at 505-with-lane; the redundant double-save is gone (one flush, one `@Version` increment, narrower pessimistic-lock window). The transient 505 is no longer separately persisted (OQ-1 confirms no consumer). `assignTransferLaneToTransferOrder` and `activateTransferOrder` remain for their other callers; if either is ever retired, re-audit `TransfersController` first.
- **Follow-ups:** none required; the C2 scheduled abandonment sweep mentioned in the sibling plan becomes unnecessary once prevention (this) + recovery (sibling) are both live, unless recurrence is observed from some other activate path.

---

## Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Size class | **Small/Standard** | 1 new method + 1 controller line, single subsystem |
| Pre-draft step | analyst+planner (this plan) | analysis locked |
| Plan-review step | **critic** | ralplan consensus pass |
| Implementation shape | **executor** | small, well-bounded |
| Verification step | verify-script + verifier | mandatory |
| Code-review step | none (executor self + verifier) | low blast radius |
| Commit step | git-master | 2 atomic commits |

---

## 11. Acceptance Script

`sbdocs/9-System/scripts/verify-260629-activate-transfer-atomicity.sh`

POSITIVE checks:
- `TransferOrderService.activateAndAssignTransferLane` method exists.
- It carries a single `@Transactional(value = "tenantTransactionManager", rollbackFor = {...})`.
- It sets `state` to `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED` and calls `customerorderRepository.save` once.
- `TransfersController.activateTransferOrder` calls `activateAndAssignTransferLane`.
- The two legacy methods (`assignTransferLaneToTransferOrder`, `activateTransferOrder`) still exist (kept for other callers).

NEGATIVE checks:
- `TransfersController.activateTransferOrder` no longer calls `activateTransferOrder(` and `assignTransferLaneToTransferOrder(` in sequence (the two-call split is gone from that method).
- The new orchestration method does not self-invoke `this.activateTransferOrder`/`this.assignTransferLaneToTransferOrder` (no CGLIB-bypass).

---

## 11. Implementation Status — implemented 2026-06-29

**Branch:** `fix/260629-activate-transfer-atomicity` (off `develop`) · **PR:** [SiteBossInc/wms2-api#58](https://github.com/SiteBossInc/wms2-api/pull/58) → `develop` · **Commit:** `b31069d`

| Change | Site | Status |
|---|---|---|
| New atomic `activateAndAssignTransferLane` (1 tenant TX: lock check + lane + state 510 + one save; skips 505) | `TransferOrderService` (`:131`) | ✅ done |
| Controller calls only the new method | `TransfersController.activateTransferOrder` (`:158`) | ✅ done |
| Relapse-vector WARNING comment on retained `activateTransferOrder` | `TransferOrderService` (`:115`) | ✅ done |

**Tests:** `TransferOrderServiceUnitTest` (nested `ActivateAndAssignTransferLane`): `…_availableLane_setsState510AndLane_singleSave`, `…_laneNotAvailable_throws_noSaveNoStateChange` (strand-prevention), `…_saveThrows_propagates_rollbackForBusinessException`. `TransfersControllerUnitTest`: `activateTransferOrder_delegatesToActivateAndAssign_notTwoCalls` (+ obsolete two-call test removed, error-path `doThrow` retargeted per Commit 2). `ActivateTransferAtomicityIT`: 2 real-tx ITs `@Disabled` `TODO(SBDEV-2217)`.

**Results:** `mvn clean compile` SUCCESS (Java 21) · `TransferOrderServiceUnitTest` + `TransfersControllerUnitTest` = **58 run, 0 failures** · verify script = **14 pass, 0 fail** (`SKIP_MVN=0`).

**Process:** DB-verified (`db_verified: true`; 5 live 505-with-lane orders confirm recurrence) → ralplan (Architect SOUND, Critic APPROVE; both optional hardening recs folded in) → TDD gate (throwing stub + 4 red tests) → implement → code review **SHIP** (0 critical/high/medium; NIT comment-wording fixed). Also fixed the verify-script `-q` mvn-helper false-negative (now uses mvn exit code).

**Remediation:** the 5 currently-stranded 505-with-lane orders on `wms2-wineco-dev` are freed via the sibling plan's operator unlink (`GET /v3/transfers/unlinkTransferLane/{id}`, PR #56); this plan stops new ones being manufactured.
