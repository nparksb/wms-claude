---
title: "Transfer Lane Leak on Cancel / Abandonment"
ticket: ""
ticket_url: ""
type: bugfix
priority: high
status: archived
project:
  - wms2
version: v2
requester: nam.park@siteboss.net
created: 2026-06-29
updated: "2026-07-15"
db_verified: true
related:
  - "[[wms2-transfer-order-workflow]]"
  - "[[260320-Auto_Release_Club_Transfer_Lane_Fix]]"
tags:
  - plan
---

# Transfer Lane Leak on Cancel / Abandonment

**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high
**Status:** draft (pending approval)
**Date:** 2026-06-29
**Plan ID:** `260629-transfer-lane-leak-on-cancel`

---

## 0. Affected Sites

| # | Site | File:line | In scope | Fix |
|---|------|-----------|----------|-----|
| 1 | `CustomerorderService.cancelOrder` normal-cancel branch | `CustomerorderService.java:750-754` | **Yes** | Fix A |
| 2 | `CustomerorderService.forceCancelOrder` final save | `CustomerorderService.java:384/422/438` | **Yes** | Fix B |
| 3 | `TransferOrderService.unlinkTransferLaneFromTransferOrder` (missing TM) | `TransferOrderService.java:104-113` | **Yes** | Fix C1/D |
| 4 | `LocationRepository.getAvailableTransferLanes` (the gate) | `LocationRepository.java:57-67` | No — correct as-is | — |
| 5 | `CustomerorderBatchService.finalizeBatchIfComplete` (existing release) | `CustomerorderBatchService.java:~406-407` | No — correct as-is | — |
| 6 | `TransfersController.activateTransferOrder` two-TX split (H2) | `TransfersController.java:147-159` | No — follow-up | `260629-activate-transfer-atomicity` |
| 7 | C2 scheduled abandonment sweep | (new job) | No — follow-up | deferred |
| 8 | `orderBatchId`/`customerOrderId` param mislabel | `TransferOrderService.java:196` | No — separate ticket | deferred |

---

## 1. Problem Statement

**User-visible symptom:** An operator opens the **Activate Transfer Order** dialog (frontend `selectLanePop.vue`, backed by `POST /v3/transfers/availableTransferLanes`) and sees **zero lanes** — only a **Cancel** button. The dialog gates **Next** on a selected lane, so the operator is hard-stuck: no transfer can be activated on the facility.

**Mechanism:** A TRANSFER customerorder activated to `CUSTOMER_ORDER_ACTIVATED(505)` / `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED(510)` — lane assigned — that is never run to `FINISHED(700)` and never cancelled **holds its transfer lane forever**. The availability gate (`LocationRepository.getAvailableTransferLanesForUpdate(coId, FINISHED)`) excludes any lane referenced by some _other_ order with `state < 700`. Once every lane is leaked, the dialog is empty.

### DB Verification (`db_verified: true`)

Tenant `wms2-wineco-dev`, queried 2026-06-29:

- 6 transfer lanes (`transferlane=true`): ids **59200–59205** = `TransferLane01`–`TransferLane06`.
- **All 6** were held by stale TEST transfer orders, `fulfillmenttype='Transfer'`, single-order batches, `markedforcancellation=false`, **none `>= 700`**:

| co.id | state | transferlane_id | order # |
|-------|-------|-----------------|---------|
| 22476694 | 510 | 59200 | BCTestTransfer01 (2025-06-03) |
| 23044155 | 505 | 59201 | TESTTRANSFERCANCEL01 |
| 30093195 | 505 | 59202 | — |
| 30093199 | 505 | 59204 | — |
| 30093203 | 505 | 59205 | TRANSFER-E2E-* |
| 30102053 | 505 | 59203 | TRANSFER-PREP-* |

- A human has already run `UPDATE customerorder SET transferlane_id=NULL` on the **five state-505** orders. **Only lane 59200 (order 22476694, state 510) still held** at time of writing → post-deploy runbook remediation (see §7).
- State constants (`WmsConstants.State`): `CUSTOMER_ORDER_ACTIVATED=505`, `CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED=510`, `FINISHED=700`, `CANCELED=800`.

---

## 2. Root Cause Analysis

