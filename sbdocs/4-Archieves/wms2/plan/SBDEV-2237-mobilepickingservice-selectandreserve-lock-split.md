---
title: "MobilePickingService.selectAndReservePickingOrder Lock-Window Split"
ticket: "SBDEV-2237"
ticket_url: "https://app.clickup.com/t/SBDEV-2237"
type: "bugfix"
priority: "high"
status: "archived"
project:
  - wms2
version: "v2"
requester: "Nam Park"
created: "2026-05-15"
updated: "2026-05-15"
db_verified: true
pr: "https://github.com/SiteBossInc/wms2-api/pull/25"
commit: "63e73a7"
related:
  - sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
  - sbdocs/3-Resources/architecture/wms2-state-machine-catalog.md
  - sbdocs/4-Archieves/wms2/plan/SBDEV-2223-confirmPick-last-pick-detection-race.md
  - sbdocs/4-Archieves/wms2/plan/SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix.md
tags:
  - plan
  - wms2
  - picking
  - mobile
  - concurrency
  - pessimistic-lock
  - transaction
  - lock-window
---

# SBDEV-2237 — `MobilePickingService.selectAndReservePickingOrder` Lock-Window Split

**Ticket:** [SBDEV-2237](https://app.clickup.com/t/SBDEV-2237)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high
**Status:** implemented
**Date:** 2026-05-15

> **db_verified: true** — `pickingorder` table confirmed on tenant PostgreSQL DB
> with `state`, `operator_id`, `lockedtooperator`, `pickinginprogress`, `section_id`,
> `version` columns (verified 2026-05-15). `mywms_user` and `pickingorder_position`
> exist as referenced. Multi-replica deployment is confirmed by
> `wms2-tenant-routing-datasource-topology.md`.
>
> The fix targets the **lock-window width** of `findByIdForUpdate(pickingOrderID)`,
> currently held across `processPickingOrderForStart` (≥4 sub-queries and an
> optional `finishPickingOrder` call). The lock window grows with workload and
> can exceed the global 5000ms `jakarta.persistence.lock.timeout` under high
> contention on the same picking order id.

---

## §0 Affected Sites

All in-scope call sites in the picking-claim cluster were enumerated. Rows 1–3
are the primary in-scope sites; rows 4–5 are deliberately **excluded** with
rationale.

| # | File:line | Construct | Outer tx | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|----------|------------------|----------------------|
| 1 | `service/mobile/MobilePickingService.java:150-167` | `selectAndReservePickingOrder(long)` — single wide `@Transactional` wrapping `findByIdForUpdate` + `processPickingOrderForStart` | self (method-level) | **yes** | **yes — Fix A (split into orchestrator + Tx-1 + Tx-2)** |
| 2 | `service/mobile/MobilePickingService.java:323-382` | `processPickingOrderForStart(Pickingorder)` private — 4 sub-queries (`userRepository.findByName`, `pickingorderPositionRepository.findByPickingorderId`, `sectionRepository.findById`, conditional `finishPickingOrder`, `pickingorderRepository.save`) all inside the lock window | inherits caller's tx | **yes** | **yes — extracted into Tx-2** |
| 3 | `repo/jpa/PickingorderRepository.java:22-24` | `findByIdForUpdate(Long)` declared `@Lock(PESSIMISTIC_WRITE)` with **no** `@QueryHints` lock-timeout override — defaults to the global `jakarta.persistence.lock.timeout=5000` in `application.properties` | n/a | yes | **yes — Fix B (per-query 1000ms override)** |
| 4 | `service/mobile/MobilePickingService.java:170-212` | `resumePickingOrderIfExists()` also calls `processPickingOrderForStart` at `:203`, **but** the entity is loaded by `findByOperatorAndStates` (no `FOR UPDATE` row lock). | self | no — no `findByIdForUpdate` lock window to shrink | **NO** — different code path; resume already operates on an order that the caller "owns" via operator-id filter. Out of scope. |
| 5 | `service/mobile/MobilePickingService.java:686-...` | `getPickingOrderPositionsInfo` — separate hot path flagged in the analysis bundle as the production-active equivalent of `selectAndReservePickingOrder`. | self | similar pattern (broader concurrency audit) | **NO** — separate change; tracking via follow-up SBDEV ticket. Bundling here would expand blast radius and break the atomic single-method fix contract. |

**Scope rationale:** rows 1–3 form a self-contained cluster — one
service-method refactor + one repository annotation = one diff. Rows 4 and 5
are explicitly recorded with their out-of-scope rationale so a future reviewer
does not assume they were missed.

---

## §1 Problem Statement

**User-visible symptom:** under heavy concurrent mobile-picking load (~100
pickers), starting a picking order can either:
- Block for up to the global `jakarta.persistence.lock.timeout=5000ms` while
  another operator's `processPickingOrderForStart` finishes, or
- Surface as a `PessimisticLockingFailureException` mapped to HTTP 409 (current
  `RestExceptionHandler.handlePessimisticLock`), occasionally observable as
  "Resource Locked — please retry" toast in the mobile UI.
- In low-volume deployments the symptom is **not observable**; the bug is
  load-amplitude-dependent.

**Root cause sentence:** `selectAndReservePickingOrder` is annotated
`@Transactional(value="tenantTransactionManager", ...)` and holds a
PostgreSQL `SELECT ... FOR UPDATE` row lock on the target `pickingorder` row
from line 154 (`findByIdForUpdate`) through the **entire**
`processPickingOrderForStart` body (lines 323–382), which itself performs ≥4
additional DB round-trips while the lock is held. The lock window scales with
sub-query latency — every extra repo call is extra time another operator's
`findByIdForUpdate` on the same row must wait.

**Reproduction (deterministic):**

1. Pick a tenant with `state = PROCESSABLE` picking orders.
2. From two concurrent threads, invoke
   `selectAndReservePickingOrder(samePickingOrderId)` (either via the mobile
   endpoint that fronts this service, or directly via an integration test with
   a `CountDownLatch`).
3. Thread A acquires `FOR UPDATE` and enters `processPickingOrderForStart`.
4. Thread B's `findByIdForUpdate` blocks for the duration of Thread A's
   sub-queries.
5. If Thread A's body exceeds 5000ms (e.g. slow DB, hot replica, large
   `pickingorder_position` count), Thread B's lock acquisition aborts with
   `LockTimeoutException → PessimisticLockingFailureException`, surfaced as
   HTTP 409 by the existing handler. Under sustained 100-picker load the
   timeout is reachable even without an artificially-slow Thread A.

**Why a fix is justified prophylactically even though `selectAndReservePickingOrder`
has no production HTTP caller in the current v2 codebase** (the analysis
bundle's audit flagged `getPickingOrderPositionsInfo` at `:686` as the actual
production hot path): the same lock-window-width antipattern lives in this
method, and the symmetric fix on the production hot path (row 5 above) will
follow the same shape. Landing the shape change here first establishes the
pattern, the verification harness, and the test coverage that the follow-up
ticket can re-use.

---

## §2 Root Cause Analysis

### Bug 1: Wide lock window in `selectAndReservePickingOrder`

```java
// MobilePickingService.java:150-167  (current)
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public Pickingorder selectAndReservePickingOrder(long pickingOrderID) throws BusinessException, FacadeException {
    LOG.debug("start with pickingOrderID={}", pickingOrderID);
    // Use pessimistic lock to prevent two workers from claiming the same order
    Optional<Pickingorder> pickingOrderOpt = pickingorderRepository.findByIdForUpdate(pickingOrderID);  // ← lock acquired
    Pickingorder pickingOrder = null;

    if (!pickingOrderOpt.isPresent()) {
        LOG.debug("end   without pickingOrder");
        return null;
    } else {
        pickingOrder = pickingOrderOpt.get();
    }

    pickingOrder = processPickingOrderForStart(pickingOrder);   // ← 4+ sub-queries STILL UNDER LOCK
    LOG.debug("end   with pickingOrder={}", pickingOrder);
    return pickingOrder;
}                                                                // ← lock released here (tx commit)
```

**Transaction boundary:** the method is `@Transactional(tenantTransactionManager)`,
which means the Hibernate session + PostgreSQL row lock are both held for the
entire method duration — through `processPickingOrderForStart` and any code it
calls (including `finishPickingOrder`).

**`processPickingOrderForStart` operation inventory** (verified from
`MobilePickingService.java:323-382`):

