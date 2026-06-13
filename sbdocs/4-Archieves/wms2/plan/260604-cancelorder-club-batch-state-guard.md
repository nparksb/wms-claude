---
title: "Guard cancelOrder against mid-club-run cancellation (batch-state guard)"
ticket: ""
ticket_url: ""
type: bugfix
priority: medium
status: archived
project: [wms2]
version: v2
requester: nam.park@siteboss.net
created: 2026-06-04
updated: 2026-06-05
db_verified: true
related:
  - sbdocs/4-Archieves/wms2/plan/260604-club-line-rerun-idempotency-fix.md
  - sbdocs/3-Resources/workflows/wms2-cancel-cascade-workflow.md
  - sbdocs/3-Resources/workflows/wms2-club-run-workflow.md
verify_script: sbdocs/9-System/scripts/verify-260604-cancelorder-club-batch-state-guard.sh
tags:
  - plan
---

# Guard cancelOrder against mid-club-run cancellation (batch-state guard)

**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** Medium (latent data-integrity; companion to the High-priority [club re-run idempotency fix](260604-club-line-rerun-idempotency-fix.md))
**Status:** draft
**Date:** 2026-06-04
**DB verified:** true (the enabling condition is live on `wms2-wineco-dev` batch 29902996)

> **Companion plan.** This is the enabling-defect fix behind §10 Open Question 1 of
> `260604-club-line-rerun-idempotency-fix.md`. That plan makes a club **re-run** safe and
> adds a *content re-validation* that fails loud if a club order's positions changed between
> runs. **This plan removes the cause of that divergence** — an OMS cancel that mutates a
> club order's positions while the batch is mid-run or partially processed. Ship the
> idempotency plan first (it is the loud safety net); this plan closes the hole upstream.

---

## 0. Affected Sites (enumeration before drafting)

| # | File:line | Construct | Same root cause? | In scope? |
|---|-----------|-----------|------------------|-----------|
| 1 | `CustomerorderService.java:621-769` `cancelOrder` | no batch-state guard before cancelling positions | yes | **YES — Fix (new guard)** |
| 2 | `OrderRestController.java:534-626` `cancelPositions` | OMS entry; already maps `BusinessException` → HTTP 400 `WRONG_STATE` (line 577-578) | yes (consumer) | NO — no change; reuses existing rejection contract |
| 3 | `UtilRestController.java:961` `cancelOrder(co,false)` | second external cancel entry (`resetOrdersInReleasedStatus`) | yes (consumer) | NO — inherits the guard automatically |
| 4 | `CustomerorderService.java:631-640` packed/palletized force-cancel | post-run path (batch ≥ FINISHED) | no | NO — guard fires only on 520/525/527, never on packed force-cancel |
| 5 | `CustomerorderService.java:752-759` `markedforcancellation` deferral | "can't cancel now" soft path | no | NO — not used; user chose hard-reject |

In-scope row 1 maps to the POSITIVE checks in `verify-260604-cancelorder-club-batch-state-guard.sh` (§9.1).

---

## 1. Problem Statement

An OMS cancel (`POST /rest/order/cancelPositions`) can cancel a **club** order's positions while its batch is **mid-club-run** (state 527) or **partially processed** (state 520/525 with a package already built). `cancelOrder` has no batch-state guard, so the cancel mutates positions out from under the club-run pipeline, producing a stale/divergent package and (combined with the per-order-commit design) a stuck or mis-shipped order.

**Reproduction:**
1. Activate a club batch (state 520) and run the club line.
2. The run commits Phase-2 per-order packages (`order.parcel_id` set), then finalize fails → batch rolls back to 520 (per the idempotency plan).
3. OMS sends a cancel for one of the orders → `cancelOrder` cancels its positions (no guard) → the already-built package no longer matches the order's positions.
4. Re-run → the idempotency plan's content re-validation throws a loud "contents no longer match" error (good — but the divergence should never have happened).

A tighter window also exists at state 527: a cancel landing *during* an in-flight run races the validation snapshot.