> **KEY INSIGHT — this is an _abandonment_ problem, not a _cancel_ problem.**
> The availability gate excludes lanes held by orders with `state < FINISHED(700)`. But `CANCELED = 800 >= 700`, so a **cancelled** order's lane no longer blocks availability _by state alone_. The leaked orders are all stuck strictly **below 700** (505/510) — they were activated and then **abandoned**, never finished and never cancelled. Fixing only the cancel paths (Fix A/B) is correct defense-in-depth, but it does **not** address the observed leak; the observed leak is freed by the operator-recovery path (Fix C1/D, `unlinkTransferLaneFromTransferOrder`) and would be prevented going forward by the deferred H2 atomicity fix (`260629-activate-transfer-atomicity`).

### 2.1 H3 — No auto-release for an abandoned transfer order (PRIMARY, confirmed, HIGH)

**Evidence:** `LocationRepository.java:57-67` — `getAvailableTransferLanes` excludes any lane where `EXISTS` a `customerorder` with `transferlaneId = l.id AND co.id != :customerOrderId AND co.state < :state`, and `activateTransferOrder` (`TransferOrderService.java:117`) passes `state = WmsConstants.State.FINISHED`. So the lane is held by **any** order strictly below 700 — including 505/510.

The only release paths are: (a) `finalizeBatchIfComplete` requires the batch's orders `>= FINISHED` or all-CANCELED (`CustomerorderBatchService:~406-407`, gated `allFinal`); (b) explicit cancel (state→800). An order that is activated and then **abandoned at 505/510** triggers neither → the lane is held **indefinitely**. This is the literal observed state of all 6 lanes. **No code path releases a lane for an order that never reaches a final state.**

### 2.2 H1 — Cancel paths never clear `transferlaneId` directly (LATENT, MEDIUM)

**Evidence:** `CustomerorderService.cancelOrder` sets `state = CANCELED` at `CustomerorderService.java:750` and saves at `:754`, then calls `finalizeBatchIfComplete(:755)`; `forceCancelOrder` sets `state = CANCELED` at `:384`/`:422` and saves at `:438`. **Neither calls `setTransferlaneId(null)` directly.**

Why latent (not the observed bug): single-order cancel currently releases the lane via `finalizeBatchIfComplete` (the order reaches 800, the single-order batch is all-final, the loop clears `transferlaneId`), and `CANCELED=800 >= 700` so the gate no longer excludes the lane anyway. The risk is **multi-order transfer batches** and **defense-in-depth**: a cancelled order should drop its own lane reference at the point of cancellation, not rely on batch finalization landing. Fix A/B make this direct and future-proof.

### 2.3 H2 — Activate two-transaction split strands orders at 505-with-lane (CONTRIBUTING, MED-HIGH, OUT OF SCOPE)

**Evidence:** `TransfersController.activateTransferOrder` (`TransfersController.java:147-159`) drives two separate service calls: `activateTransferOrder` (TX1: sets lane + state 505, `TransferOrderService.java:116-128`) then `assignTransferLaneToTransferOrder` (TX2: sets state 510, `:85-101`). On partial failure / operator abandonment between TX1 and TX2, the order is committed at **505 with a lane assigned** — exactly the stranded state observed in 5 of 6 leaked orders. This is the upstream _cause_ of abandonment-with-lane, but the atomicity refactor is **deferred** to `260629-activate-transfer-atomicity` (see §10).

---

## 3. Regression Chain

N/A — no prior fix in this area introduced the leak; this is a longstanding gap, not a regression.

---

## 4. Architecture Overview

```
LEAK LIFECYCLE
──────────────
activateTransferOrder (TX1)        assignTransferLaneToTransferOrder (TX2)
   set transferlane_id = L              set state = 510
   set state = 505             ───►            │
        │                                       │
        │  [ABANDON between/after TX1-TX2]      │  [ABANDON before run]
        ▼                                       ▼
   co.state = 505, lane = L            co.state = 510, lane = L
        └──────────────┬───────────────────────┘
                       ▼
              co.state < 700  FOREVER   ← no code path releases lane for state<700
                       │
                       ▼
   getAvailableTransferLanes(coId, FINISHED):
     EXCLUDE lanes WHERE EXISTS co2.transferlane_id=L AND co2.id!=coId AND co2.state<700
                       │
                       ▼
   all 6 lanes excluded  →  Activate dialog shows ZERO lanes (only Cancel)

CANCEL PATH (correct-by-state, but no direct clear today)
   cancelOrder / forceCancelOrder  →  state = 800 (>=700, no longer blocks)
                                       finalizeBatchIfComplete clears lane (single-order)

RECOVERY PATH (operator)
   GET /v3/transfers/unlinkTransferLane/{coId}  →  setTransferlaneId(null)  →  lane freed
```