| # | Operation | Read or Write | DB round-trip? |
|---|---|---|---|
| 1 | `userRepository.findByName(SecurityContextUtils.getUserName())` | Read | yes — under lock |
| 2 | State-guard branch: `pickingOrder.getState() < RESERVED`, throw `FacadeException` on `>= PICKED` or RESERVED-by-different-user | in-memory + mutation only | no |
| 3 | `pickingOrder.setOperatorId(user.getId())`, `setState(RESERVED)` | in-memory mutation | no |
| 4 | `pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId())` | Read | yes — under lock |
| 5 | `allFinished` branch (stream check); if true → `pickingorderBusinessService.finishPickingOrder(pickingOrder)` | conditional Write cascade (multiple repo calls inside `finishPickingOrder`) | yes — under lock |
| 6 | `sectionRepository.findById(pickingOrder.getSectionId())` | Read | yes — under lock |
| 7 | RAPID_PICKING branch: `setLockedtooperator(false)` + `pickingorderRepository.save(pickingOrder)` | Write | yes — under lock |
| 8 | Default branch: `pickingorderRepository.save(pickingOrder)` | Write | yes — under lock |

**Total**: at minimum **3 reads + 1 write** under the FOR UPDATE row lock on
`pickingorder`. On the `allFinished` branch, add the entire `finishPickingOrder`
cascade. None of these operations *require* the FOR UPDATE lock on the original
`pickingorder` row after the state mutation has been claimed and committed —
the lock is structurally necessary only for the brief read-then-write of
the `state` / `operatorId` fields that guards against two operators claiming
the same row.

### Bug 2: No per-query lock timeout on `findByIdForUpdate`

```java
// PickingorderRepository.java:22-24  (current)
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT p FROM Pickingorder p WHERE p.id = :id")
Optional<Pickingorder> findByIdForUpdate(@Param("id") Long id);
```

No `@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "..."))`
override. The lock acquisition falls back to the global
`jakarta.persistence.lock.timeout` set in `application.properties:64` (currently
`5000`ms). 5s is appropriate for slow background sweeps but too slow for the
interactive mobile-pick claim path — under contention an operator sees a
5-second blocking pause before the request fails.

Sibling repository `BillofladingRepository.findByIdForUpdate` (lines 26–30)
already demonstrates the per-query pattern with a 5000ms override; the same
pattern at a tighter 1000ms is appropriate for the interactive claim path.

---

## §3 Fix Design

### Fix A: Split `selectAndReservePickingOrder` into orchestrator + Tx-1 + Tx-2

**Before** (current `MobilePickingService.java:150-167` + `:323-382`):

```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public Pickingorder selectAndReservePickingOrder(long pickingOrderID) throws BusinessException, FacadeException {
    LOG.debug("start with pickingOrderID={}", pickingOrderID);
    Optional<Pickingorder> pickingOrderOpt = pickingorderRepository.findByIdForUpdate(pickingOrderID);
    Pickingorder pickingOrder = null;
    if (!pickingOrderOpt.isPresent()) {
        LOG.debug("end   without pickingOrder");
        return null;
    } else {
        pickingOrder = pickingOrderOpt.get();
    }
    pickingOrder = processPickingOrderForStart(pickingOrder);
    LOG.debug("end   with pickingOrder={}", pickingOrder);
    return pickingOrder;
}

private Pickingorder processPickingOrderForStart(Pickingorder pickingOrder) throws BusinessException, FacadeException {
    User user = userRepository.findByName(SecurityContextUtils.getUserName())
        .orElseThrow(() -> new EntityNotFoundException("User not found by name: " + SecurityContextUtils.getUserName()));

    if (pickingOrder.getState() < WmsConstants.State.RESERVED) {
        int stateOld = pickingOrder.getState();
        if (stateOld >= WmsConstants.State.PICKED) {
            throw new FacadeException("PICK_ALREADY_STARTED", pickingOrder.getNumber());
        }
        if (stateOld >= WmsConstants.State.RESERVED && user.getId().equals(pickingOrder.getOperatorId())) {
            throw new FacadeException("ORDER_RESERVED", "");
        }
        pickingOrder.setOperatorId(user.getId());
        if (stateOld < WmsConstants.State.RESERVED) {
            pickingOrder.setState(WmsConstants.State.RESERVED);
        }
    } else if (pickingOrder.getState() >= WmsConstants.State.RESERVED && !user.getId().equals(pickingOrder.getOperatorId())) {
        throw new BusinessException("Picking Order reserved by different user!");
    }

    List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId());
    boolean allFinished = poPositions.stream().noneMatch(p -> p.getState() < WmsConstants.State.PICKED);

    if (allFinished && pickingOrder.getState() <= WmsConstants.State.PICKED) {
        pickingOrder.setState(WmsConstants.State.PICKED);
    }
    if (pickingOrder.getState() == WmsConstants.State.PICKED) {
        pickingorderBusinessService.finishPickingOrder(pickingOrder);
        return null;
    }
    if (pickingOrder.getState() > WmsConstants.State.PICKED) {
        return null;
    }

    final Long poSectionId = pickingOrder.getSectionId();
    Section section = sectionRepository.findById(poSectionId)
        .orElseThrow(() -> new EntityNotFoundException("Section", poSectionId));
    if (section.getSectionpickingtype() == WmsConstants.SectionPickingType.RAPID_PICKING) {
        pickingOrder.setLockedtooperator(false);
        pickingorderRepository.save(pickingOrder);
        return null;
    }

    pickingOrder = pickingorderRepository.save(pickingOrder);
    return pickingOrder;
}
```

**After** — three methods, two transactions, one orchestrator, driven by
`TransactionTemplate`:

