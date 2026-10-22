---
title: "SBDEV-3286 slice 3 — defer replenishment maintenance out of the caller's transaction"
type: design-note
ticket: SBDEV-3286
target_version: v2
tier: T3
status: archived
created: 2026-10-08
updated: 2026-10-08
related: ["[[SBDEV-3244-concurrent-recalculate-stale-version-under-lock]]"]
---

> **Archived 2026-10-13** (batch archival after `/refresh-moc`). Design note for slice 3, shipped as SBDEV-3696 (wms2-api#481, on prod). Lost atomicity and second connection during commit: Dropped (deliberate trade-offs approved 2026-10-08). §6 out-of-scope: SBDEV-3286 (parent, on dev) and SBDEV-3729. Landmines fixed in #481. The SBDEV-3286 worktree is RETAINED (parent ticket still live).
> Every finding left open in this plan is carried on umbrella follow-up ticket https://app.clickup.com/t/868mgt4nr (or the ticket named above), so nothing recorded here is load-bearing after archival.

# SBDEV-3286 slice 3 — defer replenishment maintenance out of the caller's transaction

A design note, not a full plan. Nam approved this shape on 2026-10-08: T3, with the architect consult standing in for ralplan. The triage and its measurements are on the ticket, comment 2026-10-08 "TRIAGE … slice 3". Consult: `scratchpad/3286-s3-architect.md`, summarised in §3.

## 1. Defect
- **Where the recalc runs.** `ReplenishmentOrderMaintenanceService.recalculateForItem` is `@Transactional(REQUIRED)`. It is reached through a private `triggerReplenishmentMaintenance(itemDataId)` helper, and there are two copies of that helper (`FixLocationAssignmentService` ×7 call sites, `StockunitService` ×4). Called from a `@Transactional` caller, the recalc **joins** the caller's transaction and its persistence context.
- **How it throws.** If the caller has already loaded the `Replenishorder` or `Stockunit` the recalc will lock, the recalc's `findByIdForUpdate` becomes a version-checked lock **upgrade**. A concurrent recalc commits a new version, so Hibernate throws `StaleObjectStateException` → `ObjectOptimisticLockingFailureException` and marks the transaction rollback-only. The concurrent recalc is usually the per-minute cron.
- **What the operator loses.** The helper catches only `PessimisticLockingFailureException`, so the exception escapes and the **operator's whole action is rolled back**. Example: finishing a replenishment.
- **Producers (SBDEV-3244 §2.3/§3.1):**
  - `MobileReplenishService.finishReplenishmentOrder` and `fulfillMultipleUnitLoadsTx`
  - `MobilePutAwayService.storeBoxOnLocation`
  - `MobileMoveUnitloadService.scanDestination`
  - `FixLocationAssignmentService.move`
  - `StockunitService.setLockOnHold`
  - `PickLineRealignmentService.collectTree`, reached from all of the above

## 2. Exposure (prd, 2026-10-08, read-only)
| tenant | PROCESSABLE orders | REPLENISHMENT_FINISHED / 90 d | CREATE_FIX_ASSIGNMENT / 90 d | cron (`NEW_CRON_JOB_ACTIVATED` ∧ `REPLENISHMENT_TIMER_ACTIVATED`) |
|---|---|---|---|---|
| WineCo | 560 | 784 | 936 | on |
| ShipItEZ c1wh | 120 | 326 | 115 | on |
| Hydra nywh, ShipItEZ nywh | — | — | — | on |

`ON_HOLD` and `MOVE_FIX_ASSIGNMENT`, the two paths SBDEV-3244 named, show **0 events in 90 days** on WineCo and ShipItEZ c1wh.

## 3. Design — fix the rule, not the ~6 producers
New `@Component` **`service/ReplenishmentMaintenanceTrigger`** (no `service/replenish` package exists; it sits beside the maintenance service):
```java
public void requestForItem(Long itemDataId)
  null → return
  if (TSM.isSynchronizationActive() && TSM.isActualTransactionActive())
      add id to a per-tx LinkedHashSet bound via TSM.bindResource(KEY, …);
      on the FIRST add, register ONE TransactionSynchronization:
          afterCompletion(STATUS_COMMITTED): unbind; for each id → runNow(id)
          afterCompletion(other):            unbind; DEBUG "rolled back — maintenance skipped"
  else runNow(id)

runNow(id):  tenant guard (captured TenantContext at registration; null → set+clear in finally; mismatch → ERROR, skip)
             requiresNewTemplate(tenantTransactionManager).executeWithoutResult(s -> maintenance.recalculateForItem(id))
             catch (Exception e) → WARN (best effort; the cron is the backstop)
```
Every rule below exists because the repo already got that point wrong somewhere:

| Rule | Why (where the repo learned it) |
|---|---|
| `afterCompletion(COMMITTED)`, **not** `afterCommit` | An `afterCommit` exception propagates to the caller of commit, which then sees an error for work that **did** commit. It also skips the remaining `afterCommit` callbacks, including `OmsNotificationService.doSend`, so an OMS notification is silently lost. |
| Run in **`REQUIRES_NEW`** | A `REQUIRED` write from a completion callback joins the finished transaction and is lost (`BillofladingService.reportPendingReversalsOnShippedPallets`). The new transaction is also what gives the recalc a fresh persistence context, which is the fix itself. |
| REQUIRES_NEW **only after** commit | Inline `REQUIRES_NEW` while holding row locks is the known undetectable deadlock (`MobileReplenishService:824-826`). After commit, the caller's locks are released. |
| Predicate `isSynchronizationActive() && isActualTransactionActive()` | Spring clears synchronization before running `afterCompletion` callbacks, so a trigger reached from inside one runs immediately, never a doomed re-registration. That re-registration is the SBDEV-3267 double-deferral discard. ⚠ This rests on Spring 6.2 internals, so it is pinned against the real `AbstractPlatformTransactionManager` by `ReplenishmentMaintenanceTriggerSpringTxTest` (the actual-transaction-only mutant goes red there). IT-2 cannot see it: inside its REQUIRES_NEW both flags are true. |
| Deduplicate per transaction | One recalc per item per transaction for any path that requests the same item twice. (It does NOT remove `fulfillMultipleUnitLoads`' second recalc: the deferred one runs at the inner commit and the post-commit wrapper then recalculates again in its own transaction — an earlier draft of this row claimed otherwise.) |
| Pending ids live IN the synchronization, not in `bindResource` | Spring suspends synchronizations per transaction but leaves an arbitrary bound resource visible across a `REQUIRES_NEW` suspension, which would tie an inner transaction's request to the outer's outcome (lost on outer rollback; run while the suspended outer still holds locks). Found by the security and code review lanes; pinned by `ReplenishmentMaintenanceTriggerSpringTxTest`'s nested case (the bound-resource implementation goes red). Each id also keeps the tenant it was requested under. |
| Callback NOT ordered (corrected) | An earlier revision claimed "ordered LAST"; `LOWEST_PRECEDENCE` is Spring's default, so that changed nothing (re-review L-A). Callbacks registered after this one see the transaction flags the run's own transaction reset; none reads them today. |
| Separate component, not a method on the maintenance service | A mock of the maintenance service would swallow the new method. |

**Call sites.** All 11 sites call `trigger.requestForItem(...)`. Both private copies are deleted; they had already diverged, since only one had the null guard. The SBDEV-3250 rethrow branch goes with them: there is no caller transaction left to protect.

**Unchanged.** `recalculateForItem` itself; the cron (`ReplenishOrderJob:486`); `MobileReplenishService:836`, the existing post-commit wrapper.

## 4. What changes for callers — checked per caller (consult Q1)
- **No caller reads recalc output inside its own transaction.**
  - `MobileReplenishService:869-871/:909-910` ("as maintenance left it") is defensive. The template is FINISHED at commit, and the recalc only touches PROCESSABLE orders.
  - 3626: the claim is refused before the fixed location assignment is created.
  - 3637: `redirectSource` has no trigger on its path.
  - 3605/3607/3638: they read only `getAssignedunitloadId()`.
- **Lost: atomicity.** Between the commit and the deferred recalc, an order can still source a stock unit that was just put ON_HOLD or marked damaged. If the deferred recalc fails, that lasts until the next cron run. `removeLock` and the other non-transactional callers already behave this way, so it is an accepted class. Rewrite the comment at `setLockOnHold:801-803`.
- **Cost, accepted by Nam on 2026-10-08:** the run happens inside the caller's `commit()`, before the caller's connection is released, so each run briefly holds a **second** pool connection. A tenant pool is 5 with a 30 s timeout, so starving it takes about 3 producers committing at once on one tenant. Measured on WineCo prd over 90 days: at most 2 distinct operators performed producer actions in the same second, and that happened once; 3 never did. Revisit, e.g. with a bounded executor using `TenantAwareTaskDecorator`, if that changes.

## 5. Acceptance → tests
| AC | Test | Kind |
|---|---|---|
| AC-1 The operator's action commits when the cron bumps the order version mid-action | `ReplenishMaintenanceDeferralIT#producer_shouldCommit_whenConcurrentRecalcBumpsOrderVersionMidAction`, a SBDEV-3244-style latch on the `createFixedLocationAssignment` producer shape (pre-load the order, then create the fixed location). **Red on develop:** `UnexpectedRollbackException`, 0 rows. | Postgres IT |
| AC-2 The deferred recalc actually runs after commit, in its own transaction, and its write persists | IT-1: a producer in a real tenant transaction; assert the recalc's effect is committed | Postgres IT |
| AC-3 A trigger reached from inside a completion callback is not dropped | IT: maintenance requested from a `REQUIRES_NEW` transaction opened inside a completion callback still runs. A bare call from inside a callback is untestable over JPA, because any REQUIRED write there joins the dead transaction, so that branch is pinned in `ReplenishmentMaintenanceTriggerSpringTxTest` | Postgres IT + Spring-tx unit |
| AC-4 Rollback means no recalc; no transaction means the recalc runs now | `ReplenishmentMaintenanceTriggerUnitTest`, using a real `TransactionSynchronizationManager`, not mocks | unit |
| AC-5 A failing recalc does not fail the caller and logs a WARN | unit | unit |
| AC-6 Rail: no `recalculateForItem(` call in `src/main` outside the trigger, `ReplenishOrderJob` and `MobileReplenishService`'s post-commit wrapper | `ReplenishmentMaintenanceCallSiteArchTest` | ArchUnit |
| AC-7 The existing unit tests still verify the recalc call | `StockunitServiceUnitTest` etc. build a **real** trigger around the mocked maintenance service | unit (migration) |

**Floor:** every new assertion mutation-checked with PIT where possible; full `clean verify` against the baseline; 4 review lanes (conformance, review, security, re-review).

**Before implementing:** grep `src/test` for ITs that call a producer inside a test-managed `@Transactional` and assert recalc effects. Those will go red, which is correct, but each one must be named, not discovered.

## 6. Out of scope
Per-producer projection conversions (§0.3 items 1–5) and F6 are **superseded**: once the recalc never shares the caller's persistence context, no producer's pre-load matters. R9 (`setLockOnHold`'s detached merge) is a different mechanism and stays on the ticket, along with the picking HITs, which were re-ranked low.

## 7. Implementation status (2026-10-08)
- **PR:** https://github.com/SiteBossInc/wms2-api/pull/481, branch `bugfix/SBDEV-3286-replenish-recalc-deferral`.
- **Shipped:** merged to `develop` as `13007210` on 2026-10-08. The dev deploy reports `develop-1300721050846629369e0c718263b968492e234a`. Tracked as **SBDEV-3696** (`on dev`), split from SBDEV-3286, which stays `in development` for the remaining sites.
- **Dev test as panderson:** passed. The FLA upper bound went 84→90→84 and REPL050410 followed 36→42→36, within 58 ms and 28 ms of the FLA saves (not the cron). Hold and release on stock unit 21443619 both returned 200 and committed. The deferred recalc's own effect was not observable on dev, since no holdable stock sits at any destination. Details are on SBDEV-3696.
- **Commits:**
  - `87041783` TDD gate
  - `ba47c01e` implementation
  - `c69b843d` review fixes
  - `08d4e0fc` re-review Lows
  - `eb8e2273` test cosmetics
- **Tests:**
  - `ReplenishMaintenanceDeferralIT` 3/3. AC-1 was red on develop with `UnexpectedRollbackException` and 0 rows.
  - `ReplenishmentMaintenanceTriggerSpringTxTest` 3/3.
  - `ReplenishmentMaintenanceTriggerUnitTest` 13/13.
  - `ReplenishmentMaintenanceCallSiteArchTest`.
  - 7 existing classes moved onto the real-trigger `@Spy`.
- **Mutation:** PIT 18/18, plus hand mutants: REQUIRED, afterCommit, actual-tx-only predicate, the bound-resource version, first-tenant, WARN→DEBUG, and setLockOnHold's request removed. All were killed.
- **Full `mvn clean verify`:** 8,008 + 757, 0 failures, at `08d4e0fc`.
- **Landmines found while implementing:**
  - A bare REQUIRED write inside `afterCompletion` joins the dead transaction and is lost. This is why AC-3 opens REQUIRES_NEW.
  - `bindResource` is not suspended by REQUIRES_NEW.
  - `Ordered.LOWEST_PRECEDENCE` is already Spring's default for synchronizations.