### Key Files

| File | Role |
|------|------|
| `service/CustomerorderService.java` | `cancelOrder` (`:650-755`), `forceCancelOrder` (`:349-442`) — Fix A/B |
| `service/TransferOrderService.java` | `unlinkTransferLaneFromTransferOrder` (`:104-113`), `activateTransferOrder` (`:115-128`) — Fix C1/D |
| `repo/jpa/LocationRepository.java` | `getAvailableTransferLanes` (`:57-67`), `getAvailableTransferLanesForUpdate` (`:72-83`) — the gate (unchanged) |
| `controller/TransfersController.java` | `unlinkTransferLane` (`:124-132`), `activateTransferOrder` (`:147-159`), `availableTransferLanes` (`:367`) |
| `service/CustomerorderBatchService.java` | `finalizeBatchIfComplete` (`~:406-407`) — existing release (unchanged) |

---

## 5. Fix Design

### Fix A — `cancelOrder` clears the transfer lane directly

**File:** `CustomerorderService.java`, normal-cancel branch, around `:750-754`.
Method is already `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` (`:651`).

**Before** (`:750-754`):
```java
            customerOrder.setState(WmsConstants.State.CANCELED);
            // Positions already set to CANCELED by cancelOrderPosition() above — no need to repeat

            // Save order BEFORE batch finalization so CANCELED state is visible on re-read
            customerorderRepository.save(customerOrder);
```

**After:**
```java
            customerOrder.setState(WmsConstants.State.CANCELED);
            // Positions already set to CANCELED by cancelOrderPosition() above — no need to repeat

            // Drop the transfer lane reference directly on cancel — do not rely on batch
            // finalization landing (defense-in-depth, correct for multi-order transfer batches).
            if (customerOrder.getTransferlaneId() != null) {
                customerOrder.setTransferlaneId(null);
            }

            // Save order BEFORE batch finalization so CANCELED state is visible on re-read
            customerorderRepository.save(customerOrder);
```

### Fix B — `forceCancelOrder` clears the transfer lane directly

**File:** `CustomerorderService.java`, before the final save at `:438`. Runs inside `cancelOrder`'s tenant TX (`forceCancelOrder` is invoked from `cancelOrder:683`).

**Before** (`:438`):
```java
        customerorderRepository.save(customerOrder);

        if (customerOrder.getOrderbatchId() != null) {
            customerorderBatchService.finalizeBatchIfComplete(customerOrder.getOrderbatchId());
        }
```

**After:**
```java
        // Drop the transfer lane reference on the force-cancel path as well (same rationale as Fix A).
        if (customerOrder.getTransferlaneId() != null) {
            customerOrder.setTransferlaneId(null);
        }
        customerorderRepository.save(customerOrder);

        if (customerOrder.getOrderbatchId() != null) {
            customerorderBatchService.finalizeBatchIfComplete(customerOrder.getOrderbatchId());
        }
```

> **Why NOT call `unlinkTransferLaneFromTransferOrder` from the cancel paths:** that method **resets `state` to `CUSTOMER_ORDER_ACTIVATED(505)`** (`TransferOrderService.java:110`) — it would **un-cancel** the order. It is the operator-recovery path, not a cancel helper. The cancel paths use a **direct guarded `setTransferlaneId(null)`** only.

### Fix C1 / D — Add the missing tenant TM to `unlinkTransferLaneFromTransferOrder`

**File:** `TransferOrderService.java:104`. The method body is already correct — it clears the lane regardless of state and is the valid operator recovery for orders stuck at 505/510. The **bug is the missing `@Transactional`**: every other write method on this service (`assignTransferLaneToTransferOrder:85`, `activateTransferOrder:115`, `buildStock:398`) is annotated, but `unlinkTransferLaneFromTransferOrder` is not. With no annotation it runs on the `@Primary` **landlord** TM in **auto-commit** — a latent correctness bug (silently no rollback, wrong persistence unit).