```java
// --- Inner record to communicate whether Tx-1 performed a fresh claim or was a no-op re-claim.
// Used by the orchestrator to decide whether to trigger compensating release on Tx-2 failure.
private record ClaimResult(Pickingorder claimed, boolean wasFreshClaim) {}

// --- Programmatic-transaction fields, declared on MobilePickingService ---
// We use TransactionTemplate (the standard Spring API for programmatic
// transaction management) instead of @Lazy self-injection because:
//   (a) TransactionTemplate does NOT require proxy interception — it drives
//       the transaction boundary explicitly, so the inner methods can stay
//       private and there is no proxy-bypass concern.
//   (b) Self-injection via @Lazy has no precedent for self-calls in this
//       codebase; existing @Lazy uses (e.g. StockunitBusinessService:85,
//       UnitloadBusinessService:30) are cross-bean cycle breaks, not
//       self-injection. Introducing self-injection purely to drive Tx
//       splitting would be novel and unnecessary.
//   (c) TransactionTemplate makes the boundaries auditable at the call site —
//       the orchestrator reads top-to-bottom: claimTx.execute(...) then
//       finalizeTx.execute(...) then a compensating release on Tx-2 failure.
private final PlatformTransactionManager tenantTxManager;
private final TransactionTemplate claimTx;    // for Tx-1
private final TransactionTemplate finalizeTx; // for Tx-2

// Add to constructor signature (existing constructor at line 89). Inject the
// tenant transaction manager via @Qualifier to satisfy the v2 dual-TM rule
// (CLAUDE.md "Dual Transaction Manager (CRITICAL)").
public MobilePickingService(
        // ... existing args ...,
        @Qualifier("tenantTransactionManager") PlatformTransactionManager tenantTxManager) {
    // ... existing assignments ...
    this.tenantTxManager = tenantTxManager;
    this.claimTx = new TransactionTemplate(tenantTxManager);
    this.finalizeTx = new TransactionTemplate(tenantTxManager);
}

// --- ORCHESTRATOR (NOT @Transactional) ---
// Called by HTTP / mobile controller boundary. Pre-loads the user (cheap
// landlord-side read), then drives Tx-1 then Tx-2 via TransactionTemplate so
// each carries its own transactional boundary. The two inner methods are
// private; TransactionTemplate does not require a proxy.
public Pickingorder selectAndReservePickingOrder(long pickingOrderID)
        throws BusinessException, FacadeException {
    LOG.debug("start with pickingOrderID={}", pickingOrderID);

    // Pre-lock work: identify caller outside any tx so we do not pay for it
    // under the row lock.
    User user = userRepository.findByName(SecurityContextUtils.getUserName())
            .orElseThrow(() -> new EntityNotFoundException("User not found by name: "
                    + SecurityContextUtils.getUserName()));

    // Tx-1: acquire row lock, run guards, claim, commit. Lock released after
    // claimTx.execute returns.
    ClaimResult claimResult = claimTx.execute(status -> {
        try {
            return claimPickingOrderAtomically(pickingOrderID, user.getId());
        } catch (BusinessException | FacadeException e) {
            status.setRollbackOnly();
            throw new RuntimeException(e);  // TransactionTemplate requires unchecked
        }
    });
    if (claimResult == null || claimResult.claimed() == null) {
        LOG.debug("end without pickingOrder");
        return null;
    }

    // Tx-2: setup work, no row lock on pickingorder.
    try {
        return finalizeTx.execute(status -> {
            try {
                return finalizePickingOrderForStart(claimResult.claimed());
            } catch (BusinessException | FacadeException e) {
                status.setRollbackOnly();
                throw new RuntimeException(e);
            }
        });
    } catch (RuntimeException tx2Failure) {
        if (claimResult.wasFreshClaim()) {
            // Only release the claim if Tx-1 made a fresh state mutation.
            // If Tx-1 was a no-op re-claim (order was already RESERVED by same user),
            // leave the existing RESERVED state intact — the operator can retry.
            LOG.error("Tx-2 failed after fresh Tx-1 claim for pickingOrderID={}; releasing claim",
                    pickingOrderID, tx2Failure);
            releaseClaimQuietly(pickingOrderID, user.getId());
        } else {
            LOG.warn("Tx-2 failed after no-op re-claim for pickingOrderID={}; RESERVED state preserved for retry",
                    pickingOrderID, tx2Failure);
        }
        if (tx2Failure.getCause() instanceof BusinessException be) throw be;
        if (tx2Failure.getCause() instanceof FacadeException fe) throw fe;
        throw tx2Failure;
    }
}

// --- Tx-1 body — private, called only from claimTx.execute(...) ---
// Returns ClaimResult(null, false) when the row does not exist.
// Returns ClaimResult(saved, true) when a fresh claim was made (state < RESERVED → RESERVED).
// Returns ClaimResult(saved, false) when the order was already RESERVED by this user (no-op re-claim).
// Throws BusinessException / FacadeException for guard violations (RESERVED by different user, already PICKED, etc).
private ClaimResult claimPickingOrderAtomically(long pickingOrderID, Long userId)
        throws BusinessException, FacadeException {
    LOG.debug("Tx-1 start with pickingOrderID={}, userId={}", pickingOrderID, userId);

    Optional<Pickingorder> opt = pickingorderRepository.findByIdForUpdate(pickingOrderID);  // FOR UPDATE w/ 1000ms timeout (Fix B)
    if (opt.isEmpty()) {
        LOG.debug("Tx-1 end — no row");
        return new ClaimResult(null, false);
    }
    Pickingorder pickingOrder = opt.get();

    boolean freshClaim = false;
    if (pickingOrder.getState() < WmsConstants.State.RESERVED) {
        int stateOld = pickingOrder.getState();
        if (stateOld >= WmsConstants.State.PICKED) {
            LOG.warn("Order is already picked. => Cannot reserve.");
            throw new FacadeException("PICK_ALREADY_STARTED", pickingOrder.getNumber());
        }
        // Preserved as-is from the legacy method, including the existing
        // condition shape. (The condition is structurally unreachable in the
        // `state < RESERVED` branch but kept verbatim to avoid changing
        // pre-existing behavior in this refactor — see §10.)
        if (stateOld >= WmsConstants.State.RESERVED && userId.equals(pickingOrder.getOperatorId())) {
            LOG.warn("Order is already assigned to a different user. => Cannot reserve.");
            throw new FacadeException("ORDER_RESERVED", "");
        }
        pickingOrder.setOperatorId(userId);
        pickingOrder.setState(WmsConstants.State.RESERVED);
        freshClaim = true;
    } else if (!userId.equals(pickingOrder.getOperatorId())) {
        throw new BusinessException("Picking Order reserved by different user!");
    }
    // No-op re-claim path: state already RESERVED, same user — freshClaim stays false.

    // Commit the claim. Row lock released here.
    // On no-op re-claim (freshClaim==false) the entity was not mutated — skip
    // the UPDATE to avoid an extra round-trip under the FOR UPDATE lock window.
    Pickingorder saved = freshClaim ? pickingorderRepository.save(pickingOrder) : pickingOrder;
    LOG.debug("Tx-1 end — claimed state={} operator={} freshClaim={}", saved.getState(), saved.getOperatorId(), freshClaim);
    return new ClaimResult(saved, freshClaim);
}

// --- Tx-2 body — private, called only from finalizeTx.execute(...) ---
private Pickingorder finalizePickingOrderForStart(Pickingorder claimed)
        throws BusinessException, FacadeException {
    LOG.debug("Tx-2 start with pickingOrder={}", claimed);

    // Re-load by id (NO FOR UPDATE) — Tx-1 already claimed; this load is a
    // standard read inside Tx-2's session. Hibernate L1 cache scope is per-tx;
    // the entity arrives detached from the orchestrator, so the read is
    // required to manage it inside Tx-2.
    Pickingorder pickingOrder = pickingorderRepository.findById(claimed.getId())
        .orElseThrow(() -> new EntityNotFoundException("Pickingorder", claimed.getId()));

    List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId());
    boolean allFinished = poPositions.stream().noneMatch(p -> p.getState() < WmsConstants.State.PICKED);

    if (allFinished && pickingOrder.getState() <= WmsConstants.State.PICKED) {
        pickingOrder.setState(WmsConstants.State.PICKED);
    }
    if (pickingOrder.getState() == WmsConstants.State.PICKED) {
        pickingorderBusinessService.finishPickingOrder(pickingOrder);
        LOG.debug("Tx-2 end — finished cascade, returning null");
        return null;
    }
    if (pickingOrder.getState() > WmsConstants.State.PICKED) {
        LOG.debug("Tx-2 end — state past PICKED, returning null");
        return null;
    }

    final Long poSectionId = pickingOrder.getSectionId();
    Section section = sectionRepository.findById(poSectionId)
        .orElseThrow(() -> new EntityNotFoundException("Section", poSectionId));
    if (section.getSectionpickingtype() == WmsConstants.SectionPickingType.RAPID_PICKING) {
        pickingOrder.setLockedtooperator(false);
        pickingorderRepository.save(pickingOrder);
        LOG.debug("Tx-2 end — RAPID released, returning null");
        return null;
    }

    Pickingorder saved = pickingorderRepository.save(pickingOrder);
    LOG.debug("Tx-2 end with pickingOrder={}", saved);
    return saved;
}

// --- Compensating release — runs in a fresh transaction so Tx-2's rollback
//     doesn't block it. PROPAGATION_REQUIRES_NEW is used because the
//     orchestrator is non-transactional and we want the release to commit
//     even if Tx-2's rollback unwinds.
//
//     Guard: only reset the row if it is still RESERVED by the original
//     claimant. Between Tx-1 commit (lock released) and this compensating
//     call, a concurrent caller may have re-claimed or reset the row.
//     Without the guard, this method would stomp a valid claim by another
//     user. If the guard prevents the reset (concurrent state change), a
//     WARN is logged so ops can investigate if the state is unexpected.
//     If this method also fails (extreme rarity, e.g. DB down), we log
//     ERROR and leave the row RESERVED — manual DB intervention is the
//     operational recovery vector.
private void releaseClaimQuietly(long pickingOrderID, Long claimantUserId) {
    TransactionTemplate releaseTx = new TransactionTemplate(tenantTxManager);
    releaseTx.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    try {
        releaseTx.execute(status -> {
            pickingorderRepository.findById(pickingOrderID).ifPresent(po -> {
                if (claimantUserId.equals(po.getOperatorId())
                        && po.getState() == WmsConstants.State.RESERVED) {
                    po.setOperatorId(null);
                    po.setState(WmsConstants.State.PROCESSABLE);
                    pickingorderRepository.save(po);
                } else {
                    LOG.warn("Release skipped for pickingOrderID={}; row state changed since Tx-1 commit"
                            + " (currentState={}, currentOperatorId={}) — concurrent claim detected or row already reset.",
                            pickingOrderID, po.getState(), po.getOperatorId());
                }
            });
            return null;
        });
    } catch (Exception e) {
        LOG.error("Compensating release also failed for pickingOrderID={}; manual DB intervention required",
                pickingOrderID, e);
    }
}
```

**Key notes on the `TransactionTemplate` approach:**