### DB evidence — the enabling condition is live (`wms2-wineco-dev`, tenant `wine-wsl`)

```sql
SELECT b.id AS batch_id, b.state AS batch_state, b.type,
       o.id AS order_id, o.parcel_id, p.id AS pos_id, p.state AS pos_state
FROM customerorder_batch b
JOIN customerorder o      ON o.orderbatch_id = b.id
JOIN customerorder_position p ON p.order_id = o.id
WHERE b.id = 29902996;
-- → batch_state=520 (ACTIVATED), type=CLUB, parcel_id=29903012 (package built),
--   pos_state=0  (< PACKED=650 → passes every existing cancel guard → CANCELLABLE)
```

Batch 29902996 is **right now** in the exact vulnerable shape: a CLUB batch at 520, the order already has a `parcel_id`, and its position (state 0) would sail past every existing guard in `cancelOrder`. An OMS cancel arriving before the operator re-runs would silently corrupt it. No cancel happened to fire in the observed incident — this plan is preventive, and the queryable state proves the hole is open.

---

## 2. Root Cause Analysis

`cancelOrder` (`CustomerorderService.java:613`, `@Transactional("tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`) gates on **order/position** state only:

| Guard | Line | Blocks |
|-------|------|--------|
| already cancelled | 620-623 | idempotent no-op |
| shipped / past boundary | 626-628 | hard throw |
| packed / palletized | 631-640 | force-cancel (WMS or pre-QA club) else throw |
| any position ≥ PACKED | 643-645 | hard throw |

None of these consult the **batch** state. A club order whose positions are still `< PACKED` (the normal case while the batch sits at 520/525/527) passes straight through to the cancellation body (697-705): positions → CANCELED, order → CANCELED, `finalizeBatchIfComplete`, OMS confirmation enqueued.

The club-run pipeline (`CustomerorderBatchService.runClubLine`) is **non-transactional with per-order commits** (260424 design) and reads its positions snapshot once in `validateClubLine` (`643-646`). A cancel that commits between Phase 1 and Phase 2 — or after a partial run leaves the batch at 520 with a built package — is invisible to the in-flight run and divergent from the committed package. The missing guard is the root cause; the per-order-commit architecture is why the divergence is durable rather than rolled back.

---

## 3. Design / Proposed Fix

**Strategy (user decisions, 2026-06-04):**
- **Surgical guard:** block cancel when the order's batch is a CLUB batch and either (a) state == `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` (527) — always; or (b) state ∈ {`ORDER_BATCH_ACTIVATED` (520), `ORDER_BATCH_STAGING_LANE_ASSIGNED` (525)} **and** the order already has a `parcel_id` (a package was built by a prior/partial run). A legitimate pre-run cancel of a club order that has **no** package yet still succeeds.
- **Hard reject:** throw `BusinessException` → the OMS endpoint already maps it to HTTP 400 `WRONG_STATE` with the batch-state text (`OrderRestController.java:577-578`), identical to how *shipped* / *beyond-PACKED* rejections behave. OMS retries once the batch leaves the club-run state.

### 3.1 Fix — batch-state guard in `cancelOrder`

**Problem:** no batch-state check before position cancellation.

**Solution:** insert the guard immediately after the already-cancelled idempotent check (so a re-sent cancel for an order that *is* already CANCELED still no-ops), and before any state mutation. Place it ahead of the shipped/packed checks — it only fires for 520/525/527, which are strictly below PACKED/FINISHED, so it never intercepts the legitimate packed/pre-QA force-cancel path (which operates at batch ≥ 530).

**Before** (`CustomerorderService.java:619-628`):
```java
// 1. Already cancelled → no-op (idempotent)
if (isAlreadyCancelled(customerOrder)) {
    LOG.debug("cancelOrder: order {} is already cancelled, skipping", customerOrder.getNumber());
    return;
}

// 2. Shipped / finished → hard block
if (isShippedOrPastCancellationBoundary(customerOrder)) {
    throw new BusinessException("order is already shipped or past cancellation boundary");
}
```