**Before** (`:104-113`):
```java
    public void unlinkTransferLaneFromTransferOrder(Customerorder customerOrder) throws BusinessException {
        LOG.debug("called with customerOrder={}", customerOrder);
        customerOrder.setTransferlaneId(null);
        // Restore pre-assignment state (inverse of assign) — port v1 5ada0b0; without this, orders are left in
        // state=510 (TRANSFER_LANE_ASSIGNED) but transferlane_id IS NULL, which violates the data invariant
        // and causes downstream NPEs in MobileTransferOrderService.{updateOrder,updateOrderPosition}.
        customerOrder.setState(CUSTOMER_ORDER_ACTIVATED);
        customerorderRepository.save(customerOrder);
        LOG.debug("end with customerOrder={} (reset to CUSTOMER_ORDER_ACTIVATED)", customerOrder);
    }
```

**After:**
```java
    @Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
    public void unlinkTransferLaneFromTransferOrder(Customerorder customerOrder) throws BusinessException {
        LOG.debug("called with customerOrder={}", customerOrder);
        customerOrder.setTransferlaneId(null);
        // Restore pre-assignment state (inverse of assign) — port v1 5ada0b0; without this, orders are left in
        // state=510 (TRANSFER_LANE_ASSIGNED) but transferlane_id IS NULL, which violates the data invariant
        // and causes downstream NPEs in MobileTransferOrderService.{updateOrder,updateOrderPosition}.
        customerOrder.setState(CUSTOMER_ORDER_ACTIVATED);
        customerorderRepository.save(customerOrder);
        LOG.debug("end with customerOrder={} (reset to CUSTOMER_ORDER_ACTIVATED)", customerOrder);
    }
```

> **Do NOT change** `LocationRepository.getAvailableTransferLanes` / `getAvailableTransferLanesForUpdate` (the `state < 700` gate is correct), nor `CustomerorderBatchService.finalizeBatchIfComplete` (`~:406-407`, the existing correct release).

---

## 6. File Change Summary

| # | File | Method | Change | Fix |
|---|------|--------|--------|-----|
| 1 | `service/CustomerorderService.java` | `cancelOrder` (`:750-754`) | Add guarded `setTransferlaneId(null)` before save | A |
| 2 | `service/CustomerorderService.java` | `forceCancelOrder` (`:438`) | Add guarded `setTransferlaneId(null)` before final save | B |
| 3 | `service/TransferOrderService.java` | `unlinkTransferLaneFromTransferOrder` (`:104`) | Add `@Transactional(tenantTransactionManager, rollbackFor=...)` | C1/D |
| 4 | `src/test/.../CustomerorderServiceUnitTest` | new tests | 3 unit tests | A/B |
| 5 | `src/test/.../TransferOrderServiceUnitTest` | new test | 1 unit test | C1/D |

---

## 7. Prerequisites & Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|---|---|---|
| 1 | **Database state** | No schema change; no Flyway migration | Pure code logic + remediation runbook |
| 2 | **Feature flags / sysprops** | N/A | No toggle gates these fixes |
| 3 | **Config / env** | N/A | No properties change |
| 4 | **Deploy-order** | None — wms2-api standalone | No OMS/UI co-deploy required |
| 5 | **Data migration** | **Manual runbook step (no SQL migration):** post-deploy, operator frees the last leaked lane via `GET /v3/transfers/unlinkTransferLane/22476694` (frees `TransferLane01` / lane id `59200`). The other 5 lanes were already freed by hand (§1). | Run once per affected tenant |
| 6 | **External systems** | N/A | No OMS/printer/keycloak interaction |
| 7 | **Access / permissions** | Operator must have access to the unlink endpoint (existing authority) | No new role |
| 8 | **Monitoring / alerts** | N/A (C2 abandonment-metric deferred) | — |

### 7.2 Implementation Checklist (ordered atomic commits)

- [ ] **Commit 1 (Fix A):** `cancelOrder` guarded `setTransferlaneId(null)` + `cancelOrder_transferOrderWithAssignedLane_clearsTransferlaneId`, `cancelOrder_nonTransferOrder_nullLane_noNpe`.
- [ ] **Commit 2 (Fix B):** `forceCancelOrder` guarded clear + `forceCancelOrder_transferOrderWithLane_clearsTransferlaneId`.
- [ ] **Commit 3 (Fix C1/D):** add `@Transactional(tenantTransactionManager, rollbackFor=...)` to `unlinkTransferLaneFromTransferOrder` + `unlinkTransferLaneFromTransferOrder_clearsLane`.
- [ ] `mvn clean compile` (gate DI/compile drift, per project memory).
- [ ] `bash sbdocs/9-System/scripts/verify-260629-transfer-lane-leak-on-cancel.sh` → 0 fail.
- [ ] **Post-deploy runbook:** operator `GET /v3/transfers/unlinkTransferLane/22476694` per affected tenant.