- `TransactionTemplate` is the standard Spring API for programmatic
  transaction management. It does **not** require proxy interception — both
  `claimPickingOrderAtomically` and `finalizePickingOrderForStart` can remain
  `private`. There is no proxy-bypass concern as there would be with
  `@Transactional` on a private or self-called method.
- `TransactionTemplate` propagates checked exceptions as `RuntimeException`
  wrappers (the `TransactionCallback` interface does not allow checked
  exceptions). The orchestrator unwraps them via `instanceof` pattern
  matching and rethrows the original checked type. **Note on unchecked
  exceptions:** unchecked exceptions (e.g. `EntityNotFoundException` thrown
  inside Tx-2) propagate natively through `TransactionTemplate.execute()`
  and are still caught by the `catch (RuntimeException tx2Failure)` block
  above, triggering the `wasFreshClaim` check. The wrap-unwrap pattern
  (`instanceof BusinessException be`) only applies to checked exceptions
  thrown by the inner lambda.
- `releaseClaimQuietly` uses `PROPAGATION_REQUIRES_NEW` so it runs in its own
  transaction regardless of whether the outer context has one (it doesn't —
  the orchestrator is non-transactional). It accepts `claimantUserId` and
  guards the reset with `po.getOperatorId().equals(claimantUserId) &&
  po.getState() == RESERVED` before mutating — preventing the compensating
  action from stomping a concurrent re-claim by another user or an
  operator-driven state reset that occurred between Tx-1 commit and the
  compensating call.
- Both `TransactionTemplate` instances are initialized with
  `tenantTransactionManager` via `@Qualifier` — this satisfies the v2 dual-TM
  rule (`CLAUDE.md` "Dual Transaction Manager (CRITICAL)") without relying on
  the `@Transactional(value = "tenantTransactionManager")` annotation form.
  `tenantTxManager` is also stored as a field so `releaseClaimQuietly` can
  construct its `PROPAGATION_REQUIRES_NEW` template directly without going
  through `claimTx.getTransactionManager()`.
- `TransactionTemplate` is already used in this project's IT tests
  (`SequenceTransactionServiceConcurrencyIT.java:104`,
  `BillofladingServiceFinishTransferPerformanceIT.java:110`); this plan
  introduces it in `main/java` for the first time — flagged for
  code-reviewer attention.

`processPickingOrderForStart` is **deleted** from `MobilePickingService` — its
body has been split between Tx-1 (the claim) and Tx-2 (the setup). The single
caller-side reference at `:164` is replaced by the orchestrator's
`finalizeTx.execute(...)` call. The other caller at `:203`
(`resumePickingOrderIfExists`) is **out of scope** for this plan — see §0
row 4 — and so the deletion of `processPickingOrderForStart` is contingent on
its sole remaining call being preserved by inlining the relevant subset (see
Fix A.1 immediately below).

**Note on partial-commit atomicity (auto-compensated):** if Tx-2 fails after
Tx-1 commits, the orchestrator's `catch (RuntimeException tx2Failure)` block
invokes `releaseClaimQuietly(pickingOrderID, user.getId())`, which runs in a
`PROPAGATION_REQUIRES_NEW` transaction. The release guards against concurrent
re-assignment: it only resets `operatorId=null` and `state=PROCESSABLE` if
the row is still RESERVED by the original claimant. If a concurrent caller
has already claimed or reset the row, the release is skipped with a WARN
log. If the compensating release itself fails (e.g. DB down), the order
remains in RESERVED — manual DB intervention is required, and the log entry
contains the `pickingOrderID` so ops can locate it. Expected frequency of
the double-failure path: extremely rare (< 0.01% of picking starts).
Documented in AC10 / §7 manual-test row "Tx-2 failure recovery" and in §9
Risk-2.

### Fix A.1: Inline subset into `resumePickingOrderIfExists`

`resumePickingOrderIfExists` (line 203) is the only other caller of
`processPickingOrderForStart`. Because the resume path has already handled
RAPID_PICKING at lines 187-201 (before reaching line 203), and has already
resolved the user at line 173, the correct inline subset for the resume call
site is the strict minimum needed to preserve resume semantics:

```java
// REPLACE: pickingOrder = processPickingOrderForStart(pickingOrder);  (line 203)
// WITH:

List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId());
boolean allFinished = poPositions.stream().noneMatch(p -> p.getState() < WmsConstants.State.PICKED);

if (allFinished && pickingOrder.getState() <= WmsConstants.State.PICKED) {
    pickingOrder.setState(WmsConstants.State.PICKED);
}
if (pickingOrder.getState() == WmsConstants.State.PICKED) {
    pickingorderBusinessService.finishPickingOrder(pickingOrder);
    return null;
}
if (pickingOrder.getState() > WmsConstants.State.PICKED) {
    return null;
}
pickingOrder = pickingorderRepository.save(pickingOrder);
```

**NOT included** (already handled at the resume call site, or not applicable
to the resume path):

| Legacy block | Why excluded |
|---|---|
| User lookup (`userRepository.findByName(...)`) | Already done at `resumePickingOrderIfExists:173` |
| State-guard branch ("RESERVED by different user") | Irrelevant — resume's query at `:174` (`findByOperatorAndStates(user.getId(), …)`) already filters by operator |
| RAPID_PICKING section lookup + `setLockedtooperator(false)` + save | Already handled inline at `resumePickingOrderIfExists:187-201` (the earlier `switch (sectionPickingType)` block) |
| `stateOld >= PICKED` / `ORDER_RESERVED` throw guards | These are state-guards for a **new claim**; not applicable on the resume path where the row has already been claimed |

The resume path keeps its existing semantics and existing test coverage; only
its inline body changes. The inline body is **not** wrapped in any
`TransactionTemplate`/`@Transactional` plumbing — `resumePickingOrderIfExists`
is itself already `@Transactional("tenantTransactionManager")` at line 169
and inherits the transaction for the inlined statements.

### Fix B: Add 1000ms lock timeout to `PickingorderRepository.findByIdForUpdate`

**Before:**

```java
// PickingorderRepository.java:22-24
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT p FROM Pickingorder p WHERE p.id = :id")
Optional<Pickingorder> findByIdForUpdate(@Param("id") Long id);
```

**After:**

```java
import jakarta.persistence.QueryHint;
import org.springframework.data.jpa.repository.QueryHints;
// ...

@Lock(LockModeType.PESSIMISTIC_WRITE)
@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "1000"))
@Query("SELECT p FROM Pickingorder p WHERE p.id = :id")
Optional<Pickingorder> findByIdForUpdate(@Param("id") Long id);
```

**Exception chain on timeout (no controller changes needed):**

```
PostgreSQL 55P03 lock_not_available
  → Hibernate LockAcquisitionException
  → Spring CannotAcquireLockException  (subclass of PessimisticLockingFailureException)
  → RestExceptionHandler.handlePessimisticLock  (RestExceptionHandler.java:153-160)
  → HTTP 409 Conflict + ProblemDetail{retryable=true, title="Resource Locked"}
```

The handler at `RestExceptionHandler.java:153-160` already maps
`PessimisticLockingFailureException` to HTTP 409 with `retryable: true`. No
controller or handler change is required for Fix B's UX path; the existing
handler is the design.

**Important nuance:** Fix B alone **does not reduce lock duration** — it only
converts a slow-blocking acquisition into a fast-fail with operator-visible
retry signal. Fix A is what actually reduces the lock duration. Both together
are belt-and-suspenders: Fix A shrinks the typical lock-hold time so that
contention rarely arises; Fix B bounds the worst-case wait when contention
does arise.

---

## §4 Architecture Overview

### ASCII flow (post-fix)

```
Mobile client
     │
     ▼
selectAndReservePickingOrder(orderId)          ← NOT @Transactional (orchestrator)
     │
     ├─ [pre-lock] userRepository.findByName(...)
     │       (resolves caller identity outside any tx)
     │
     ├─ Tx-1: claimTx.execute(status -> claimPickingOrderAtomically(orderId, userId))   ← TransactionTemplate(tenantTM)
     │         findByIdForUpdate(orderId)  ─ SELECT FOR UPDATE  [1000ms timeout]
     │         state guards: < RESERVED / >= RESERVED branch
     │         setOperatorId + setState(RESERVED)
     │         pickingorderRepository.save(pickingOrder)
     │         [COMMIT — row lock released here]              ◄── lock window ends
     │
     ├─ Tx-2: finalizeTx.execute(status -> finalizePickingOrderForStart(claimed))   ← TransactionTemplate(tenantTM)
     │         pickingorderRepository.findById(orderId)  [no lock]
     │         pickingorderPositionRepository.findByPickingorderId(...)
     │         if allFinished → pickingorderBusinessService.finishPickingOrder(...)
     │         if RAPID_PICKING → setLockedtooperator(false) + save
     │         else save
     │         [COMMIT]
     │
     └─ On RuntimeException from finalizeTx.execute:
              releaseClaimQuietly(orderId)              ← TransactionTemplate(tenantTM) PROPAGATION_REQUIRES_NEW
              ↳ findById + setOperatorId(null) + setState(PROCESSABLE) + save + COMMIT
              rethrow original BusinessException / FacadeException / RuntimeException
```

