---
title: "Restore three replenishment-maintenance triggers on lock-state changes in StockunitService (v2)"
ticket: "SBDEV-2033 (follow-up)"
ticket_url: https://app.clickup.com/t/868hyr110
type: feature
priority: medium
status: archived
project: [wms2]
version: v2
requester: Nam Park
created: 2026-06-26
updated: "2026-07-15"
related:
  - sbdocs/1-Projects/wms1/plan/260626-restore-replenishment-triggers-on-lock-state-changes.md
  - sbdocs/2-Areas/wms-v1-v2-sync/sweeps/2026-06-26b-wms-v1-sync.md
  - sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
  - sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md
db_verified: "manual — per-env wms2 sysprop cron check is a manual DB step (see §5.1)"
tags: [plan, replenishment, reservation, wms2, v1-v2-port]
---

# Restore three replenishment-maintenance triggers on lock-state changes in StockunitService (v2)

**Ticket:** [SBDEV-2033 (follow-up)](https://app.clickup.com/t/868hyr110)
**Project:** wms2 | **Version:** v2 | **Type:** feature
**Priority:** medium
**Status:** implemented — 2026-06-27, v2 commit `64e8516` on `port/SBDEV-2033-restore-lock-state-replenish-triggers`, **PR [#54](https://github.com/SiteBossInc/wms2-api/pull/54) squash-merged → `develop` as `6ab2f37`** (2026-06-28). ralplan consensus (Planner → Architect → Critic, APPROVE) + code-reviewer (0 High, 3 Medium all fixed). Ports v1 commits `0d6f989d` + `d3f5ce18` ([v1 plan](../../wms1/plan/260626-restore-replenishment-triggers-on-lock-state-changes.md), PR [#185](https://github.com/SiteBossInc/wms-api/pull/185)). See §12.
**V2 Target:** `v2/wms2-api`
**Date:** 2026-06-26

> Follow-up to SBDEV-2033, addressing Brent Campbell's ClickUp question on whether the removed
> triggers had a good reason. No dedicated ticket; references SBDEV-2033.

---

## 1. Problem Statement

SBDEV-2033 removed the `triggerReplenishmentMaintenance()` calls from `StockunitService` to fix a re-reservation bug. In v1 it had **five** call sites; v1's final state (after `0d6f989d` removed all five and `d3f5ce18` restored three) keeps the trigger on `setLockOnHold`, `setLockDamaged`, `removeLock` and OFF on `transferStock`, `adjustReservedAmount`, `adjustAmount`.

The actual re-reservation bug lived only in `transferStock` + `adjustReservedAmount` — operator-intent paths that leave the source unit-load `NOT_LOCKED` and available, so a synchronous recalc re-grabs the stock the operator just moved/released. The other three (`setLockOnHold`, `setLockDamaged`, `removeLock`) were legitimate (SBDEV-1742): their removal lets replenishment keep pointing a pick at stock that was **just damaged or just put on hold** until the next replenish-cron cycle — a stale-source window during which operators are directed to pick stock that is no longer pickable.

**v2 diverged from v1** before this work: v2 only ever had **three** trigger sites, currently `setLockDamaged` (:401) + `adjustAmount` (:441), with `transferStock` already removed by the SBDEV-2033 port (v2 `38fcc13`). This plan reconciles v2 to v1's intent — not a mechanical cherry-pick.

---

## 2. Summary

| Metric | Count |
|---|---|
| v1 trigger sites in final state | 3 ON (`setLockOnHold`, `setLockDamaged`, `removeLock`), 3 OFF |
| Already correct in v2 (no change) | `setLockDamaged` ON (:401); `transferStock` OFF; `adjustReservedAmount` OFF |
| **Deliberate v1↔v2 divergence** | `adjustAmount` — v1 OFF (scope deferral), **v2 keeps it ON** (see §3 + §11) |
| v2 code changes needed | **2** (+`setLockOnHold`, +`removeLock`) |
| NEW v2-only issues | 1 (NEW-1, MEDIUM — deferred, see §6) |

**No DB / schema / Flyway / config / deploy-order / external-system change.** Pure service-method behavior → **unit tests only**; no Testcontainers IT (so SBDEV-2217's broken v2 IT harness does **not** block this port).

> **`adjustAmount` divergence (decided 2026-06-26):** v1's removal of the `adjustAmount` trigger was a **scope deferral** ("low marginal value, no reported defect"), *not* a safety fix — `adjustAmount` was never one of the two re-reservation-bug paths (`transferStock` + `adjustReservedAmount`). v2 currently has a working, safe `adjustAmount` trigger (:441); removing it would **regress** existing v2 behavior (a new stale-source window on amount edits) for parity-only benefit. Because an amount edit genuinely changes availability (`amount − reserved` drives replenishment sizing via `getAvailableIncludingReservation`), the synchronous recalc there is *correct*, not wasted. **v2 therefore keeps the `adjustAmount` trigger ON** — a deliberate, documented divergence from v1. Future v1→v2 sweeps must NOT "correct" this.

---

## 3. V1 → V2 Applicability Analysis

| V1 Fix | Description | V2 Verdict | Rationale (v2 file:line) |
|---|---|---|---|
| Restore `setLockOnHold` trigger | recalc after put-on-hold | **Needed** | v2 OFF; method `@Transactional(tenantTransactionManager)` :296. Insert before `return stockUnitUpdated;` :348. |
| Restore `setLockDamaged` trigger | recalc after damage | **Not needed (V2 already correct)** | v2 already calls it at :401. Lock in with a `times(1)` parity assertion (§7). |
| Restore `removeLock` trigger | recalc after unlock | **Needed** | v2 OFF; method NOT `@Transactional` :477. Insert before `return newStockUnit;` :510. |
| Keep `transferStock` OFF | re-reservation bug boundary | **Not needed (V2 already correct)** | v2 OFF (removed by `38fcc13`); `@Transactional` :149. Negative guard test. |
| Keep `adjustReservedAmount` OFF | re-reservation bug boundary | **Not needed (V2 already correct)** | v2 OFF with "intentionally NOT triggering" comment :468-471; existing negative test :382. |
| `adjustAmount` deferred (OFF in v1) | v1 removed, did not restore (scope) | **Deliberate divergence — V2 keeps ON** | v2 currently ON at :441 and **stays ON**. v1's OFF was a scope deferral, not a safety fix; `adjustAmount` is not a re-reservation-bug path; amount edits change availability so recalc is correct + safe. Removing it would regress v2. Lock in with a `times(1)` parity assertion (§8 test 6). |

**Helper:** `triggerReplenishmentMaintenance(Long)` at :125-131 — best-effort `try/catch`+WARN swallow; cannot throw or change the return. `replenishmentOrderMaintenanceService` already constructor-injected (:68/:96/:121). No wiring work.

---

## 4. V2-Specific Adaptation Notes

1. **Transaction manager / propagation (the load-bearing v2 nuance).** `recalculateForItem` (`ReplenishmentOrderMaintenanceService.java:109`) is `@Transactional(value = "tenantTransactionManager", rollbackFor = {...})` with **default `REQUIRED`** propagation — it is self-transactional:
   - **`setLockOnHold` (IS `@Transactional`)** → the trigger **joins the host tenant tx**. `recalculateForItem` reaches `recalculateOrder` via a **plain `this.recalculateOrder` call** (`:134`, see the WARNING block `:124-133`). This is safe **because no inner transaction is created** — so an unchecked exception inside `recalculateOrder` does **not** set a rollback-only flag on the shared host tx; it is swallowed by `triggerReplenishmentMaintenance`'s `try/catch`. It is **NOT** safe because the recalc writes are "isolated" — they are not: `changeReservedAmount` / `replenishorderRepository.save` / `cancelOrder` against *other* orders and stock units **execute inside `setLockOnHold`'s commit unit**. ⚠️ **Invariant:** the trigger MUST remain the **last statement before `return`** (after `save` at :341). If recalc runs before the `ON_HOLD` state is flushed, `isSourceUsable` sees `NOT_LOCKED` and re-grabs → the exact SBDEV-2033 regression. Guarded by an `InOrder` test (§7) **and** a code comment.
   - **`removeLock` (NOT `@Transactional`)** → its `save` (:508) auto-commits (repos inherit `tenantTransactionManager`); then `recalculateForItem` (`REQUIRED`) opens its **own new tenant tx** and re-reads the now-`NOT_LOCKED` stock → uses it as a valid source. Best-effort, identical to v1. **`removeLock` stays non-transactional in THIS change** — the transactional wrap is the NEW-1 fast-follow (§6), explicitly out of scope here.
2. **Jakarta namespace:** N/A — no imports change.
3. **`tenantTransactionManager` rule:** relevant only to NEW-1; this port adds/modifies **no** `@Transactional` annotation.
4. **SLF4J parameterized logging:** already used by the v2 helper.
5. **Constructor injection:** `replenishmentOrderMaintenanceService` already injected — no constructor change.
6. **Mockito:** v2 modern Mockito; mock field `StockunitServiceUnitTest:103`.

---

## 5. Changes by File

### 5.1 `src/main/java/net/aim_ai/wms/service/StockunitService.java`

| V1 Fix # | V2 Line | Status | Action | Priority |
|---|---|---|---|---|
| setLockOnHold | :348 (before `return stockUnitUpdated;`) | Confirmed missing | ADD trigger + comment | Phase 2 |
| setLockDamaged | :401 | Already correct | none (parity test only) | — |
| adjustAmount | :441 | Deliberate divergence — keep ON | **none** (parity test only) | — |
| removeLock | :510 (before `return newStockUnit;`) | Confirmed missing | ADD trigger + comment | Phase 2 |

**Two edits only.** Before each, re-grep to confirm exact pre-edit lines: `grep -n "return stockUnitUpdated\|return newStockUnit\|triggerReplenishmentMaintenance" StockunitService.java`, then targeted `offset+limit` Read.

**Edit 1 — `setLockOnHold` (before `return stockUnitUpdated;` at :348), ADD:**
```java
// SBDEV-2033 follow-up (SBDEV-1742): the unit load was relocated to the CODE_ON_HOLD location
// and the stock unit set ON_HOLD + saved (lines 338-341, above) BEFORE this point, so
// ReplenishmentOrderMaintenanceService.isSourceUsable() excludes it — recalc cannot re-grab it.
// MUST remain the LAST statement before return: this method is @Transactional, so the recalc joins
// the host tx and reads the FLUSHED ON_HOLD state. Moving it above the save would let recalc see
// NOT_LOCKED and re-grab the stock — the SBDEV-2033 re-reservation bug. (Guarded by an InOrder test.)
triggerReplenishmentMaintenance(stockUnit.getItemdataId());
```

**Edit 2 — `removeLock` (before `return newStockUnit;` at :510), ADD:**
```java
// SBDEV-2033 follow-up (SBDEV-1742): removeLock returns the stock to NOT_LOCKED (line 507, above,
// already saved at 508), making it a valid replenishment source again — re-reserving it against an
// open shortage is the intended outcome. This method is NOT @Transactional, so the unlock commits
// first and recalculateForItem (REQUIRED) opens its own short tenant tx (best-effort, v1 parity).
triggerReplenishmentMaintenance(stockUnit.getItemdataId());
```

**`adjustAmount` (:441) — NO code change.** v2 keeps its existing trigger (deliberate v1↔v2 divergence, §2/§3/§11). Add a brief comment above the existing call so a future sweep doesn't strip it for parity:
```java
// Kept ON deliberately (v2 diverges from v1, which deferred this for scope). An amount edit changes
// availability (amount - reserved), so a recalc here is correct + safe — adjustAmount is NOT one of
// the SBDEV-2033 re-reservation paths (those were transferStock + adjustReservedAmount).
triggerReplenishmentMaintenance(stockUnit.getItemdataId());
```

---

## 6. NEW Issues Summary

| NEW-# | Issue | File:Line | Severity | Disposition |
|---|---|---|---|---|
| NEW-1a | `removeLock` lacks method-level `@Transactional(tenantTransactionManager)` → its writes (`setEntityLock`+`save`, `sendStockChangeMessage`) auto-commit per statement (non-atomic). | `StockunitService.java:477` | MEDIUM | **Fast-follow (low risk).** Pre-existing; does NOT block this port (adding the trigger preserves v1 best-effort semantics — unlock commits first, recalc is a separate tx). A transactional wrap would make unlock+message+recalc atomic and remove the in-tx/separate-tx asymmetry. Track as a separate change. |
| NEW-1b | `setLockDamaged` (& `adjustAmount`) lack method-level `@Transactional`. | `:351`, `:407` | MEDIUM | **Deferred (non-trivial).** `setLockDamaged` calls `printService.cupsPrint` (external network I/O) at `:521` — naively wrapping the method in `@Transactional` would hold a tenant DB connection across the print (anti-pattern per CLAUDE.md scheduled-jobs rule). Needs its own design pass. Do NOT bundle. |

Neither is introduced by this port; both are pre-existing v2 latent concerns.

---

## 7. Implementation Priority

### Phase 0 — Prerequisites (BLOCKING, per-env, no code)

| # | Prerequisite | Required value / action | Notes |
|---|---|---|---|
| 1 | **Replenish cron live (BLOCKING per env)** | Per env (per tenant), confirm the v2 replenish sweep is active: sysprops `NEW_CRON_JOB_ACTIVATED=true` + `REPLENISHMENT_TIMER_ACTIVATED=true` (gates at `ReplenishOrderJob.java:130-131`), `app.cron=true` on the cron node, advisory lock `JobLockId.REPLENISH_ORDER` (:100) free. Sweep entry: `recalculateOpenOrders(false)` (:183). | **Concrete check (run before merge per env):** `SELECT syskey, sysvalue FROM los_sysprop WHERE syskey IN ('NEW_CRON_JOB_ACTIVATED','REPLENISHMENT_TIMER_ACTIVATED');` against the tenant DB (wms2 sysprop MCP), and confirm `app.cron=true` on the scheduler node. If cron is OFF in an env, the synchronous triggers still recalc correctly in-request, but the next-cycle backstop is absent — gate per-env rollout on cron status. Don't assume defaults. |
| 2 | DB / schema / Flyway / config / deploy-order / external systems / access / async | **N/A** — no schema change, no migration, no new property, single-service change, no cross-service contract, no new role, no async path. | Only a *read* of sysprops (row 1). |
| 3 | Monitoring | Optional: watch for an uptick in swallowed `"replenishment maintenance failed for itemDataId="` WARN logs post-deploy. | Best-effort; helper already logs at WARN. |

> **No `@Transactional` change is made in this port.** NEW-1 is explicitly deferred (§6).

### Phase 1 — TDD gate
Author the acceptance tests (§8); confirm the correct red/green baseline. Pause for approval (`wms-tdd-gate`).

### Phase 2 — Implement
Apply Edits 1–3 (§5.1). Re-run the targeted tests → all green.

### Phase 3 — Build & verify
`mvn clean compile` (Java 21) → SUCCESS; `mvn test -Dtest=StockunitServiceUnitTest` → green; full unit suite → green. ITs N/A.

### Phase 4 — Commit & sign-off
Commit `port v1 d3f5ce18 — restore replenishment recalc triggers on lock-state changes`; open PR → `develop`. Update §9 Implementation Status (v2 SHA, test methods, mvn result), flip status → implemented, link PR.

---

## 8. Testing Plan

Test class `net.aim_ai.wms.unit.service.StockunitServiceUnitTest` (mock `replenishmentOrderMaintenanceService` :103, modern Mockito). **All argument matchers pin the exact `itemDataId`** (`testStockunit.getItemdataId()`), not `anyLong()` — a wrong-id call must fail.

| # | Test method (target) | Assertion | TDD baseline |
|---|---|---|---|
| 1 | NEW `setLockOnHold_triggersReplenishmentMaintenance` | `InOrder` over (`stockunitRepository`, `replenishmentOrderMaintenanceService`): `inOrder.verify(stockunitRepository).save(any()); inOrder.verify(rom, times(1)).recalculateForItem(stockUnit.getItemdataId());` — asserts **count, argument, AND save-before-recalc ordering** | FAILS pre-impl (`WantedButNotInvoked`) |
| 2 | amend existing `setLockDamaged` happy-path (e.g. `SetLockDamagedExtended`) | add `verify(rom, times(1)).recalculateForItem(stockUnit.getItemdataId())` — parity lock-in | PASSES (trigger already at :401) |
| 3 | amend `RemoveLock#removesOnHoldLock` (:714) — **NEW assertion** | `verify(rom, times(1)).recalculateForItem(stockUnit.getItemdataId())` | FAILS pre-impl (existing test currently green, no trigger) |
| 4 | amend `RemoveLock#removesQualityFaultLock` (:690) — **NEW assertion** | `verify(rom, times(1)).recalculateForItem(stockUnit.getItemdataId())` | FAILS pre-impl |
| 5 | NEW `transferStock_doesNotTriggerReplenishmentMaintenance` | `verify(rom, never()).recalculateForItem(anyLong())` | PASSES throughout |
| 6 | amend `AdjustAmount#callsBusinessServiceOnChange` (:252) — **NEW assertion** (parity lock-in for the deliberate divergence) | `verify(rom, times(1)).recalculateForItem(testStockunit.getItemdataId())` | PASSES throughout (trigger already at :441; this guards that v2 KEEPS it) |
| 7 | KEEP `adjustReservedAmount_doesNotTriggerReplenishmentMaintenance` (:382) | `never().recalculateForItem(anyLong())` | PASSES throughout |

> **TDD-gate note:** the genuine **red phase** is tests **1, 3, 4** (1 = new `setLockOnHold` test; 3/4 = NEW assertions on existing-green `removeLock` tests) — all fail against the currently-missing trigger. Tests **2 and 6** are **parity lock-ins** (assert v2 KEEPS the `setLockDamaged` and `adjustAmount` triggers it already has — pass throughout). Tests **5 and 7** are negative guards (pass throughout). Test 1's `InOrder` is the regression guard against the SBDEV-2033 re-grab ordering bug (a plain `times(1)` cannot catch ordering).

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Hold a replen source | staging (cron confirmed) | Put a replen-source UL on hold via Handling Units | Open PROCESSABLE replenish order recalcs; held UL no longer used as source | |
| Damage a replen source | staging | Damage a UL that is the source of an open replenish order | Order recalcs (redirected/cancelled); no longer points at the damaged UL | |
| Unlock previously-held stock | staging | Remove the hold from a UL with an open shortage for the item | Order re-reserves the freed stock (same request) | |
| Amount edit does NOT recalc | staging | `adjustAmount` on a stock unit via Handling Units | No synchronous recalc; cron handles next cycle | |
| Cron sysprop check | per env DB | Phase 0 row-1 SQL + `app.cron` node check | Both sysprops true; cron node `app.cron=true` | |

### Deliberately-skipped coverage
| What | Why |
|---|---|
| Testcontainers ITs / `mvn verify` | No repo/SQL/controller change → no IT needed; v2 IT lane also blocked by SBDEV-2217. The in-tx recalc path is covered only at unit level (acceptable for a unit-scoped change). |

---

## 9. Horizontal Scalability Validation

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | In-JVM state | N/A | None added |
| 2 | Connection pool | **Yes (bounded)** | `setLockOnHold` joins the host connection (no 2nd connection). `removeLock` borrows one extra short-lived tenant connection for the item-scoped recalc (`findByStateAndItemdataId`, one SKU). Bounded; request-scoped operator action, not a loop. |
| 3 | Scheduled jobs | N/A | `ReplenishOrderJob` advisory-locked (`JobLockId.REPLENISH_ORDER` :100) — single replica runs the sweep; unchanged. |
| 4 | Long transactions | No | recalc is item-scoped + short; no external I/O in `recalculateForItem`. |
| 5 | Request affinity | N/A | Synchronous in-request. |
| 6 | Retry / idempotency | N/A | Best-effort swallow; cron is the convergent backstop. |
| 7 | Tenant context | No issue | Synchronous in-request; `TenantContext` set; no async hop. |
| 8 | Distributed lock correctness | **Yes (correct)** | `recalculateOrder` re-fetches via `findByIdForUpdate` (`:154`, PESSIMISTIC_WRITE) — serializes the sync trigger against the cron sweep and across replicas. |
| 9 | Cache invalidation | N/A | None. |
| 10 | External notifications | N/A | None. |

---

## 10. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Re-reservation of just-moved stock (SBDEV-2033 regression) | Very low | High | 2 buggy paths stay OFF (tests 5+7); restored paths excluded by `isSourceUsable`; **`InOrder` test (test 1) guards the setLockOnHold save-before-recalc ordering invariant**. |
| Future edit reorders the `setLockOnHold` trigger above the save | Low | High | Code comment (Edit 1) + executable `InOrder` assertion (test 1). |
| Inner recalc poisons `setLockOnHold` host tx | Very low | Medium | `recalculateForItem` uses plain `this.recalculateOrder` (no inner tx → no rollback-only flag, verified :134); helper swallows. Do NOT route via self-proxy. |
| `adjustAmount` divergence is "corrected" by a future sweep (re-removed) | Low | Medium | Code comment at :441 + §2/§3/§11 divergence notes + parity test 6 (`times(1)`) fail if the trigger is stripped. |
| Cron OFF in an env removes the safety net | Medium (env-dependent) | Medium | Phase 0 per-env BLOCKING gate with concrete SQL check. |
| Scope creep into NEW-1 | Low | Medium | Explicitly deferred; NEW-1a = fast-follow, NEW-1b = separate investigation (print-I/O). |

---

## 11. ADR

- **Decision:** Restore the trigger on `setLockOnHold` + `removeLock`; leave `setLockDamaged` (already ON), `adjustAmount` (already ON — **kept deliberately**), `transferStock` (OFF) and `adjustReservedAmount` (OFF) unchanged. **Two** surgical edits in `StockunitService.java`; no `@Transactional` change.
- **Drivers:** (1) close the stale-source window on lock-state changes (SBDEV-1742 correctness); (2) do NOT reintroduce the SBDEV-2033 re-reservation bug; (3) reach v1's *intent* (restore the 3 legitimate triggers; keep the 2 buggy ones off) while honoring v2's own correct behavior; (4) keep the surface minimal and avoid the orthogonal atomicity gap.
- **Alternatives considered:**
  - *Option B (also add `@Transactional` to setLockDamaged/removeLock now):* rejected — `setLockDamaged` holds a tenant connection across `cupsPrint` network I/O; scope creep into a transaction-semantics redesign. (The `removeLock`-only half is captured as NEW-1a fast-follow.)
  - *Option C-remove (strip `adjustAmount` for strict v1 parity):* **rejected (decided 2026-06-26).** v1's OFF was a scope deferral, not a safety fix; `adjustAmount` is not a re-reservation-bug path; amount edits change availability so recalc is correct + safe. Stripping it would *regress* current v2 behavior (new stale-source window) for parity-only benefit. → v2 keeps the trigger; deliberate documented divergence.
- **Why chosen:** smallest change that reaches v1's intent, with safety proven by `isSourceUsable` exclusion (verified in code) — while not regressing a safe, correct v2 behavior (`adjustAmount`) just to match a v1 scope choice.
- **Consequences:** lock-state changes recalc synchronously (in-request) instead of waiting for cron; one extra short tenant connection per `removeLock`. An undocumented ordering invariant is now made explicit (comment + `InOrder` test). The in-tx (`setLockOnHold`) vs separate-tx (`removeLock`) asymmetry is deliberate and documented. **v2 retains the `adjustAmount` trigger — a permanent, intentional v1↔v2 divergence that sweeps must not reconcile.**
- **Follow-ups:** NEW-1a (`removeLock` transactional wrap) low-risk fast-follow; NEW-1b (`setLockDamaged` print-I/O atomicity) separate investigation.

---

## 12. Implementation Status

**Implemented 2026-06-27; merged 2026-06-28.** v2 commit `64e8516` on branch `port/SBDEV-2033-restore-lock-state-replenish-triggers`; **PR [#54](https://github.com/SiteBossInc/wms2-api/pull/54) squash-merged → `develop` as `6ab2f37`** (branch deleted).

### Code (`src/main/java/net/aim_ai/wms/service/StockunitService.java`)
| Site | Change | Verified |
|---|---|---|
| `setLockOnHold` (last stmt before `return`) | ADDED trigger + must-stay-last comment | ✓ |
| `removeLock` (before `return`) | ADDED trigger + separate-tx comment | ✓ |
| `adjustAmount` | KEPT trigger + divergence comment (no behavior change) | ✓ |
| `setLockDamaged` / `transferStock` / `adjustReservedAmount` | unchanged | ✓ |

No `@Transactional` added/changed (NEW-1 deferred).

### Tests (`StockunitServiceUnitTest`) — ported v1 d3f5ce18 + code-review hardening
| v1 plan test | v2 method | Result |
|---|---|---|
| AC-1 setLockOnHold triggers (InOrder) | `SetLockOnHoldExtended#setLockOnHold_triggersReplenishmentMaintenance_afterSave` — InOrder `transferUnitLoadToLocation → save → recalculateForItem` (M1 hardening) | PASS |
| (M2 hardening) swallow contract | `SetLockOnHoldExtended#setLockOnHold_swallowsRecalcFailure_andStillReturns` | PASS |
| AC-2 setLockDamaged parity | `SetLockDamagedExtended#transfersEntireUnitloadWhenAmountEqualsTotal` (+`times(1)`) | PASS |
| AC-3 removeLock ON_HOLD | `RemoveLock#removesOnHoldLock` (+`times(1)`) | PASS |
| AC-4 removeLock QUALITY_FAULT | `RemoveLock#removesQualityFaultLock` (+`times(1)`) | PASS |
| AC-5 transferStock negative (non-vacuous, M3) | `TransferStockToExistingContainer#transferStock_doesNotTriggerReplenishmentMaintenance` (+terminal-side-effect verify) | PASS |
| AC-6 adjustAmount parity (divergence) | `AdjustAmount#callsBusinessServiceOnChange` (+`times(1)`) | PASS |
| AC-7 adjustReservedAmount negative (kept) | `AdjustReservedAmount#adjustReservedAmount_doesNotTriggerReplenishmentMaintenance` | PASS |

### Build / verify
- `mvn clean compile` (Java 21) — **SUCCESS**.
- `mvn test -Dtest=StockunitServiceUnitTest` — **70 run, 0 failures, 0 errors** (TDD baseline before impl: AC-1/3/4 failed `WantedButNotInvoked`; flipped green after the edits).
- ITs: N/A (no repo/SQL/controller change; v2 IT lane blocked by SBDEV-2217).

### Review
- ralplan consensus: Planner → Architect → Critic = **APPROVE** (2 iterations).
- code-reviewer: **0 High, 3 Medium** (all fixed: M1 InOrder relocation gap, M2 swallow-contract test, M3 non-vacuous `never()`), 3 Low noted/optional.

### Docs
- `sbdocs/3-Resources/design/wms2-stockunit-design.md` updated (method-table trigger column, dependency tree, §8 trigger-source list) — corrected the stale `transferStock`-triggers claim (pre-existing since `38fcc13`) and added the new lock-state trigger sites; `last_verified` → 2026-06-27.

### Cron prerequisite (Phase 0, §7) — per-env verification pending
The replenish-cron live-check (`NEW_CRON_JOB_ACTIVATED` + `REPLENISHMENT_TIMER_ACTIVATED` + `app.cron`) must still be confirmed per environment before/at deploy. Not a code blocker; recorded here as the open rollout gate.