**After:**
```java
// 1. Already cancelled → no-op (idempotent)
if (isAlreadyCancelled(customerOrder)) {
    LOG.debug("cancelOrder: order {} is already cancelled, skipping", customerOrder.getNumber());
    return;
}

// 1.5 Block cancellation while a CLUB batch is mid-run, or a partial-run package already
//     exists. Prevents mutating positions out from under the per-order club-run pipeline
//     (companion to 260604-club-line-rerun-idempotency-fix.md §10 OQ1).
if (isClubRunCancellationBlocked(customerOrder)) {
    int batchState = clubBatchStateOf(customerOrder); // resolved inside the guard helper
    throw new BusinessException("Cannot cancel order " + customerOrder.getNumber()
            + " while its club batch is in state: " + WmsConstants.State.getCodeText(batchState)
            + ". Retry after the club run completes.");
}

// 2. Shipped / finished → hard block
if (isShippedOrPastCancellationBoundary(customerOrder)) {
    throw new BusinessException("order is already shipped or past cancellation boundary");
}
```

New private helper (mirrors `isOmsPreQaPackedCancellationAllowed` at line 611, but takes the batch row under a **pessimistic write lock** — see the lock rationale below):
```java
private boolean isClubRunCancellationBlocked(Customerorder customerOrder) {
    if (customerOrder.getOrderbatchId() == null) {
        return false;
    }
    // findByIdForUpdate (not plain findById) so this cancel serializes against
    // validateClubLine's batch lock (CustomerorderBatchService:608) — deterministically
    // closes the Phase-2-interleave seam (see §7 row 8). Same repo method validateClubLine uses.
    CustomerorderBatch batch = customerorderBatchRepository
            .findByIdForUpdate(customerOrder.getOrderbatchId()).orElse(null);
    if (batch == null || !WmsConstants.OrderBatchType.CLUB.equals(batch.getType())) {
        return false;
    }
    int s = batch.getState();
    boolean inProgress = (s == WmsConstants.State.ORDER_BATCH_CLUB_RUN_IN_PROGRESS);
    boolean preRunWithPackage =
            (s == WmsConstants.State.ORDER_BATCH_ACTIVATED
                    || s == WmsConstants.State.ORDER_BATCH_STAGING_LANE_ASSIGNED)
            && customerOrder.getParcelId() != null;
    return inProgress || preRunWithPackage;
}
```
(For the error message, the helper or a sibling `clubBatchStateOf` returns the resolved state; the implementer may fold both into one helper that returns an `OptionalInt`/sentinel to avoid a second lookup. Single-lookup form preferred — do **not** issue two `findByIdForUpdate` calls.)

**Files changed:** `CustomerorderService.java` (one guard call + one/two private helpers). No new dependency — `customerorderBatchRepository` is already injected (used at line 737); `findByIdForUpdate` already exists on the repo (`validateClubLine` uses it at `CustomerorderBatchService.java:608`).

### 3.2 Why this scope (and not more)

- **Not state 530+ (FINISHED):** once the run finished, the order is PACKED and the existing packed/pre-QA force-cancel path (631-640) correctly governs cancellation. The guard must not fire there.
- **Not non-club batches:** the 520/525/527 constants are club-batch states; the guard is additionally gated on `OrderBatchType.CLUB` so it can never affect pick/pack or other flows.
- **Not the deferral path:** user chose hard-reject over `markedforcancellation` deferral (which would require wiring the club completion path to honor marked orders — larger blast radius, separate plan if ever desired).