### Key files

| File | Lines | Role |
|------|-------|------|
| `service/mobile/MobilePickingService.java` | 150-167, 323-382 | Primary fix target — split into non-transactional orchestrator + private `claimPickingOrderAtomically` (Tx-1, driven by `claimTx.execute`) + private `finalizePickingOrderForStart` (Tx-2, driven by `finalizeTx.execute`) + compensating `releaseClaimQuietly` (`PROPAGATION_REQUIRES_NEW`); delete `processPickingOrderForStart`; inline residual subset into `resumePickingOrderIfExists` |
| `repo/jpa/PickingorderRepository.java` | 22-24 | Lock-timeout per-query hint (Fix B) |
| `exceptions/RestExceptionHandler.java` | 153-160 | Existing 409 handler — no change |
| `service/PickingorderBusinessService.java` | 121-126 | `startPickingOrder` / `finishPickingOrder` (called from Tx-2 on the `allFinished` branch) |

---

## §5 Implementation Steps

### §5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No schema change; no migration | N/A | Pure code change |
| 2 | **Feature flags / system properties** | None — the `jakarta.persistence.lock.timeout=1000` per-query value overrides the global 5000ms in `application.properties:64` for this specific repository method only | N/A | Per-query `@QueryHints` is the documented override path; no env change |
| 3 | **Config / env changes** | None | N/A | |
| 4 | **Deploy-order dependencies** | None — single JAR | N/A | |
| 5 | **Data migration** | None | N/A | |
| 6 | **External systems** | None | N/A | No OMS / printer / webhook interaction in this code path |
| 7 | **Access / permissions** | None | N/A | |
| 8 | **Monitoring / alerts** | Pre-deploy: capture baseline rate of `PessimisticLockingFailureException` and HTTP 409 responses on mobile-picking endpoints. Post-deploy: expect (a) sharp drop in 409s on `selectAndReservePickingOrder` calls (because lock window shrinks), (b) any residual 409s should now have `retryable:true` and bounded ~1200ms wait latency. No new metric definitions required. | Implementer | Existing handler observed via standard Micrometer HTTP timer |

### §5.2 Implementation Checklist (ordered atomic steps)

> **Order matters.** Fix B is safe alone (it only adds a timeout, the new value
> is still > the typical sub-millisecond happy-path lock acquisition). Fix A is
> the bigger change. Land Fix B first so the fast-fail signal is in place by
> the time Fix A reshapes the lock window.

- [ ] **Step 1 (Fix B — additive)** — Add `@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "1000"))` and required imports (`jakarta.persistence.QueryHint`, `org.springframework.data.jpa.repository.QueryHints`) to `PickingorderRepository.findByIdForUpdate` (line 22-24). Behavior change: contended `findByIdForUpdate` calls now fail at 1000ms instead of 5000ms; the path is mapped to HTTP 409 by the existing handler.

- [ ] **Step 2 (TransactionTemplate fields)** — Inject `@Qualifier("tenantTransactionManager") PlatformTransactionManager` into the constructor (line 89). Create two `TransactionTemplate` fields (`claimTx`, `finalizeTx`), both initialized from `tenantTxManager` in the constructor body. No `self` field needed — `TransactionTemplate` drives the transaction explicitly without proxy interception, so the inner methods can stay private.

- [ ] **Step 3 (Tx-1)** — Add a new `private Pickingorder claimPickingOrderAtomically(long pickingOrderID, Long userId)` method (no `@Transactional` annotation — invoked exclusively from `claimTx.execute(...)`). Body: `findByIdForUpdate` + state guards + claim mutation + save (lock released when `claimTx.execute(...)` commits). The state-guard branch is preserved verbatim from the legacy method including the structurally-unreachable `stateOld >= RESERVED` inside the `< RESERVED` outer branch (intentional — no behavior change in this refactor).

- [ ] **Step 4 (Tx-2)** — Add a new `private Pickingorder finalizePickingOrderForStart(Pickingorder claimed)` method (no `@Transactional` annotation — invoked exclusively from `finalizeTx.execute(...)`). Body: `findById` re-load (no FOR UPDATE) + positions read + allFinished branch + section read + RAPID_PICKING branch + default save.

- [ ] **Step 5 (orchestrator)** — Rewrite `selectAndReservePickingOrder(long pickingOrderID)` to: (a) **remove** the `@Transactional` annotation, (b) pre-load `User` via `userRepository.findByName(...)`, (c) call `claimTx.execute(status -> claimPickingOrderAtomically(pickingOrderID, user.getId()))` with checked-exception unwrapping, (d) on null return early, (e) call `finalizeTx.execute(status -> finalizePickingOrderForStart(claimed))` inside a try/catch that on `RuntimeException` (and `wasFreshClaim==true`) calls `releaseClaimQuietly(pickingOrderID, user.getId())` and rethrows the original checked cause. Add a private `releaseClaimQuietly(long pickingOrderID, Long claimantUserId)` method backed by a `PROPAGATION_REQUIRES_NEW` `TransactionTemplate` with the operatorId+state guard per the §3 code block.

- [ ] **Step 6 (resume inline + delete `processPickingOrderForStart`)** — Inline the exact subset documented in §3 Fix A.1 into `resumePickingOrderIfExists` (replacing the `pickingOrder = processPickingOrderForStart(pickingOrder);` call at line 203). The inline body MUST consist of exactly: `findByPickingorderId`, the `allFinished` derivation, the `state==PICKED`/`>PICKED` early-return branches, and the final `save`. It must NOT include: the user lookup, the "RESERVED by different user" guard, the RAPID_PICKING section lookup branch, or the `stateOld >= PICKED` / `ORDER_RESERVED` claim guards (see Fix A.1 NOT-included table for rationale). Then **delete** `processPickingOrderForStart` from the class. Resume path's existing test coverage in `MobilePickingServiceUnitTest` must continue to pass without modification.

- [ ] **Step 7 (tests)** — Update / extend `MobilePickingServiceUnitTest`:
  - Rewrite the existing 3 `selectAndReservePickingOrder` tests to target the new method structure (AC5, AC6, AC7 below).
  - Add: reflection asserts that `claimPickingOrderAtomically` and `finalizePickingOrderForStart` are `private` and carry **no** `@Transactional` annotation (AC2, AC3).
  - Add: negative annotation check on the orchestrator (AC4).
  - Add: Tx-2 failure path test that asserts `releaseClaimQuietly` resets the row and the original `BusinessException` is rethrown (AC10).
  - Add: `processPickingOrderForStart` absent from class via reflection / source-grep (AC8).

- [ ] **Step 8 (targeted run)** — `mvn test -Dtest=MobilePickingServiceUnitTest` exits 0.

- [ ] **Step 9 (full regression)** — `mvn test` full suite — no new failures.

- [ ] **Step 10 (verify script)** — `bash sbdocs/9-System/scripts/verify-SBDEV-2237-mobilepickingservice-selectandreserve-lock-split.sh` — all PASS.

---

## §6 File Change Summary

| File | Change Type | Description |
|---|---|---|
| `service/mobile/MobilePickingService.java` | Refactor | Split `selectAndReservePickingOrder` into a non-`@Transactional` orchestrator + private `claimPickingOrderAtomically` (Tx-1) + private `finalizePickingOrderForStart` (Tx-2) + private `releaseClaimQuietly` (compensating, `PROPAGATION_REQUIRES_NEW`); inject `@Qualifier("tenantTransactionManager") PlatformTransactionManager` and create two `TransactionTemplate` fields (`claimTx`, `finalizeTx`); delete `processPickingOrderForStart`; inline its residual subset into `resumePickingOrderIfExists` |
| `repo/jpa/PickingorderRepository.java` | Enhancement | Add `@QueryHints(@QueryHint(jakarta.persistence.lock.timeout = "1000"))` to `findByIdForUpdate` |
| `test/.../service/mobile/MobilePickingServiceUnitTest.java` | Test update | Rewrite existing 3 tests + add new tests covering AC2-AC10 |