### 7.3 Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Rationale |
|---|---------|---------|-----------|
| 1 | Stateless services | **PASS** | `CustomerorderService` / `TransferOrderService` hold no request state |
| 2 | No in-JVM lane cache | **PASS** | Lane availability is queried from DB every call; no `ConcurrentHashMap`/static |
| 3 | Assign uses pessimistic lock | **PASS** | `getAvailableTransferLanesForUpdate` `@Lock(PESSIMISTIC_WRITE)` (`LocationRepository:72`) unchanged |
| 4 | Cancel nulls lane in tenant TX | **PASS** | Fix A/B inside `cancelOrder`'s tenant TX; `Customerorder` `@Version` optimistic lock guards concurrent writes |
| 5 | No scheduler added (C1) | **PASS** | C2 sweep job deferred → N/A for this plan |
| 6 | Tenant context | **PASS** | Set by `TenantFilter`; no `@Async` boundary crossed |
| 7 | Idempotency | **PASS** | `cancelOrder` short-circuits via `isAlreadyCancelled` early-return (`:657`); clearing a null lane is a no-op |
| 8 | Connection-pool math | **PASS** | +1 field on an existing `save()` — 0 extra DB round-trips |
| 9 | Optimistic-lock retry | **PASS** | Lock failure bubbles a 409; no new lock contention introduced |
| 10 | Cleanup-job amplification | **N/A** | No scheduled job in this plan |

### 7.4 V2-only Constraints

| # | Constraint | Verdict | Rationale |
|---|------------|---------|-----------|
| 1 | Correct transaction manager | **PASS (key)** | Fix A/B inherit the correct tenant TM; **Fix D ADDS the missing `tenantTransactionManager`** to `unlinkTransferLaneFromTransferOrder` |
| 2 | `rollbackFor` present | **PASS** | `{BusinessException.class, FacadeException.class}` on Fix D, matching siblings |
| 3 | OSIV-disabled safe | **PASS** | `transferlaneId` is a scalar `Long`; no lazy association touched |
| 4 | `readOnly` | **N/A** | Write path |
| 5 | Caffeine eviction | **N/A** | `transferlaneId` is not `@Cacheable` |
| 6 | `jakarta.*` imports | **PASS** | `@Transactional` already imported in `TransferOrderService` |
| 7 | Constructor injection | **PASS** | No new dependency added |
| 8 | `BaseControllerTest` | **N/A** | No controller signature change |

---

## 8. Testing Plan

> **Harness note:** the v2 Testcontainers Postgres lane is broken (SBDEV-2217 — `outbox_message` Flyway-profile gap + landlord datasource). Author integration tests as **H2 repo tests** where feasible, otherwise `@Disabled` with `TODO(SBDEV-2217)`. The **TDD gate relies on the unit tests** below.

### Unit tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `CustomerorderServiceUnitTest` | `cancelOrder_transferOrderWithAssignedLane_clearsTransferlaneId` | After normal cancel, `transferlaneId == null` and `state == CANCELED` (Fix A) |
| `CustomerorderServiceUnitTest` | `forceCancelOrder_transferOrderWithLane_clearsTransferlaneId` | After force-cancel, `transferlaneId == null` (Fix B) |
| `CustomerorderServiceUnitTest` | `cancelOrder_nonTransferOrder_nullLane_noNpe` | Null `transferlaneId` cancel path is a no-op, no NPE (guard) |
| `TransferOrderServiceUnitTest` | `unlinkTransferLaneFromTransferOrder_clearsLane` | Lane cleared, state reset to `CUSTOMER_ORDER_ACTIVATED`, save called (Fix C1/D) |
| `CustomerorderServiceUnitTest` | `cancelOrder_singleOrderTransferBatch_clearsLaneAndFinalizesOnce` | Full chain on a SINGLE-ORDER transfer batch: `cancelOrder` → `finalizeBatchIfComplete`. Asserts `transferlaneId == null`, `state == CANCELED`, and the order's `@Version` increments **exactly once** — Fix A already nulled the lane, so `finalizeBatchIfComplete`'s clear at `CustomerorderBatchService:407` is a no-op (no second flush). H2/unit, NOT Testcontainers (SBDEV-2217). |

### Integration tests (H2 repo, else `@Disabled TODO(SBDEV-2217)`)

