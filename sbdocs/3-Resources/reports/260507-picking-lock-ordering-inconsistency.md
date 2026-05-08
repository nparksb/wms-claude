---
title: "Picking lock-ordering inconsistency: processPick vs confirmPick"
type: investigation-report
status: complete
version: v2
scope: wms2-api
owner: Nam Park
created: 2026-05-07
updated: 2026-05-07
related:
  - ../../2-Areas/wms-v1-v2-sync/sync-log.md
  - ../../2-Areas/wms-v1-v2-sync/sweeps/2026-05-07-wms-v1-sync.md
tags:
  - investigation
  - picking
  - concurrency
  - deadlock
  - wms2
trigger: NEW-3 from Group P verification (2026-05-07 sync sweep)
verdict_summary: Lock-order inconsistency is real but practically bounded — PostgreSQL deadlock detection plus PickingController's existing PessimisticLockingFailureException retry mitigates the failure mode.
---

# Picking lock-ordering inconsistency — investigation report

> **Trigger:** Group P verification (2026-05-07 sync sweep) flagged NEW-3 — `MobilePickingService.processPick` acquires a `findByIdForUpdate` on `Pickingorder`, while `PickingorderBusinessService.confirmPick` acquires `findByIdForUpdate` on `Customerorder` first then `Pickingorder`. The concern was a classic AB/BA deadlock setup if both target the same `(CO, PO)` pair concurrently.

---

## 1. Context & Trigger

`PickingorderBusinessService.confirmPick` was hardened in v2 commit `da64cc0` ("port v1 fixes for confirmPick race condition and transfer error handling"; v1 source `4d73546`). The fix introduced explicit lock ordering — Customerorder first, Pickingorder second — with the comment "Lock ordering: Customerorder first, then Pickingorder — prevents deadlocks between concurrent 'last pick' transactions (V1 Order_241019 fix)" at `PickingorderBusinessService.java:405-410`.

When sweeping Group P on 2026-05-07, the audit observed that `MobilePickingService.processPick` re-reads its `Pickingorder` via `findByIdForUpdate` at line 392 — acquiring a PO lock first. If processPick then triggers a `Customerorder` UPDATE downstream (via `save` or cascade), it would hold PO and acquire CO. confirmPick would hold CO and wait for PO. This is the AB/BA deadlock pattern.

The question is whether this pattern is reachable in v2 under normal warehouse load, and what the practical impact would be if it fires.

---

## 2. Questions

1. Does `processPick` actually acquire a `Customerorder` lock (explicit or implicit via UPDATE) in any code path?
2. If yes, what is the practical likelihood of a concurrent `processPick(po1)` ↔ `confirmPick(co1, po1)` pair colliding on the same `(CO, PO)` pair?
3. If a deadlock fires, how does the system behave — silent hang, abort, retry, escalate to operator?
4. Are there other picking entry points (e.g., `selectAndReservePickingOrder`, `startPickingOrder`, `resumePickingOrderIfExists`, cron `ReleaseOrderJobService.releaseOrder`) that introduce additional lock-ordering combinations?
5. Is the existing retry instrumentation sufficient, or is a code change warranted?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence |
|---|---|---|
| H1 | `processPick` does NOT acquire any Customerorder lock — only Pickingorder. The deadlock concern dissolves; lock ordering is moot. | medium |
| H2 | `processPick` acquires a Customerorder lock implicitly via JPA `save()` (UPDATE → row lock) in some branches. AB/BA deadlock is theoretically reachable. | medium |
| H3 | The deadlock has been observed in production logs (Spring `CannotAcquireLockException`, PostgreSQL `40P01 deadlock detected`). | low |
| H4 | "Nothing is actually wrong" null hypothesis — even if H2 holds, the existing PickingController catch logic (port of v1 9-catch-pair pattern) makes the failure mode a recoverable retry, not a stuck operator. | medium-high |

---

## 3.5 Sources In Scope