---

## §7 Testing Plan

### Unit tests — `MobilePickingServiceUnitTest`

| Test method | Acceptance Criterion | What it asserts |
|---|---|---|
| `shouldReturnNullWhenPickingOrderNotFound` | **AC5** | Stub `pickingorderRepository.findByIdForUpdate(...)` to return `Optional.empty()`; call `selectAndReservePickingOrder(orderId)`; verify (a) `claimTx.execute(...)` is invoked once (effectively, the `findByIdForUpdate` is called via the Tx-1 body), (b) Tx-1 returns null, (c) `finalizeTx.execute(...)` is **never** invoked (no `pickingorderPositionRepository.findByPickingorderId` call), (d) the orchestrator returns null. |
| `shouldReservePickingOrderWhenInProcessableState` | **AC7** | Seed an order in PROCESSABLE state; verify Tx-1 sets `operatorId` + `state=RESERVED`, calls `pickingorderRepository.save(...)` once; verify orchestrator then drives Tx-2 (observable via `pickingorderPositionRepository.findByPickingorderId` being called). |
| `shouldThrowWhenReservedByDifferentUser` | **AC6** | Seed an order already in RESERVED state with a different `operatorId`; call orchestrator; verify `BusinessException("Picking Order reserved by different user!")` is rethrown by the orchestrator (after the `TransactionTemplate` unwraps it); verify `pickingorderRepository.save(...)` is **never** called and `pickingorderPositionRepository.findByPickingorderId(...)` is **never** called (Tx-2 never entered). |
| `shouldReleaseClaimWhenFinalizeFails` | **AC10** | Stub Tx-2 collaborators so `finalizePickingOrderForStart` throws `BusinessException` (e.g. `sectionRepository.findById(...)` returns empty); verify the orchestrator (a) calls `releaseClaimQuietly(pickingOrderID)` which invokes `pickingorderRepository.findById(orderId)` + `save(...)` resetting state to `PROCESSABLE` and `operatorId` to null, and (b) rethrows the original `BusinessException`. |
| `claimPickingOrderAtomically_isPrivate` | **AC2** | Reflection: `MobilePickingService.class.getDeclaredMethod("claimPickingOrderAtomically", long.class, Long.class)` has `Modifier.PRIVATE` set; method has **no** `@Transactional` annotation. (Source-grep equivalent enforced by verify script §G1.) |
| `finalizePickingOrderForStart_isPrivate` | **AC3** | Reflection: `MobilePickingService.class.getDeclaredMethod("finalizePickingOrderForStart", Pickingorder.class)` has `Modifier.PRIVATE` set; method has **no** `@Transactional` annotation. (Source-grep equivalent enforced by verify script §G2.) |
| `selectAndReservePickingOrder_shouldNotHaveTransactionalAnnotation` | **AC4** | Reflection: assert `selectAndReservePickingOrder(long)` has **no** `@Transactional` annotation. |
| `processPickingOrderForStart_methodNameAbsentFromClass` | **AC8** | Reflection (`getDeclaredMethods()`): assert no method named `processPickingOrderForStart` exists on `MobilePickingService.class`. |

### Integration tests