| Test | What it asserts |
|------|-----------------|
| `getAvailableTransferLanes_afterCancel_laneReappears` | Cancel an order holding a lane → lane reappears in availability query |
| `getAvailableTransferLanes_orderStuckAt505_laneExcluded_thenUnlink_reappears` | Order stranded at 505-with-lane excludes the lane; after unlink the lane reappears |

### Regression

- Re-run full `CustomerorderServiceUnitTest`, `TransferOrderServiceUnitTest`; confirm no break in existing cancel / club-cancel coverage.
- Known clean-`develop` failures (4/4194 — Bol shipped-date, RestExceptionHandler 404, UtilRest ×2) are pre-existing and unrelated.

### Manual test plan

| Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Activate dialog populated after fix | staging | Cancel/unlink a held lane, open Activate Transfer Order dialog | Lanes listed, Next enabled | |
| Cancel a transfer order frees its lane | staging | Activate→assign lane→cancel order | Lane reappears in availability | |
| Operator unlink recovers stuck 505/510 | staging | `GET /v3/transfers/unlinkTransferLane/{id}` on a stranded order | Lane freed, order back to 505 | |
| SQL sanity | staging DB | `SELECT transferlane_id FROM customerorder WHERE id=22476694` | NULL after runbook unlink | |

### Acceptance

Machine-checkable acceptance: **`sbdocs/9-System/scripts/verify-260629-transfer-lane-leak-on-cancel.sh`**. A "DONE" claim with any FAIL line is not accepted. Optional `mvn_test_passes` of `CustomerorderServiceUnitTest` + `TransferOrderServiceUnitTest`.

---

## 9. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Cancel paths accidentally call `unlinkTransferLaneFromTransferOrder` (un-cancels to 505) | Low | High | NEGATIVE verify check: cancel paths must NOT reference `unlinkTransferLaneFromTransferOrder`; use direct `setTransferlaneId(null)` |
| Fix D TM annotation changes propagation/visibility of existing callers | Low | Medium | Method is only called from `TransfersController.unlinkTransferLane` (not nested in another tenant TX); standalone TX is correct |
| Multi-order transfer batch leaves sibling lane held | Low | Medium | Fix A/B clear per-order at cancel; `finalizeBatchIfComplete` still finalizes the batch |
| Abandoned 505/510 orders keep recurring (root H2 unfixed) | Medium | Medium | Tracked as follow-up `260629-activate-transfer-atomicity`; operator unlink is the interim recovery |
| Stale data on other tenants beyond wineco-dev | Medium | Low | Runbook unlink is per-tenant; sweep query before declaring done |

---

## 10. Open Questions / Resolved Decisions

### Resolved (locked scope)

1. **Cancel paths use direct guarded `setTransferlaneId(null)`, NOT `unlinkTransferLaneFromTransferOrder`** — the latter resets state to 505 (un-cancels) and has no TM. **Resolved: direct clear.**
2. **In scope = Fix A, B, C1, D only.** C2 scheduled abandonment sweep is **deferred** (follow-up).
3. **Remediation = manual runbook unlink of order 22476694 post-deploy** — no SQL migration. **Resolved.**
4. **Do not touch the `state < 700` gate or `finalizeBatchIfComplete`** — both correct as-is. **Resolved.**

### Deferred follow-ups

- **H2 activate atomicity** — collapse the two-TX activate split so an order cannot commit at 505-with-lane → **`260629-activate-transfer-atomicity`** (the root prevention).
- **`orderBatchId` / `customerOrderId` parameter mislabel** at `TransferOrderService.java:196` (`getSKUOverview`) — cosmetic param-name bug, **separate ticket**.

### ADR