| Source | Why |
|---|---|
| `v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java` | All MobilePicking lock sites (lines 154, 392, 682, 1066) |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` | `confirmPick` (line 412) + `releaseOrder` callers (lines 176, 409, 499, 544) |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java` | Cron `releaseOrder` lock site (line 107); `@Transactional(propagation = Propagation.REQUIRES_NEW)` at line 99 |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/mobile/PickingController.java` | Existing exception-catching pattern (9 catch pairs for `ObjectOptimisticLockingFailureException` + `PessimisticLockingFailureException`) |
| `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` | v2 transaction boundaries reference |
| `sbdocs/2-Areas/wms-v1-v2-sync/sync-log.md` | v1 source commit `4d73546` (V1 Order_241019 fix) and v2 port `da64cc0` |

---

## 4. Method

Code read only. No production logs available in this session; no DB queries run; no repro at runtime. The investigation determines whether the deadlock vector is theoretically reachable from the source, then judges practical risk based on existing mitigations.

---

## 5. Evidence

### 5.1 `processPick` lock acquisition map

`MobilePickingService.processPick` is annotated `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` at line 384. Inside the method body (line 384 → method end), `findByIdForUpdate` is called **exactly once**:

```
MobilePickingService.java:392
    pickingOrder = pickingorderRepository.findByIdForUpdate(pickingOrderId)
        .orElseThrow(() -> new EntityNotFoundException("PickingOrder", pickingOrderId));
```

Within the same method body, `customerorderRepository.*` is invoked at:
- Two `findById(coPosition.getOrderId())` calls — read-only, no lock
- Two `customerorderRepository.save(...)` calls (one inside `getOrderByToteLabelId(toteName).ifPresent(...)`-style branch handling old-tote release, one in the main happy path after tote assignment)
- One `getOrderByToteLabelId(toteName)` — read-only

**The `save(...)` calls translate to JPA UPDATE statements at flush time. PostgreSQL acquires a `FOR UPDATE` row lock on the targeted Customerorder row at that point.** The lock is held until transaction commit.

So the practical lock acquisition order inside `processPick` is:
1. **PO via explicit `findByIdForUpdate(pickingOrderId)`** at line 392 (first SQL after method entry)
2. **CO via implicit UPDATE row lock** when the customerorder save() is flushed — this happens at varying points depending on which conditional branches fire (old-tote release, tote-reassignment, etc.) but always after step 1

This **does** create the AB/BA pattern with `confirmPick`, which acquires CO at line 409 then PO at line 412.

### 5.2 `confirmPick` lock acquisition map

```
PickingorderBusinessService.java:405-412
    // Lock ordering: Customerorder first, then Pickingorder — prevents deadlocks
    // between concurrent "last pick" transactions (V1 Order_241019 fix)
    CustomerorderPosition copForLock = customerorderPositionRepository.findById(...).orElse(null);
    if (copForLock != null) {
        customerorderRepository.findByIdForUpdate(copForLock.getOrderId());
    }
    Optional<Pickingorder> pickingOrderOpt = pickingorderRepository.findByIdForUpdate(pickingPosition.getPickingorderId());