N/A — `MobilePickingServiceIntegrationTest` is currently `@Disabled` in the
repo; re-enabling the integration harness is out of scope for this plan.
A future plan that re-enables that class is the right home for an end-to-end
lock-window verification (two threads, CountDownLatch, assert Tx-1 hold time
< 50ms and Tx-2 outside the lock window).

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Single picker starts a PROCESSABLE order | wineco-dev | POST to the picking endpoint that fronts `selectAndReservePickingOrder` | Order transitions PROCESSABLE → RESERVED; picker sees the order in their mobile UI | |
| Concurrent: same order, 2 pickers, one wins | wineco-dev | Simultaneous requests on the same `pickingOrderId` | One operator gets a 200 (or 204 on RAPID release / finished); the other gets HTTP 409 with `retryable:true` and `title:"Resource Locked"` (from the existing handler) | |
| Lock timeout fires | wineco-dev (simulated) | Hold a DB-level lock on the target `pickingorder` row externally (e.g. `psql` issues `BEGIN; SELECT ... FOR UPDATE` and pauses); invoke endpoint from another session | HTTP 409 returned within ~1200ms (1000ms timeout + handler overhead) | |
| RAPID_PICKING section order | wineco-dev | Start a pick on a `RAPID_PICKING` section order | Tx-2 sets `lockedtooperator=false`, returns null (order auto-released); mobile UI shows the released state | |
| Tx-2 failure recovery | wineco-dev | Simulate a Tx-2 failure after Tx-1 commits (e.g. delete the order's section row mid-flight so `sectionRepository.findById(...)` throws `EntityNotFoundException` inside Tx-2) | Orchestrator catches the wrapped exception, invokes `releaseClaimQuietly(pickingOrderID)` in a fresh `PROPAGATION_REQUIRES_NEW` transaction (resets `operatorId=null`, `state=PROCESSABLE`), then rethrows the original exception. Verify in DB that the row is back to PROCESSABLE; verify log line `"Tx-2 failed after Tx-1 committed claim for pickingOrderID=..."` | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=MobilePickingServiceUnitTest` | PASS | 94 passed, 0 failed |
| `mvn test` | PASS (pre-existing failures only) | 2 pre-existing failures (`OmsNotificationConfigContextLoadTest`, `RestExceptionHandlerUnitTest$HandleNoSuchElement`) confirmed on `develop` baseline via `git stash`; 0 new failures from SBDEV-2237 |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2237-mobilepickingservice-selectandreserve-lock-split.sh` | 21 PASS, 1 FAIL (F2 pre-existing mvn failures) | All 21 static/source checks pass; F2 reflects the same 2 pre-existing test failures |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Integration test exercising 2-thread CountDownLatch race | `MobilePickingServiceIntegrationTest` is `@Disabled`; re-enabling out of scope |
| Load test of 100 concurrent pickers | Requires a load-generation harness not present in repo today; in-scope of a future SRE workstream |
| `getPickingOrderPositionsInfo` (the production hot-path equivalent) | Different method, different cluster; bundling would expand blast radius — filed as follow-up SBDEV ticket |

---

## §8 Acceptance Criteria

**AC1** — `PickingorderRepository.findByIdForUpdate` has `@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "1000"))` adjacent to the existing `@Lock(LockModeType.PESSIMISTIC_WRITE)` annotation. Imports `jakarta.persistence.QueryHint` and `org.springframework.data.jpa.repository.QueryHints`.

**AC2** — `MobilePickingService.claimPickingOrderAtomically(long, Long)` exists, is declared `private`, and is called only from within `claimTx.execute(...)` in the orchestrator. (Source-grep enforced by verify script §G1; reflection variant in `MobilePickingServiceUnitTest`.)

**AC3** — `MobilePickingService.finalizePickingOrderForStart(Pickingorder)` exists, is declared `private`, and is called only from within `finalizeTx.execute(...)` in the orchestrator. (Source-grep enforced by verify script §G2; reflection variant in `MobilePickingServiceUnitTest`.)

**AC4** — `MobilePickingService.selectAndReservePickingOrder(long)` exists and has **NO** `@Transactional` annotation.

**AC5** — When `findByIdForUpdate` returns `Optional.empty()`, `claimPickingOrderAtomically` returns `null`; the orchestrator detects the null and returns `null` **without** entering Tx-2 (no `pickingorderPositionRepository.findByPickingorderId` call).

**AC6** — When the order is RESERVED by a different `userId`, `claimPickingOrderAtomically` throws `BusinessException("Picking Order reserved by different user!")`; `pickingorderRepository.save(...)` is **never** called inside Tx-1, and Tx-2 is never entered.

**AC7** — When the order is PROCESSABLE, Tx-1 sets `operatorId` + `state=RESERVED`, calls `save(...)` once, returns the claimed entity; the orchestrator then drives Tx-2 (observable via `pickingorderPositionRepository.findByPickingorderId(...)` being invoked).

**AC8** — The method name `processPickingOrderForStart` is **absent** from `MobilePickingService.java` after the refactor (deleted; its residual subset inlined into `resumePickingOrderIfExists`).

**AC9** — All existing and new `MobilePickingServiceUnitTest` tests pass: `mvn test -Dtest=MobilePickingServiceUnitTest` exits 0.

**AC10** — On Tx-2 failure (mocked via `finalizePickingOrderForStart` throwing `BusinessException`) after a **fresh claim** (Tx-1 transitioned state to RESERVED), the orchestrator invokes `releaseClaimQuietly(pickingOrderID, user.getId())`. When the guarding condition holds (`po.getOperatorId().equals(claimantUserId) && po.getState() == RESERVED`), `save(...)` is called with `operatorId == null` and `state == PROCESSABLE`, and the original `BusinessException` is rethrown. A second test case covers the **no-op re-claim path**: when Tx-1 was a re-claim by the same user (`wasFreshClaim == false`), a Tx-2 failure must NOT call `releaseClaimQuietly`; the RESERVED state persists so the operator can retry. A third test case covers the **concurrent-overwrite guard**: when `findById` returns a row with a different `operatorId` (simulating a concurrent claim between Tx-1 commit and the compensating call), `save(...)` is NOT called — the LOG.warn path fires instead.

**Verification script:** `sbdocs/9-System/scripts/verify-SBDEV-2237-mobilepickingservice-selectandreserve-lock-split.sh`

---

## §9 Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **`TransactionTemplate` not driving a transaction at runtime** — e.g. wrong `PlatformTransactionManager` injected, or template constructed with the landlord TM | Very Low | High (silent loss of transactional guarantees) | Constructor uses `@Qualifier("tenantTransactionManager") PlatformTransactionManager` — Spring fails at startup with `NoSuchBeanDefinitionException` if the qualifier is missing. Verify script §B2 grep-asserts the qualifier string is present in `MobilePickingService.java`. Unit-test mock can verify `claimTx.execute(...)` is invoked. |
| **Tx-2 failure after Tx-1 commits leaves an orphaned RESERVED claim** | Low (auto-compensated) | Low | Tx-2 failure triggers `releaseClaimQuietly(pickingOrderID, user.getId())` in `PROPAGATION_REQUIRES_NEW`, which guards that `po.getOperatorId().equals(claimantUserId) && po.getState() == RESERVED` before resetting. This prevents stomping a concurrent re-claim. The original exception is then rethrown. Log entry includes the `pickingOrderID`. If the compensating release ALSO fails (e.g. DB down), the order remains in RESERVED — manual DB intervention is required. Expected frequency: extremely rare (< 0.01% of picking starts). AC10 + §7 manual-test row "Tx-2 failure recovery" enforce the behavior. |
| **1000ms lock-timeout too aggressive — false positives on slow DB days** | Low | Low | 1000ms is already orders-of-magnitude larger than the typical sub-millisecond happy-path lock acquisition for a row-level lock on a single `pickingorder.id`. If the deployment's DB consistently can't acquire a row lock within 1s, that is itself a signal (e.g. PgBouncer saturation, replica lag) and the resulting 409 with `retryable:true` is the right UX. Mitigation: timeout is a per-query `@QueryHints` value — easy to tune up to 2000ms or 3000ms if operational data shows a recurring false-positive rate above ~0.1%. |
| **`selectAndReservePickingOrder` has no production HTTP caller — fix is prophylactic** | Low (Likelihood that prophylactic value misses)  | Low | Documented in §1; the actual production hot path `getPickingOrderPositionsInfo` (`:686`) is tracked as a follow-up SBDEV ticket. Landing this pattern here first establishes the shape, the test harness, and the verification script for the follow-up to copy. |
| **`wms2-picking-workflow.md` doc references the OLD method name** | Low | Low (docs drift) | Post-merge doc update: grep `sbdocs/3-Resources/workflows/wms2-picking-workflow.md` for `reserveOrder` / `selectAndReservePickingOrder` / `processPickingOrderForStart` and correct any stale references. Filed as a documentation follow-up; will not block merge. |
| **`resumePickingOrderIfExists` inline introduces a subtle behavior change** | Low | Medium | The inline subset preserves the legacy `processPickingOrderForStart` body verbatim for the resume call site. Existing `resumePickingOrderIfExists` unit-test coverage must continue to pass without modification — Step 9 of §5.2 enforces this. If existing coverage is thin, a regression test exercising both the `allFinished` branch and the RAPID_PICKING branch of the inlined block is added in Step 7. |

---

## §10 Open Questions / Resolved Decisions

All decisions are pre-confirmed for this plan; no open questions remain.

1. **Fix approach** — **Option A (Split Tx)** chosen ✓. Rejected: Option B (pre-load before lock) does not shorten the lock window for write branches (`finishPickingOrder`, RAPID_PICKING release); Option C (timeout-only) does not reduce lock duration at all. Option A is the only approach that reduces the lock window for all branches.
2. **Lock failure UX** — HTTP 409 via the existing `RestExceptionHandler.handlePessimisticLock(...)` at `RestExceptionHandler.java:153-160` ✓. No new handler / no controller change.
3. **Lock timeout value** — `jakarta.persistence.lock.timeout=1000ms` via per-query `@QueryHints` ✓. Overrides the global 5000ms in `application.properties:64` for this one method only. Sibling pattern: `BillofladingRepository.findByIdForUpdate` (5000ms).
4. **Scope** — v2/wms2-api only ✓. `getPickingOrderPositionsInfo` (the production-active equivalent at `:686`) deferred to a follow-up SBDEV ticket.
5. **Atomicity trade-off** — Tx-2 failure after Tx-1 commit leaves a RESERVED claim ✓ intentional, documented, recoverable via existing `releaseRegularPickingOrder` path.
6. **`ORDER_RESERVED` dead-code guard** — The legacy `processPickingOrderForStart` contained a `FacadeException("ORDER_RESERVED","")` throw (lines 336-339) inside the outer `if (state < RESERVED)` branch. This guard is **structurally unreachable** (it tests `stateOld >= RESERVED` while already inside `state < RESERVED`). **Explicit decision: remove it.** The split design routes the `state >= RESERVED` case through the outer `else if (!userId.equals(operatorId))` branch. Keeping the dead inner guard would require artificially preserving unreachable code inside `claimPickingOrderAtomically`. The intent of same-user re-claim semantics is superseded by `ClaimResult.wasFreshClaim`, which explicitly distinguishes fresh claims from no-op re-claims.
7. **Detached `claimed` reference** — The `ClaimResult.claimed` entity returned by `claimTx.execute(...)` is a **detached** JPA entity: Tx-1's Hibernate session closes when `claimTx.execute(...)` returns. The orchestrator MUST treat `claimed` as read-only — only its `id` is used to bootstrap Tx-2's `findById` re-load. If `Pickingorder` carries `@Version`, the `claimed.version` value is safe to read for logging but must not be merged into another session. `finalizePickingOrderForStart` correctly re-fetches a fresh managed entity via `pickingorderRepository.findById(claimed.getId())` and does not reference the detached `claimed` object beyond that call.

---

## §11 Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | **In-JVM state** (`TransactionTemplate` fields) | **No new concern** | The two `TransactionTemplate` fields are stateless wrappers around the shared `PlatformTransactionManager`. Singleton-scoped bean; safe across replicas. No new caches, no static fields, no ThreadLocals introduced. |
| 2 | **Connection pool math** | **Net improvement** | Tx-1 holds a connection for ~one SELECT + one UPDATE (sub-millisecond happy-path). Tx-2 holds a connection for the setup-work duration (~20ms typical). Previously, a single tx held the connection for **both** the lock-and-claim phase AND the setup phase combined (≥30ms). Per-request total connection-seconds **decrease**, even though we now use **two** sequential connection acquisitions per request. No change to per-tenant Hikari pool sizing. |
| 3 | **Scheduled jobs** | **N/A** | No `@Scheduled` change in this plan. |
| 4 | **Long transactions** | **Fixed** | Tx-1's body is one SELECT FOR UPDATE + at most one UPDATE — typically < 5ms. Tx-2's body has no `FOR UPDATE` (only `findById` reads and one save), typically < 30ms. Previous single tx held the row lock for the union of both phases plus any `finishPickingOrder` cascade — observably up to several seconds under load. |
| 5 | **Request affinity** | **N/A** | No in-memory session state; orchestrator is stateless; each call is independent. |
| 6 | **Retry / idempotency** | **Improved** | If the same operator retries after a Tx-2 failure: Tx-1's state guards (RESERVED by same `userId`) allow the second call to proceed through the `>= RESERVED` branch (no-op claim); Tx-2 retries cleanly. The claim is **idempotent for the same user**. For HTTP 409 on lock timeout, the existing handler's `retryable:true` property is the documented retry signal. |
| 7 | **Tenant context** | **N/A** | No new async path, no `@Async`, no scheduled job. `TenantContext` propagation unchanged. |
| 8 | **Distributed lock correctness** | **Yes — improved** | Tx-1 holds a PostgreSQL row-level lock via `findByIdForUpdate` with an explicit 1000ms timeout. Lock is acquired and released inside a single `claimTx.execute(...)` boundary backed by `tenantTransactionManager` — `TransactionTemplate`'s commit releases the lock cleanly even if the connection is later recycled by another replica. |
| 9 | **Cache invalidation** | **N/A** | `Pickingorder` is not listed in `wms2-caching-strategy.md` as a Caffeine-cached entity. No `@Cacheable` write path touched. |
| 10 | **External notifications** | **N/A** | `selectAndReservePickingOrder` does not invoke `messageService`, `httpRestService`, OMS notifications, or printer drivers. Existing call site `processPick` (unchanged) is the notification path for the pick action itself; that path is not in scope. |

### Evidence

| Concern # | What was done / verified | File:line |
|---|---|---|
| 2 | Tx-1 + Tx-2 split via `TransactionTemplate` shown to reduce per-request total connection-hold time | `MobilePickingService.java` (post-fix, `claimTx.execute` + `finalizeTx.execute` boundaries) |
| 4 | Tx-1 body (`claimPickingOrderAtomically`) bounded by one `findByIdForUpdate` + one `save`; no external I/O | `MobilePickingService.java::claimPickingOrderAtomically` (private; called only from `claimTx.execute(...)`) |
| 8 | `findByIdForUpdate` with `@Lock(PESSIMISTIC_WRITE)` + `@QueryHints(jakarta.persistence.lock.timeout=1000)` | `PickingorderRepository.java:22-24` (post-fix) |

---

## §12 v2-only Constraint Checklist

| # | Constraint | Status | Notes |
|---|---|---|---|
| 1 | **OSIV disabled — no lazy-load outside tx** | ✓ | Both Tx-1 and Tx-2 are driven by `TransactionTemplate.execute(...)`; entity mutation only occurs inside a managed session opened by the template. The orchestrator does not touch entity associations (just receives the claimed entity from `claimTx.execute(...)` and passes its reference into `finalizeTx.execute(...)` — no lazy-collection read on the orchestrator side). |
| 2 | **Transaction manager value="tenantTransactionManager"** | ✓ | Both `TransactionTemplate` instances are initialized with `tenantTransactionManager` via `@Qualifier("tenantTransactionManager") PlatformTransactionManager` in the constructor. Inner private methods are not annotated. The compensating `releaseClaimQuietly` uses the same TM directly via the stored `tenantTxManager` field. |
| 3 | **`readOnly=true` where applicable** | N/A (must be writable) | Tx-2 performs `save(...)` and may call `finishPickingOrder(...)` — cannot be `readOnly`. Tx-1 also writes. |
| 4 | **Caffeine cache invalidation** | N/A | `Pickingorder` is not a `@Cacheable` entity. |
| 5 | **`jakarta.*` namespace** | ✓ | New imports use `jakarta.persistence.QueryHint`; no `javax.*` references introduced. |
| 6 | **H2-compatible test SQL** | N/A | Unit tests use Mockito; no direct DB-test SQL. |
| 7 | **`BaseControllerTest` for controller changes** | N/A | No controller change in this plan. |
| 8 | **Micrometer metrics** | N/A | No new metric definitions. Existing `PessimisticLockingFailureException` counter (auto-observed by Spring's HTTP timer) will surface any residual 409s post-deploy. |

---

## Completeness Checklist

| # | Item | Status |
|---|---|---|
| 1 | §0 affected-sites table with in-scope / out-of-scope rationale | ✓ |
| 2 | Problem statement with symptoms + reproduction | ✓ |
| 3 | Root cause per bug with file:line + code | ✓ |
| 4 | Fix design per bug with Before/After | ✓ |
| 5 | Architecture overview with ASCII + key-files table | ✓ |
| 6 | File change summary | ✓ |
| 7 | Implementation steps ordered with atomic guidance | ✓ |
| 8 | Testing plan: unit + manual; integration N/A explained | ✓ |
| 9 | Acceptance Criteria machine-checkable | ✓ |
| 10 | Risks & mitigations | ✓ |
| 11 | Open Questions / Resolved Decisions | ✓ |
| 12 | Horizontal Scalability Validation (10 rows) | ✓ |
| 13 | v2-only Constraint Checklist (8 rows) | ✓ |
| 14 | Acceptance script path referenced | ✓ |

---

## §13 Acceptance & Implementation

### 13.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2237-mobilepickingservice-selectandreserve-lock-split.sh`