- **Decision:** Fix the leak via (A/B) direct lane-clear on both cancel paths and (C1/D) hardening the operator-recovery `unlinkTransferLaneFromTransferOrder` with the correct tenant TM; remediate the one remaining leaked lane by runbook unlink.
- **Drivers:** unblock the empty Activate dialog now; correctness (right TM, no un-cancel); minimal blast radius; no schema/flag/deploy coupling.
- **Alternatives considered:** (i) **C2 scheduled abandonment sweep** to auto-release lanes for orders stranded below 700; (ii) **reuse `unlinkTransferLaneFromTransferOrder` from the cancel paths** instead of a direct clear; (iii) **change the availability gate** to ignore 505/510.
- **Why chosen:** (i) deferred — heavier (advisory lock, sysprop gate, metrics, tenant iteration) and not needed to unblock; the runbook + H2 fix cover the live and root cases. (ii) invalidated — it resets state to 505, **un-cancelling** the order, and lacks a TM. (iii) invalidated — 505/510-with-lane is a legitimately-occupied lane; ignoring it would hand the same lane to two concurrent activations.
- **Consequences:** cancelled/force-cancelled transfer orders drop their lane immediately; the recovery endpoint now runs transactionally on the tenant DB; abandoned orders still require the H2 fix to stop recurring. After Fix A/B, lane-clearing is now performed by **both** `cancelOrder`/`forceCancelOrder` **and** `finalizeBatchIfComplete` (`CustomerorderBatchService:407`) — duplicated invariant enforcement; the deferred H2 follow-up (`260629-activate-transfer-atomicity`) MUST keep both paths in sync, because if either stops clearing the lane for transfer batches the other silently becomes solely load-bearing.
- **Follow-ups:** `260629-activate-transfer-atomicity` (H2 root), C2 sweep (if recurrence persists), `orderBatchId` mislabel ticket.

---

## Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Size class | **Standard** | 3 fixes, single subsystem (transfer-order cancel) |
| Pre-draft step | analyst+planner (done) | analysis locked |
| Plan-review step | **critic** | ralplan consensus pass |
| Implementation shape | **executor** | small, well-bounded |
| Verification step | verify-script + verifier | mandatory |
| Code-review step | none (executor self + verifier) | low blast radius |
| Commit step | git-master | 3 atomic commits |

---

## 11. Implementation Status — implemented 2026-06-29

**Branch:** `fix/260629-transfer-lane-leak-on-cancel` (off `develop`) · **PR:** [SiteBossInc/wms2-api#56](https://github.com/SiteBossInc/wms2-api/pull/56) → `develop` · **Commit:** `5f95a53`

| Fix | Site | Status |
|---|---|---|
| A | `CustomerorderService.cancelOrder` — guarded `setTransferlaneId(null)` before save (`:754`) | ✅ done |
| B | `CustomerorderService.forceCancelOrder` — guarded clear before final save (`:438`) | ✅ done |
| C1/D | `TransferOrderService.unlinkTransferLaneFromTransferOrder` (`:104`) — added `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` | ✅ done |

**Tests added** (`src/test`):
- `CustomerorderServiceUnitTest`: `cancelOrder_transferOrderWithAssignedLane_clearsTransferlaneId`, `forceCancelOrder_transferOrderWithLane_clearsTransferlaneId`, `cancelOrder_nonTransferOrder_nullLane_noNpe`, `cancelOrder_singleOrderTransferBatch_clearsLaneAndFinalizesOnce` (renamed from `…FlushesOnce` per review).
- `TransferOrderServiceUnitTest`: `unlinkTransferLaneFromTransferOrder_clearsLane`.
- `TransferLaneLeakOnCancelIT`: 2 availability-reappearance ITs, `@Disabled` `TODO(SBDEV-2217)` (bodies filled, compile-clean).

**Results:** `mvn clean compile` SUCCESS (Java 21) · `CustomerorderServiceUnitTest` + `TransferOrderServiceUnitTest` = **143 run, 0 failures, 0 errors** · verify script `verify-260629-transfer-lane-leak-on-cancel.sh` = **12 pass, 0 fail** (`SKIP_MVN=0`).

**Code review:** Architect = SOUND, code-reviewer = **SHIP** (0 critical/high). 1 MEDIUM (empty `@Disabled` IT bodies) + LOW/NIT all resolved in-PR (IT bodies filled, test renamed + `times(1)` tightened, `ArgumentCaptor` import).

**Docs updated** (sbdocs, not in PR): `wms2-transfer-order-workflow.md` (TM column + §8 lane-release note), `wms2-cancel-cascade-workflow.md` (§3/§9 + Verification Log), `wms2-transaction-osiv-boundary-map.md` (Verification Log).

**Remediation:** 5/6 leaked lanes on `wms2-wineco-dev` freed manually pre-fix. Last one — order `22476694` (`TransferLane01`): run `GET /v3/transfers/unlinkTransferLane/22476694` post-deploy.

**Deferred follow-ups:** `260629-activate-transfer-atomicity` (single-tx activate); `orderBatchId`/`customerOrderId` mislabel in `TransfersController` (§10) — to ticket.