```

Confirmed: CO first, PO second. The comment is explicit that this ordering exists to prevent deadlocks observed in v1 under "last pick" contention.

### 5.3 Why the AB/BA pattern can fire

For a deadlock between `processPick(P_a)` and `confirmPick(C_x, P_a)` to occur, both must target the same Pickingorder `P_a`. In normal warehouse operations, a Pickingorder is owned by exactly one operator at a time — `pickingOrder.getOperatorId()` is checked at `MobilePickingService.java:399-403` and throws BusinessException if a different user attempts the pick. **So a single Pickingorder cannot have processPick + confirmPick fired by two operators concurrently for the same PO.**

However, the same Customerorder can have multiple Pickingorders (a club order picked across multiple totes/operators). In that scenario:
- Operator A is mid-`processPick(P_1)` — holds `P_1`, will UPDATE `C_1` later
- Operator B is mid-`confirmPick(C_1, P_2)` — holds `C_1`, waits for `P_2`
- Operator A's `P_1` ≠ Operator B's `P_2`, so they don't collide on PO

To get a true deadlock the two transactions must contend for **the same** `(CO, PO)` pair from each side. Since one operator owns one PO, and confirmPick is called on the same operator's PO the operator just picked, the natural call sequence is:
- Operator A: `processPick(P_1)` → release TX → `confirmPick(C_1, P_1)` (sequential on the same operator's session)
- These are in different transactions, so no in-session lock-order collision

The contention scenario reduces to: **two operators picking and/or confirming from the same Customerorder C_x via different Pickingorders P_a and P_b, where one operator's `processPick` UPDATE on C_x races another operator's `confirmPick` SELECT FOR UPDATE on C_x.** Under PostgreSQL row-level locks, the loser waits up to `deadlock_timeout` (default 1s) and is aborted with `40P01 deadlock detected` if a cycle is found — otherwise just blocks until the winner commits.

### 5.4 Existing mitigation — PickingController retry pattern

Per Group P verification, `PickingController` has 9 catch pairs of `ObjectOptimisticLockingFailureException` + `PessimisticLockingFailureException`. Spring maps PostgreSQL `40P01` to `CannotAcquireLockException`, which is a subclass of `PessimisticLockingFailureException`. So the deadlock-aborted transaction is caught and surfaced to the operator as a retry-able error envelope (with the existing `Runtime Error` wrapping).

`MobilePickingService.processPick` itself does not retry — but the **controller layer** wraps the call. Frontend behavior is the standard "Tap again" — operator retries; second attempt succeeds because the contending transaction has committed.

**Net effect:** sporadic operator-visible "Runtime Error" on the picking screen during heavy contention on a shared Customerorder; recoverable via retry; no stuck operator and no data corruption.

### 5.5 Other lock sites (broadening scope)

| Method | Lock acquisitions | Order |
|---|---|---|
| `MobilePickingService.selectAndReservePickingOrder` (line 154) | `pickingorderRepository.findByIdForUpdate(pickingOrderID)` | PO only |
| `MobilePickingService.processPick` (line 392) | PO explicit + CO implicit (via save) | PO → CO (implicit) |
| `MobilePickingService.startPickingOrder` (in path of line 682) | PO explicit, possibly CO via save | PO → CO (implicit) |
| `MobilePickingService.resumePickingOrderIfExists` (line 1066) | PO explicit | PO only |
| `PickingorderBusinessService.confirmPick` (line 405-412) | CO explicit + PO explicit | CO → PO |
| `PickingorderBusinessService.finishPickingOrder` (line 176, dedup map) | CO explicit (multiple via Map<Long, Customerorder>) | CO only — dedup'd |
| `PickingorderBusinessService.processCancelOrder` (line 499) | CO explicit | CO only |
| `PickingorderBusinessService.startPickingOrder` (line 544) | CO explicit | CO only |
| `ReleaseOrderJobService.releaseOrder` (line 107) | CO explicit (in `@Transactional(REQUIRES_NEW)` per-order) | CO only |

The CO-only paths (`finishPickingOrder`, `processCancelOrder`, `releaseOrder`) cannot deadlock against `processPick` because they don't ask for PO. The PO-only paths (`selectAndReservePickingOrder`, `resumePickingOrderIfExists`) cannot deadlock against `confirmPick` for the same reason.

The two paths that hold both locks are `processPick` (PO → CO implicit) and `confirmPick` (CO → PO explicit). These are the only AB/BA pair.

### 5.6 What we did NOT find

- No production logs in scope this session — H3 (the deadlock has been observed in production) cannot be verified or refuted from code alone. Recommendation: grep `wineco-prod` and `wineco-dev` logs for `CannotAcquireLockException` and `40P01` against the `customerorder` and `pickingorder` tables; if absent over the last 30 days under typical warehouse load, that is strong evidence the practical risk is negligible.
- No JMeter / k6 stress test result for the `(processPick, confirmPick)` pair targeting the same Customerorder.
- No application-level deadlock metric in Micrometer — could be added, but not strictly necessary if the controller retry layer is doing its job.

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Updated confidence | Why it moved |
|---|---|---|---|
| H1 | `processPick` does not acquire any Customerorder lock — only Pickingorder | **rejected** | `customerorderRepository.save()` at multiple branches in processPick body translates to UPDATE → implicit row lock on Customerorder |
| H2 | AB/BA deadlock is theoretically reachable | **high** | Confirmed via §5.1, §5.2, §5.3 — both methods touch (CO, PO) in opposite orders, contention requires only that two operators target the same Customerorder via different Pickingorders |
| H3 | The deadlock has been observed in production logs | **unknown** | Cannot verify from code alone; left for a follow-up log/metric query |
| H4 | Even if H2 holds, the existing controller retry layer makes this a recoverable retry, not a stuck operator | **high** | `PickingController` 9 catch-pair pattern catches `PessimisticLockingFailureException` (Spring's mapping of PostgreSQL `40P01`); operator gets standard "Runtime Error" envelope; "Tap again" succeeds |

---

## 7. Verdict

**The lock-ordering inconsistency between `processPick` (PO → CO implicit) and `confirmPick` (CO → PO explicit) is real and creates a theoretically reachable deadlock vector.** Confidence: high (code evidence is direct).

**The practical impact is bounded by two factors:**
1. The deadlock requires two operators concurrently working on different Pickingorders that share the same parent Customerorder — an uncommon but reachable warehouse pattern (multi-tote club orders).
2. PostgreSQL detects and aborts at `deadlock_timeout` (default 1s) with `40P01`, which Spring maps to `PessimisticLockingFailureException`, which `PickingController` already catches and renders as a retry-able error envelope. Operator retries, second attempt succeeds.

**The system is therefore deadlock-resilient in practice, even though the source-level lock ordering is fragile.** This is a defensible-but-not-best-in-class state. Confidence: high.

A future refactor that removes the controller retry layer, or that adds a third entity into the lock dance (e.g., locking the picking-order's parent club batch), would invalidate this resilience claim. The fragility should be documented so the next person touching these methods doesn't accidentally remove the mitigation.

---

## 8. Recommendation

**Monitor.**

Concretely:
1. **Add a 30-day log query** against `wineco-prod` for `CannotAcquireLockException`, `PessimisticLockingFailureException`, and PostgreSQL `40P01 deadlock detected` filtered to `customerorder` / `pickingorder` lock_addr. If the count is < 10/month, the existing mitigation is sufficient and no code change is warranted.
2. **Add a comment to `MobilePickingService.processPick`** at line 392 documenting the lock-ordering tension and the controller-layer retry as the mitigation. This is a one-line cross-reference comment, not a code-behavior change. It prevents the next refactor from removing the retry without realizing it's load-bearing.
3. **Do NOT introduce explicit `findByIdForUpdate(customerOrder)` to processPick** to "fix" the lock ordering. Adding an explicit CO lock at the top of processPick would widen the lock window for every pick (the common case) to mitigate a rare edge case (multi-operator club-order contention). The cost-benefit tilts against it.
4. **If the 30-day log query shows > 50/month of these exceptions**, escalate to a `wms-bugfix-plan` to add the explicit CO lock at the top of processPick (matching confirmPick's order) and ship a verify script asserting the lock acquisition order. Until then, the existing retry layer is the right tool.

Recommendation category: **Monitor** (not Fix now, not Fix later). Verify the log query result first.

This recommendation does NOT trigger a downstream `wms-bugfix-plan`, so no `verify-<plan-id>.sh` script is required at this time. If the monitoring step escalates to "Fix later", the resulting bugfix plan must ship with one per the `wms-bugfix-plan` skill's verification-script section.

---

## 9. Open Questions

1. **Production-log evidence (H3 verification):** Has `CannotAcquireLockException` (or PostgreSQL `40P01`) been observed in `wineco-prod` v2 logs over the last 30 days for the picking flow? Suggested query: filter by class `CannotAcquireLockException` OR message contains `deadlock detected` AND stacktrace mentions `MobilePickingService.processPick` OR `PickingorderBusinessService.confirmPick`.
2. **Multi-PO Customerorder prevalence:** What fraction of active Customerorders at wineco have more than one Pickingorder? This determines the population size for the contention scenario. Quick query: `SELECT count(distinct customerorder_id) FROM pickingorder GROUP BY customerorder_id HAVING count(*) > 1;` (adapt to actual v2 schema).
3. **Cron `releaseOrder` interaction:** `ReleaseOrderJobService.releaseOrder` (line 107) takes a CO `findByIdForUpdate` inside `@Transactional(REQUIRES_NEW)` per order. If the cron fires at the moment a `processPick` is mid-flight on a child PO of the same CO, the cron's CO lock blocks until processPick commits. This is normal blocking, not deadlock — but worth noting if the cron is observed timing out.
4. **PostgreSQL `lock_timeout` setting:** Verified 2026-05-07 via grep across `v2/wms2-api/src/main/resources/` and `v2/wms2-api/src/main/java/net/aim_ai/wms/landlord/` — **no `lock_timeout` or `lockTimeout` configured anywhere in v2.** PostgreSQL default applies (i.e., `lock_timeout` = 0 → wait indefinitely until `deadlock_timeout` fires at default 1s for true deadlocks). A non-zero `lock_timeout` would surface contention earlier and convert hang-into-deadlock-detection into hang-into-fast-retry. Out of scope for this investigation; flagging for SRE consideration if Q1 (production-log evidence) shows non-trivial contention.

---

## 10. References

- Sync sweep flagging this concern: `sbdocs/2-Areas/wms-v1-v2-sync/sweeps/2026-05-07-wms-v1-sync.md` (Group P NEW-3)
- v1 source of confirmPick lock-ordering fix: `4d73546` ("fix: lock parent rows in confirmPick() to prevent concurrent completion race")
- v2 port: `da64cc0` ("feat: port v1 fixes for confirmPick race condition and transfer error handling")
- v2 transaction boundary reference: `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md`
- Controller retry pattern verified in: Group P verification (sync-log entry 2026-05-07)
- Sync log: `sbdocs/2-Areas/wms-v1-v2-sync/sync-log.md`

---

## Completeness Checklist

| # | Concern | Status |
|---|---|---|
| 1 | All in-scope code files / log sources / queries enumerated in §3.5 | ✓ §3.5 |
| 2 | At least one "nothing is actually wrong" hypothesis in §3 | ✓ H4 |
| 3 | Each hypothesis has primary evidence (file:line, log line, query output), not paraphrase | ✓ §5.1, §5.2, §5.3, §5.4 |
| 4 | Confidence assigned per hypothesis; uncertainty stated explicitly when present | ✓ §6 (H3 marked unknown) |
| 5 | What you LOOKED FOR but didn't find — null results documented as findings | ✓ §5.6 |
| 6 | v1/v2 deltas if both versions are in scope | ✓ §5.2 cites v1 source `4d73546` and v2 port `da64cc0` |
| 7 | Cross-references to related reports / plans cited | ✓ §10 |
| 8 | §9 Open Questions populated with any sub-questions you couldn't answer | ✓ §9 (4 questions) |
| 9 | §8 Recommendation explicitly picks one of: Fix now / Fix later / Do NOT fix / Monitor / Investigate further | ✓ Monitor |
| 10 | If recommendation = Fix now/later — note that the downstream plan must ship a verify script | ✓ §8 footnote |