**Why `parcelId != null` at 520/525 reliably means "partial run" (and not some benign cause):** every other `setParcelId` caller is either non-club or sets the batch to FINISHED in the same transaction — `packageOrder` rejects CLUB before setting parcel (`CustomerorderService.java:509-511,556`); `BillofladingService.transferOrder` sets PACKED + batch→530 together (`:772-777`). The one path that resets a club batch to 520 **without** clearing `parcel_id` is `activateOrderBatch` (`CustomerorderBatchService.java:464-472`), i.e. re-activation. But re-activation is gated by `batchHasNoActiveOrders` (`CustomerorderBatchService.java:889-893`), which **throws if all orders are FINISHED/CANCELED** — so a cleanly-finished club batch cannot be re-activated, and a *partially*-finished one that is re-activated is exactly the partial-run shape this guard targets. Therefore `parcelId != null` at 520/525 reliably indicates "package built, run not cleanly finished" → blocking is correct in every reachable case.

---

## 4. Architecture Overview

```
OMS  POST /rest/order/cancelPositions
        │
        ▼
OrderRestController.cancelPositions          (534-626)
        │   per order:
        ├─ customerorderService.cancelOrder(co, false)      ← Fix: new guard 1.5 here
        │       catch BusinessException → WebserviceBusinessExceptionClientSide(WRONG_STATE)
        │                               → HTTP 400 + state text   (577-578)   [unchanged contract]
        ▼
CustomerorderService.cancelOrder             (613-763, @Transactional tenantTM)
   guards: alreadyCancelled → [NEW club-run guard] → shipped → packed → pos≥PACKED → cancel body
```

### Key files

| File | Lines | Role |
|------|-------|------|
| `service/CustomerorderService.java` | 621-769 | `cancelOrder`; add guard 1.5 + helper (**Fix**) |
| `service/CustomerorderService.java` | 611-617 | `isOmsPreQaPackedCancellationAllowed` — pattern to mirror (club-batch lookup) |
| `controller/rest/OrderRestController.java` | 534-626 | OMS entry; `BusinessException` → 400 `WRONG_STATE` (no change) |
| `controller/rest/UtilRestController.java` | 961 | second external cancel entry (inherits guard) |
| `service/WmsConstants.java` | 71/76/81, 123 | club-batch state constants + `State.getCodeText(int)` |
| `service/CustomerorderBatchService.java` | 608-624 | `validateClubLine` batch lock + IN_PROGRESS — the run side of the race |

Reference: `sbdocs/3-Resources/workflows/wms2-cancel-cascade-workflow.md`, `wms2-club-run-workflow.md`.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|---|---|---|
| 1 | Database state | None | No schema change |
| 2 | Feature flags / sysprops | N/A | Pure correctness guard |
| 3 | Config / env | N/A | — |
| 4 | Deploy order | Ship **after / with** `260604-club-line-rerun-idempotency-fix` | The idempotency fix is the loud safety net; this closes the upstream hole |
| 5 | Data migration | N/A | — |
| 6 | External systems | OMS must tolerate HTTP 400 `WRONG_STATE` on cancel | Already the contract for shipped/beyond-PACKED rejections; confirm OMS retries rather than drops |
| 7 | Access / permissions | N/A | — |
| 8 | Monitoring / alerts | Optional | Log line on block is sufficient; a counter is optional (see §10) |

### 5.2 Implementation Checklist