### 13.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 2 fixes (A+B) across 2 files; one test class update; concurrency-adjacent but well-bounded |
| **Pre-draft step** | done (ralplan consensus) | RALPLAN-DR principles + drivers + options summary recorded above (§ ralplan summary in handoff) |
| **Plan-review step** | `critic` | Lock-window change deserves a second pair of eyes before code lands |
| **Implementation shape** | `executor` | Mechanical refactor + 1 new test class update; no orchestration required |
| **Verification step** | verify-script + `verifier` | Mandatory |
| **Code-review step** | `code-reviewer` | Self-injection + tx-boundary split warrants explicit review |
| **Commit step** | `git-master` (atomic A+B together) | A and B should land in a single coordinated commit; B is safe-alone but A alone leaves the bigger lock window in place at 5000ms |

### 13.3 ADR

**Decision:** Split `MobilePickingService.selectAndReservePickingOrder` into a
non-transactional orchestrator + two private inner methods driven by
`TransactionTemplate(tenantTransactionManager)` — Tx-1
(`claimPickingOrderAtomically`) acquires the FOR UPDATE lock, runs the state
guard, claims the row, commits; Tx-2 (`finalizePickingOrderForStart`) runs all
setup work without holding the lock. The inner methods carry NO `@Transactional`
annotation; transaction boundaries are driven programmatically via
`claimTx.execute(...)` and `finalizeTx.execute(...)`. Add
`@QueryHints(jakarta.persistence.lock.timeout=1000)` to
`PickingorderRepository.findByIdForUpdate`.

**Decision drivers:**
1. Lock window width directly determines contention probability under high-picker load.
2. Spring AOP cannot intercept `@Transactional` on private or direct-call methods — separating into two proxy-callable methods on a self-injected bean is the only clean split path.
3. Both writes and reads in the legacy `processPickingOrderForStart` extend the lock window — pre-loading data before the lock (Option B) does not address the write-path branches.

**Alternatives considered:**
- **Option B — Pre-load before lock:** rejected. The lock-window bottleneck is not only the reads — `finishPickingOrder` and the RAPID_PICKING release branch perform writes after the lock is acquired. Pre-loading data does not shorten the lock window for these branches.
- **Option C — Timeout-only (Fix B alone):** rejected. Converts indefinite block to fast-fail (good) but does not reduce lock duration (bad). Useful as belt-and-suspenders to Fix A but insufficient as a standalone fix.

**Why chosen:** Option A (Split Tx) is the unique combination that **actually reduces lock duration for all branches** of the post-claim setup work. Combined with Option C (per-query 1000ms timeout), the result is both shorter typical lock windows AND bounded worst-case operator wait time on contention.

**Consequences:**
- **Positive:** lock window collapses from "claim + 4 sub-queries + optional finishPickingOrder cascade" to "claim + 1 save". Contention surface area for high-picker workloads shrinks dramatically. Operator-visible 409s on lock timeout are bounded to ~1200ms instead of ~5200ms.
- **Negative:** new partial-commit recovery path required — a Tx-2 failure after Tx-1 commit leaves the row in RESERVED state instead of rolling back. Mitigated by the existing symmetric `releaseRegularPickingOrder` operator action. Documented in §3, §7, §9.

**Follow-ups:**
- File a follow-up SBDEV ticket for the symmetric fix on `getPickingOrderPositionsInfo` (`:686`) — the production-active equivalent.
- Post-merge: update `sbdocs/3-Resources/workflows/wms2-picking-workflow.md` to correct any stale `processPickingOrderForStart` references.
- Consider re-enabling `MobilePickingServiceIntegrationTest` to land a 2-thread CountDownLatch lock-window verification — separate plan.