- [ ] **S1** Add `isClubRunCancellationBlocked` helper (+ state resolver) to `CustomerorderService`.
- [ ] **S2** Insert guard 1.5 in `cancelOrder` after the already-cancelled check, before the shipped check (§3.1).
- [ ] **S3** Unit tests (§6) in `CustomerorderServiceUnitTest`.
- [ ] Code review (focus: guard placement vs the packed/force-cancel path; OMS 400 contract).

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Block — IN_PROGRESS | club batch state 527 | `cancelOrder` throws `BusinessException`; no position mutated |
| Block — pre-run with package | club batch 520/525, order.parcelId != null | throws `BusinessException`; no mutation |
| Allow — pre-run no package | club batch 520/525, order.parcelId == null | cancel proceeds (unchanged behavior) |
| Allow — non-club batch | batch type != CLUB, any state | cancel proceeds (guard inert) |
| Allow — finished | batch 530+ | guard inert; existing packed/pre-QA path governs |
| Idempotent — already cancelled | order already CANCELED, batch 527 | no-op return (guard not reached) |
| OMS contract | cancel a 527 club order via `/rest/order/cancelPositions` | HTTP 400, body shows `WRONG_STATE` + batch state text |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `CustomerorderServiceUnitTest` | `cancelOrderBlockedWhenClubBatchInProgress` | `BusinessException`; `verify(customerorderPositionService, never()).cancelOrderPosition(...)` |
| `CustomerorderServiceUnitTest` | `cancelOrderBlockedWhenClubPreRunHasPackage` | batch 520 + parcelId set → throws; no mutation |
| `CustomerorderServiceUnitTest` | `cancelOrderAllowedWhenClubPreRunNoPackage` | batch 520 + parcelId null → proceeds (positions cancelled, order CANCELED) |
| `CustomerorderServiceUnitTest` | `cancelOrderAllowedWhenBatchNotClub` | non-CLUB batch → guard inert |
| `CustomerorderServiceUnitTest` | `cancelOrderIdempotentWhenAlreadyCancelledEvenMidRun` | already CANCELED + batch 527 → no-op, no throw |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| OMS cancel during club run | staging | start a club run, fire `/rest/order/cancelPositions` for an order in it | HTTP 400 `WRONG_STATE`; order untouched; run completes normally | |
| OMS cancel of pre-run club order (no package) | staging | activate club batch (don't run), cancel an order | cancel succeeds; order CANCELED | |
| OMS cancel after run finished | staging | finish club run, cancel a PACKED order | existing pre-QA/packed behavior unchanged | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped |
|---------|--------|-----------------------|
| `mvn test -Dtest=CustomerorderServiceUnitTest` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Testcontainers IT | Guard is pure in-memory state logic over mocked repos; no native SQL/transfer semantics involved. The end-to-end club race is covered by the idempotency plan's IT. |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Mitigation / rationale |
|---|---------|---------|------------------------|
| 1 | In-JVM state | N/A | Guard reads DB batch state only |
| 2 | Connection pool math | No | One extra `findById` on the cancel path (low frequency) |
| 3 | Scheduled jobs | N/A | Request-driven |
| 4 | Long transactions | No | Guard adds one read inside the existing `cancelOrder` tx |
| 5 | Request affinity | N/A | — |
| 6 | Retry / idempotency | OK | Already-cancelled no-op preserved; a blocked cancel is a clean 400 that OMS may safely retry later |
| 7 | Tenant context | OK | Within request-scoped `TenantContext` |
| 8 | **Distributed lock correctness** | **Yes — sealed via `findByIdForUpdate`** | The guard takes the batch row under `findByIdForUpdate` (§3.1), so a cancel **serializes against `validateClubLine`'s batch lock** (`CustomerorderBatchService:608`) — consistent batch-first lock ordering (both paths lock the batch first → low deadlock risk). This deterministically closes the Phase-2-interleave seam: a cancel can no longer commit between `validateClubLine`'s order snapshot (`:632`) and a later order's `processOrder`, because it must wait for the run's batch lock and will then see state 527 (blocked). A lock-free `findById` was considered (lighter) but rejected: the residual race it leaves is the exact seam shared with the idempotency plan. Lock timeout is finite (`jakarta.persistence.lock.timeout=5000`, `application.properties:64`), so a crashed holder self-heals. |
| 9 | Cache invalidation | N/A | No cached entity written by the guard |
| 10 | External notifications | Unchanged | The OMS cancel confirmation enqueue (708-744) is only reached when the cancel is *allowed* |

### Evidence (Yes rows)

| Concern # | What was verified | File:line |
|-----------|-------------------|-----------|
| 8 | `validateClubLine` locks batch then re-reads orders; guard reads state | `CustomerorderBatchService.java:608-624,632-633`; `CustomerorderService.java:609` (lock-free read pattern) |

---

## 8. Notes

- This guard is intentionally **narrow**: it never fires at batch ≥ FINISHED, never for non-club batches, and never for a pre-run club order without a package — so legitimate cancels still flow. Do not broaden it to "block all cancels for club orders" without revisiting the OMS contract.
- The companion idempotency plan (`260604-club-line-rerun-idempotency-fix.md`) remains the loud safety net even with this guard in place (the `wms2.clubline.reuse_content_mismatch` counter there will read zero once this guard ships, confirming the hole is closed).

### v2 Constraint Checklist

| # | Constraint | Verdict | Where addressed |
|---|------------|---------|-----------------|
| 1 | OSIV disabled — reads inside a tx | OK | Guard runs inside `cancelOrder`'s tenant tx |
| 2 | Tenant transaction manager | OK | `cancelOrder` already `@Transactional("tenantTransactionManager")` |
| 3 | `@Transactional(readOnly=true)` | N/A | Read is inside an existing read-write tx |
| 4 | Caffeine cache invalidation | N/A | No cached entity written |
| 5 | Jakarta namespace | OK | No `javax.*` introduced |
| 6 | H2-compatible test SQL | OK | Unit tests mock repos; no SQL |
| 7 | `BaseControllerTest` for controller changes | N/A | No controller change (endpoint behavior unchanged — it already maps `BusinessException`→400) |
| 8 | Micrometer metrics | Optional | A `wms2.clubline.cancel_blocked` counter is optional (§10) |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

`sbdocs/9-System/scripts/verify-260604-cancelorder-club-batch-state-guard.sh` asserts:
- **POSITIVE** — `isClubRunCancellationBlocked` helper present and gated on `OrderBatchType.CLUB`.
- **POSITIVE** — helper checks `ORDER_BATCH_CLUB_RUN_IN_PROGRESS` and the `{ACTIVATED, STAGING_LANE_ASSIGNED} && getParcelId() != null` condition.
- **POSITIVE** — `cancelOrder` invokes the guard and throws a `BusinessException` mentioning the club batch state, placed **after** the already-cancelled check.
- **mvn** — `CustomerorderServiceUnitTest` passes.

Final acceptance: `Result: N pass, 0 fail, …` pasted into the implementation report.

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Small / Standard | One guard + helper + unit tests in a single service |
| **Pre-draft step** | analyst + clarifying questions (done) | scope + OMS-contract decisions resolved |
| **Plan-review step** | critic (optional) | small surface; the OMS-contract + TOCTOU calls are documented |
| **Implementation shape** | executor | bounded single-file change |
| **Verification step** | verify-script + verifier | mandatory |
| **Code-review step** | code-reviewer | guard placement vs packed/force-cancel path is the one subtlety |
| **Commit step** | git directly | single logical commit |

---

## 10. Resolved Decisions & Open Questions

### Resolved (user decisions, 2026-06-04)
1. **Guard scope = surgical:** block at 527 always; at 520/525 only when `order.parcelId != null`; allow otherwise. Pre-run cancels of package-less club orders still succeed.
2. **Reject semantics = hard reject:** throw `BusinessException` → HTTP 400 `WRONG_STATE` (existing contract). No `markedforcancellation` deferral.

### Open questions / follow-ups
1. **TOCTOU — RESOLVED (architect/critic).** The guard uses `findByIdForUpdate(batchId)` (§3.1, §7 row 8), serializing the cancel against `validateClubLine`'s batch lock and deterministically sealing the Phase-2-interleave seam shared with the idempotency plan. (Originally drafted as a lock-free read for minimalism; promoted to the locked read on review — one line, low deadlock risk via batch-first lock ordering.)
2. **OMS retry behavior on 400 `WRONG_STATE`.** Confirm OMS treats the rejection as retryable (re-sends after the batch finishes) rather than dropping the cancel. If OMS drops it, reconsider the deferral (`markedforcancellation`) design.
3. **Optional observability.** A `wms2.clubline.cancel_blocked` counter would quantify how often OMS cancels race club runs. Low effort; deferred unless ops wants the signal.
4. **Guard message is not surfaced verbatim to OMS (code review HIGH — accepted as-is).** `OrderRestController.cancelPositions` (`:577-578`) maps any `BusinessException` to `WebserviceBusinessExceptionClientSide(WRONG_STATE, e, State.getCodeText(customerOrder.getState()), ...)` — so the OMS-visible detail is the **order** state (e.g. "Processable"), and the guard's "…club batch is in state X. Retry after the club run completes." text rides only as the exception cause. The cancel **is** correctly rejected with HTTP 400 WRONG_STATE; only the human-readable reason is generic. This is the *pre-existing* contract shared by the shipped / beyond-PACKED rejections — deliberately **not** changed here, because altering the controller's error mapping would change the OMS-visible text for every cancel rejection (out of scope). If clearer messaging is wanted, surface `e.getMessage()` for `BusinessException` in that catch as a separate, contract-reviewed change.
5. **`resetOrdersInReleasedStatus` now skips mid-run club orders (blast radius).** The admin reset path (`UtilRestController.java:961`) catches the cancel `BusinessException` and continues, so after this guard it will silently skip a club order whose batch is mid-run/partial instead of resetting it. Benign (you would not want to reset a mid-run club order), but noted as an intended side effect.

---

## 11. Implementation Status (2026-06-04)

**Status: implemented.**

### Changes
| File | Change |
|------|--------|
| `service/CustomerorderService.java` | Added private `clubRunCancellationBlockingState(Customerorder)` — single-lookup sentinel helper (returns the blocking state or `null`) reading the batch under `findByIdForUpdate` (serializes vs `validateClubLine`), gated on `OrderBatchType.CLUB`, blocking at 527 always and at 520/525 when `parcelId != null`. Wired a guard into `cancelOrder` immediately after the already-cancelled idempotent check (before the shipped/packed checks) that throws `BusinessException` ("…while its club batch is in state: X. Retry after the club run completes.") when blocked. |
| `test/.../CustomerorderServiceUnitTest.java` | 7 tests in the `CancelOrder` nested class: block-527, block-520-with-package, block-525-with-package, allow-520-no-package, allow-non-club, allow-batch-not-found, idempotent-already-cancelled (asserts no batch lock taken). |

### Verification
- `mvn test -Dtest=CustomerorderServiceUnitTest` → **BUILD SUCCESS, 100 tests, 0 failures, 0 errors** (Java 21.0.11 / Maven 3.9.15).
- `mvn clean compile` → **BUILD SUCCESS**.
- `bash sbdocs/9-System/scripts/verify-260604-cancelorder-club-batch-state-guard.sh` → **`Result: 8 pass, 0 fail, 0 skip`**.
- Code review (`code-reviewer`, opus): **0 CRITICAL**. 1 HIGH (guard message not surfaced verbatim by `OrderRestController` — pre-existing shared contract; accepted, see §10 OQ4). 2 MEDIUM test gaps (525 branch, batch-not-found) **closed**. Remaining MEDIUM/LOW (admin-reset skip, lock-on-every-cancel, theoretical unboxing NPE) documented; no code change.
- verify-docs: `wms2-cancel-cascade-workflow.md` (`last_verified: 2026-05-08`, within threshold) has pre-existing approximate `cancelOrder` line refs (now shifted +42) and does not yet mention the new club-run guard — recommended non-blocking touch-up.

### Git
- Branch: `tasks/cancelorder-club-guard` (off `origin/develop`; companion to PR #36).
- Commit: `4fdbc2df775d0ea578c67f841c098107ba5734fb`
- PR (→ `develop`): https://github.com/SiteBossInc/wms2-api/pull/37 (merge **after** PR #36)

---

> **Archive note (2026-06-05):** Shipped via PR #37 (merged to `develop`, after PR #36). Archived from `1-Projects/wms2/plan/`.
> Acceptance script retained at `sbdocs/9-System/scripts/verify-260604-cancelorder-club-batch-state-guard.sh`.
